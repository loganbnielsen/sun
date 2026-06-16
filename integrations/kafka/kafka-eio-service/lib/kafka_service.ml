module type MESSAGE = sig
  type t
  val topic_name : string
  val schema : string
  val encode : t -> Yojson.Safe.t
  val decode : Yojson.Safe.t -> (t, string) result
end

type 'a topic = {
  name      : string;
  schema_id : int;
  encode    : 'a -> Yojson.Safe.t;
  decode    : Yojson.Safe.t -> ('a, string) result;
}

type config = {
  brokers             : string list;
  schema_registry_url : string;
  admin_url           : string;
  linger_ms           : int;
  partitions          : int;
  security            : Kafka_security.t;
}

type t = {
  producer            : Kafka_producer.t;
  brokers             : string list;
  schema_registry_url : string;
  admin_url           : string;
  partitions          : int;
  security            : Kafka_security.t;
}

(* ------------------------------------------------------------------ *)
(* HTTP client via cohttp-eio                                          *)
(* ------------------------------------------------------------------ *)

(* Build a Cohttp_eio client.  The https wrapper is initialised lazily on
   first use so that plain-HTTP-only callers pay no startup cost. *)
let https_wrapper = Sun_tls.make_https_wrapper ~caller:"kafka_service"

let http_do_once net ~sw ~meth ~base_url ~path ~content_type_opt ~body_opt =
  let uri = Uri.of_string (base_url ^ path) in
  let https = Some (Lazy.force https_wrapper) in
  let client = Cohttp_eio.Client.make ~https net in
  let headers =
    let base = Http.Header.of_list
      [ ("Accept",     "application/json")
      ; ("Connection", "close")
      ] in
    match content_type_opt with
    | None    -> base
    | Some ct -> Http.Header.add base "Content-Type" ct
  in
  let body = match body_opt with
    | None   -> None
    | Some s -> Some (Cohttp_eio.Body.of_string s)
  in
  let resp, resp_body =
    Cohttp_eio.Client.call client ~sw ~headers ?body meth uri
  in
  let status = Http.Status.to_int (Http.Response.status resp) in
  let body_str =
    Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:(4 * 1024 * 1024)
  in
  (status, body_str)

let http_do net ~clock ~meth ~base_url ~path ~content_type_opt ~body_opt =
  try
    Eio.Time.with_timeout_exn clock 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        Ok (http_do_once net ~sw ~meth ~base_url ~path ~content_type_opt ~body_opt)))
  with
  | Eio.Time.Timeout -> Error "HTTP request timed out after 10s"
  | exn -> Error (Printexc.to_string exn)

let http_post net ~clock ~base_url ~path ~content_type ~body =
  http_do net ~clock ~meth:`POST ~base_url ~path
    ~content_type_opt:(Some content_type) ~body_opt:(Some body)

let http_put net ~clock ~base_url ~path ~content_type ~body =
  http_do net ~clock ~meth:`PUT ~base_url ~path
    ~content_type_opt:(Some content_type) ~body_opt:(Some body)

let http_get net ~clock ~base_url ~path =
  http_do net ~clock ~meth:`GET ~base_url ~path
    ~content_type_opt:None ~body_opt:None

(* ------------------------------------------------------------------ *)
(* Schema registry                                                     *)
(* ------------------------------------------------------------------ *)

module Schema = struct
  let check ~net ~clock ~registry_url (module M : MESSAGE) =
    let subject = M.topic_name ^ "-value" in
    let body = Yojson.Safe.to_string (`Assoc [
      ("schemaType", `String "JSON");
      ("schema",     `String M.schema);
    ]) in
    match http_post net ~clock ~base_url:registry_url
            ~path:(Printf.sprintf "/compatibility/subjects/%s/versions/latest" subject)
            ~content_type:"application/vnd.schemaregistry.v1+json"
            ~body with
    | Error e -> Error ("connection failed: " ^ e)
    | Ok (200, resp_body) ->
      (try
        match Yojson.Safe.from_string resp_body with
        | `Assoc fields ->
          (match List.assoc_opt "is_compatible" fields with
           | Some (`Bool true)  -> Ok ()
           | Some (`Bool false) ->
             Error (Printf.sprintf
               "schema for topic '%s' is not compatible with the registered version"
               M.topic_name)
           | _ -> Error ("unexpected registry response: " ^ resp_body))
        | _ -> Error ("unexpected registry response: " ^ resp_body)
       with Yojson.Json_error _ -> Error ("json parse error in registry response: " ^ resp_body))
    | Ok (404, _) ->
      Ok ()  (* no registered version yet — compatible by definition *)
    | Ok (status, body) ->
      Error (Printf.sprintf "schema registry HTTP %d: %s" status body)

  let check_all ~net ~clock ~registry_url modules =
    List.fold_left (fun acc m ->
      match acc with
      | Error _ as e -> e
      | Ok ()        -> check ~net ~clock ~registry_url m
    ) (Ok ()) modules
end

let set_subject_compatibility net ~clock ~registry_url ~topic_name =
  let subject = topic_name ^ "-value" in
  let body = {|{"compatibility":"FULL"}|} in
  match http_put net ~clock ~base_url:registry_url
          ~path:(Printf.sprintf "/config/%s" subject)
          ~content_type:"application/vnd.schemaregistry.v1+json"
          ~body with
  | Error e -> Error ("set compatibility: " ^ e)
  | Ok (200, _) | Ok (204, _) -> Ok ()
  | Ok (status, resp_body) ->
    Error (Printf.sprintf "set compatibility: HTTP %d: %s" status resp_body)

let register_schema net ~clock ~registry_url ~topic_name ~schema =
  let subject = topic_name ^ "-value" in
  let body =
    Yojson.Safe.to_string (`Assoc [
      ("schemaType", `String "JSON");
      ("schema",     `String schema);
    ])
  in
  match http_post net ~clock ~base_url:registry_url
          ~path:(Printf.sprintf "/subjects/%s/versions" subject)
          ~content_type:"application/vnd.schemaregistry.v1+json"
          ~body with
  | Error e -> Error ("schema registry connect: " ^ e)
  | Ok (status, resp_body) when status = 200 || status = 201 ->
    (match Yojson.Safe.from_string resp_body with
     | `Assoc fields ->
       (match List.assoc_opt "id" fields with
        | Some (`Int id) -> Ok id
        | _ -> Error ("schema registry: missing 'id' in: " ^ resp_body))
     | _ -> Error ("schema registry: unexpected response: " ^ resp_body)
     | exception Yojson.Json_error _ -> Error ("schema registry: json parse error in: " ^ resp_body))
  | Ok (status, resp_body) ->
    Error (Printf.sprintf "schema registry: HTTP %d: %s" status resp_body)

(* ------------------------------------------------------------------ *)
(* Topic provisioning                                                  *)
(* ------------------------------------------------------------------ *)

(* Topic provisioning via librdkafka admin API — best-effort at startup.
   Reuses the existing producer connection; no subprocess or extra TCP setup.
   In production, topics are pre-created by infrastructure. *)
let ensure_topic rk ~topic_name ~partitions =
  let err = Kafka_raw.create_topic rk topic_name partitions 1 in
  if err <> 0 then
    Error (Printf.sprintf "could not provision topic %s: %s" topic_name (Kafka_raw.err2str err))
  else
    Ok ()

(* Query the current partition count for an existing topic via the Redpanda
   admin API.  Returns None if the topic does not exist or the admin API is
   unreachable — callers must not block on this being populated. *)
let query_topic_partitions net ~clock ~admin_url ~topic_name =
  match http_get net ~clock ~base_url:admin_url
          ~path:(Printf.sprintf "/v1/topics/%s" topic_name) with
  | Error _ | Ok (404, _) -> None
  | Ok (200, body) ->
    (try
      match Yojson.Safe.from_string body with
      | `Assoc fields ->
        (match List.assoc_opt "partitions" fields with
         | Some (`List parts) -> Some (List.length parts)
         | _ -> None)
      | _ -> None
    with _ -> None)
  | Ok _ -> None

(* ------------------------------------------------------------------ *)
(* Confluent wire format: 0x00 + 4-byte big-endian schema_id + JSON   *)
(* ------------------------------------------------------------------ *)

module Confluent_wire = struct
  (* Header layout: 1 magic byte (0x00) + 4 bytes big-endian schema ID = 5 bytes *)
  let header_len = 5
  let magic_byte = '\x00'

  (** Encode a JSON value into Confluent wire format: magic + big-endian schema_id + JSON. *)
  let encode ~schema_id json =
    let json_str = Yojson.Safe.to_string json in
    let json_len = String.length json_str in
    let cs = Cstruct.create (header_len + json_len) in
    Cstruct.set_char cs 0 magic_byte;
    Cstruct.BE.set_uint32 cs 1 (Int32.of_int schema_id);
    Cstruct.blit_from_string json_str 0 cs header_len json_len;
    Cstruct.to_bytes cs

  (** Decode a Confluent wire-format message.
      Returns [Error] on too-short messages or invalid magic byte. *)
  let decode bytes =
    if Bytes.length bytes < header_len then
      Error "wire format: message too short"
    else
      let cs = Cstruct.of_bytes bytes in
      if Cstruct.get_char cs 0 <> magic_byte then
        Error "wire format: invalid magic byte"
      else
        let schema_id = Int32.to_int (Cstruct.BE.get_uint32 cs 1) in
        let json_str = Cstruct.(to_string (sub cs header_len (length cs - header_len))) in
        Ok (schema_id, json_str)
end

let encode_wire ~schema_id json = Confluent_wire.encode ~schema_id json
let decode_wire bytes = Confluent_wire.decode bytes

(* ------------------------------------------------------------------ *)
(* Public API                                                          *)
(* ------------------------------------------------------------------ *)

let config_of_env () =
  let env_or name default =
    match Sys.getenv_opt name with
    | Some v when String.length v > 0 -> v
    | _ -> default
  in
  let brokers_str = env_or "KAFKA_BROKERS" "localhost:9092" in
  {
    brokers             = String.split_on_char ',' brokers_str;
    schema_registry_url = env_or "SCHEMA_REGISTRY_URL" "http://localhost:8081";
    admin_url           = env_or "REDPANDA_ADMIN_URL"  "http://localhost:9644";
    linger_ms           = 50;
    partitions          = 1;
    security            = Kafka_security.of_env ();
  }

let create (cfg : config) ~sw =
  let producer_cfg : Kafka_producer.config = {
    brokers       = cfg.brokers;
    delivery_mode = Kafka_producer.At_least_once;
    linger_ms     = Some cfg.linger_ms;
    security      = cfg.security;
  } in
  match Kafka_producer.create producer_cfg ~sw with
  | Error e -> Error ("producer: " ^ Kafka_error.to_string e)
  | Ok producer ->
    Ok {
      producer;
      brokers             = cfg.brokers;
      schema_registry_url = cfg.schema_registry_url;
      admin_url           = cfg.admin_url;
      partitions          = cfg.partitions;
      security            = cfg.security;
    }

let register : type a. t -> net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> (module MESSAGE with type t = a) -> (a topic, string) result =
  fun svc ~net ~clock (module M) ->
  let rk = Kafka_producer.raw_handle svc.producer in
  let partition_guard () =
    match query_topic_partitions net ~clock ~admin_url:svc.admin_url
            ~topic_name:M.topic_name with
    | None -> Ok ()
    | Some current when current <= svc.partitions -> Ok ()
    | Some current ->
      Error (Printf.sprintf
        "partition count for topic '%s' cannot be reduced from %d to %d; \
         delete the topic first if this change is intentional"
        M.topic_name current svc.partitions)
  in
  match partition_guard () with
  | Error e -> Error e
  | Ok () ->
  match ensure_topic rk ~topic_name:M.topic_name ~partitions:svc.partitions with
  | Error e -> Error e
  | Ok () ->
    match register_schema net ~clock ~registry_url:svc.schema_registry_url
            ~topic_name:M.topic_name ~schema:M.schema with
    | Error e -> Error e
    | Ok schema_id ->
      (* Set FULL compatibility: new and old schemas must be mutually readable.
         This is what makes rolling deploys safe — old pods can read new messages
         and new pods can read old messages during the rollout window. *)
      (match set_subject_compatibility net ~clock ~registry_url:svc.schema_registry_url
               ~topic_name:M.topic_name with
       | Error e ->
         Printf.eprintf "warn: could not set schema compatibility for %s: %s\n%!" M.topic_name e
       | Ok () -> ());
      Ok { name = M.topic_name; schema_id; encode = M.encode; decode = M.decode }

let publish svc topic ?trace_ctx msg =
  let headers = match trace_ctx with
    | None     -> []
    | Some ctx -> Obs_trace.inject_to_headers ctx []
  in
  let payload = encode_wire ~schema_id:topic.schema_id (topic.encode msg) in
  Kafka_producer.produce_await svc.producer ~topic:topic.name ~value:payload ~headers ()

type retry_strategy =
  | In_memory    of Kafka_consumer.retry_policy
  | Retry_topics of { max_attempts : int }

let default_retry_strategy = In_memory Kafka_consumer.default_retry

let default_on_decode_error e ~raw_bytes:_ ~ack =
  Printf.eprintf "sun-worker: DECODE_ERROR skip=true error=%S\n%!" e;
  ack ();
  Kafka_consumer.Continue

let consume svc topic ~group_id ~sw
    ?(on_ready = ignore)
    ?(on_decode_error = default_on_decode_error)
    ?ot
    ~handler () =
  let decode_err_count = match ot with
    | None -> None
    | Some o ->
      Some (Obs.register_counter o
        ~name:"sun_worker_decode_errors_total"
        ~help:"Total Kafka messages dropped due to decode errors"
        ~label_names:[])
  in
  let on_decode_error e ~raw_bytes ~ack =
    (match decode_err_count with Some c -> c 1 | None -> ());
    (match ot with
     | None -> ()
     | Some o ->
       Obs.log_t o Obs.Error
         ~fields:[("error", e);
                  ("raw_bytes_len", string_of_int (Bytes.length raw_bytes));
                  ("topic", topic.name)]
         "sun-worker: decode error, skipping message");
    on_decode_error e ~raw_bytes ~ack
  in
  let consumer_cfg : Kafka_consumer.config = {
    brokers      = svc.brokers;
    group_id;
    topics       = [topic.name];
    offset_reset = Kafka_consumer.Latest;
    auto_commit  = false;
    on_rebalance = None;
    security     = svc.security;
  } in
  match Kafka_consumer.create ~on_ready consumer_cfg ~sw with
  | Error e -> Error e
  | Ok consumer ->
    let decode_and_handle raw_msg ~ack =
      let trace_ctx = Obs_trace.extract_from_headers raw_msg.Kafka_consumer.headers in
      let raw_bytes = raw_msg.Kafka_consumer.value in
      match decode_wire raw_bytes with
      | Error e -> on_decode_error e ~raw_bytes ~ack
      | Ok (_schema_id, json_str) ->
        let json_result =
          try Ok (Yojson.Safe.from_string json_str)
          with exn -> Error (Printexc.to_string exn)
        in
        match json_result with
        | Error e -> on_decode_error ("json parse: " ^ e) ~raw_bytes ~ack
        | Ok json ->
          match topic.decode json with
          | Error e -> on_decode_error ("message decode: " ^ e) ~raw_bytes ~ack
          | Ok msg  -> handler msg ~ack ~trace_ctx
    in
    let result = Kafka_consumer.consume consumer ~handler:decode_and_handle in
    Kafka_consumer.close consumer;
    result

let consume_partitioned svc topic ~group_id ~sw ~clock
    ?(on_ready = ignore)
    ?(on_decode_error = default_on_decode_error)
    ?(retry_strategy = default_retry_strategy)
    ?(on_retry = fun ~partition:_ ~attempt:_ ~delay_s:_ -> ())
    ?ot
    ~handler () =
  let decode_err_count = match ot with
    | None -> None
    | Some o ->
      Some (Obs.register_counter o
        ~name:"sun_worker_decode_errors_total"
        ~help:"Total Kafka messages dropped due to decode errors"
        ~label_names:[])
  in
  let on_decode_error e ~raw_bytes ~ack =
    (match decode_err_count with Some c -> c 1 | None -> ());
    (match ot with
     | None -> ()
     | Some o ->
       Obs.log_t o Obs.Error
         ~fields:[("error", e);
                  ("raw_bytes_len", string_of_int (Bytes.length raw_bytes));
                  ("topic", topic.name)]
         "sun-worker: decode error, skipping message");
    on_decode_error e ~raw_bytes ~ack
  in
  let consumer_cfg : Kafka_consumer.config = {
    brokers      = svc.brokers;
    group_id;
    topics       = [topic.name];
    offset_reset = Kafka_consumer.Latest;
    auto_commit  = false;
    on_rebalance = None;
    security     = svc.security;
  } in
  match retry_strategy with
  | In_memory retry ->
    (match Kafka_consumer.create ~on_ready consumer_cfg ~sw with
     | Error e -> Error e
     | Ok consumer ->
       let decode_and_handle raw_msg ~ack =
         let trace_ctx = Obs_trace.extract_from_headers raw_msg.Kafka_consumer.headers in
         let raw_bytes = raw_msg.Kafka_consumer.value in
         match decode_wire raw_bytes with
         | Error e -> on_decode_error e ~raw_bytes ~ack
         | Ok (_schema_id, json_str) ->
           let json_result =
             try Ok (Yojson.Safe.from_string json_str)
             with exn -> Error (Printexc.to_string exn)
           in
           match json_result with
           | Error e -> on_decode_error ("json parse: " ^ e) ~raw_bytes ~ack
           | Ok json ->
             match topic.decode json with
             | Error e -> on_decode_error ("message decode: " ^ e) ~raw_bytes ~ack
             | Ok msg  -> handler msg ~ack ~trace_ctx
       in
       let result =
         Kafka_consumer.consume_partitioned consumer ~sw ~clock ~retry ~on_retry
           ~handler:decode_and_handle ()
       in
       Kafka_consumer.close consumer;
       result)
  | Retry_topics { max_attempts } ->
    let retry_topic_name = topic.name ^ "-retry" in
    let dlq_topic_name   = topic.name ^ "-dlq" in
    let rk_prod = Kafka_producer.raw_handle svc.producer in
    (match ensure_topic rk_prod ~topic_name:retry_topic_name ~partitions:svc.partitions with
     | Error e -> Printf.eprintf "warn: kafka_service: %s\n%!" e
     | Ok ()   -> ());
    (match ensure_topic rk_prod ~topic_name:dlq_topic_name ~partitions:svc.partitions with
     | Error e -> Printf.eprintf "warn: kafka_service: %s\n%!" e
     | Ok ()   -> ());
    let hdr_attempt  = "X-Sun-Attempt" in
    let hdr_retry_at = "X-Sun-Retry-At" in
    let backoff_s n  = Float.min (1.0 *. (2. ** Float.of_int n)) 600.0 in
    let get_attempt headers =
      match List.assoc_opt hdr_attempt headers with
      | Some s -> Option.value ~default:0 (int_of_string_opt s)
      | None   -> 0
    in
    let get_retry_at headers =
      match List.assoc_opt hdr_retry_at headers with
      | Some s -> Option.value ~default:0.0 (float_of_string_opt s)
      | None   -> 0.0
    in
    let strip_sun_hdrs headers =
      List.filter (fun (k, _) -> k <> hdr_attempt && k <> hdr_retry_at) headers
    in
    let publish_raw ~target_topic ~attempt ~raw_bytes ~headers ~delay_s ~partition =
      on_retry ~partition ~attempt ~delay_s;
      let retry_at = Unix.gettimeofday () +. delay_s in
      let new_headers =
        (hdr_attempt,  string_of_int   attempt) ::
        (hdr_retry_at, string_of_float retry_at) ::
        strip_sun_hdrs headers
      in
      match Eio.Promise.await (
        Kafka_producer.produce_await svc.producer
          ~topic:target_topic ~value:raw_bytes ~headers:new_headers ()
      ) with
      | Ok ()  -> Ok ()
      | Error e ->
        Printf.eprintf
          "sun-worker: PUBLISH_FAILED target=%s attempt=%d error=%s — not acking\n%!"
          target_topic attempt (Kafka_error.to_string e);
        Error e
    in
    (match Kafka_consumer.create ~on_ready consumer_cfg ~sw with
     | Error e -> Error e
     | Ok consumer ->
       (* Create retry topic consumer — runs as a background fiber in sw. *)
       let retry_consumer_cfg : Kafka_consumer.config = {
         brokers      = svc.brokers;
         group_id     = group_id ^ "-sun-retry";
         topics       = [retry_topic_name];
         offset_reset = Kafka_consumer.Earliest;
         auto_commit  = false;
         on_rebalance = None;
         security     = svc.security;
       } in
       (match Kafka_consumer.create retry_consumer_cfg ~sw with
        | Error e ->
          Printf.eprintf "warn: kafka_service: retry consumer: %s\n%!" (Kafka_error.to_string e)
        | Ok retry_consumer ->
          let retry_rk =
            Kafka_consumer_handle.to_raw (Kafka_consumer.handle retry_consumer)
          in
          let decode_retry raw_msg ~ack ~attempt =
            let trace_ctx =
              Obs_trace.extract_from_headers raw_msg.Kafka_consumer.headers
            in
            let raw_bytes = raw_msg.Kafka_consumer.value in
            match decode_wire raw_bytes with
            | Error e -> on_decode_error e ~raw_bytes ~ack
            | Ok (_schema_id, json_str) ->
              match
                (try Ok (Yojson.Safe.from_string json_str)
                 with exn -> Error (Printexc.to_string exn))
              with
              | Error e -> on_decode_error ("json parse: " ^ e) ~raw_bytes ~ack
              | Ok json ->
                match topic.decode json with
                | Error e -> on_decode_error ("message decode: " ^ e) ~raw_bytes ~ack
                | Ok msg  ->
                  match handler msg ~ack ~trace_ctx with
                  | Kafka_consumer.Continue -> Kafka_consumer.Continue
                  | Kafka_consumer.Stop     -> Kafka_consumer.Stop
                  | Kafka_consumer.Error _  ->
                    let next = attempt + 1 in
                    let target, delay =
                      if next >= max_attempts then (dlq_topic_name, 0.0)
                      else (retry_topic_name, backoff_s next)
                    in
                    (match publish_raw ~target_topic:target ~attempt:next
                             ~raw_bytes:raw_msg.Kafka_consumer.value
                             ~headers:raw_msg.Kafka_consumer.headers
                             ~delay_s:delay
                             ~partition:raw_msg.Kafka_consumer.partition with
                     | Ok ()  -> ack ()
                     | Error _ -> ());
                    Kafka_consumer.Continue
          in
          Eio.Fiber.fork ~sw (fun () ->
            let retry_stream = Kafka_consumer.stream retry_consumer in
            let rec loop () =
              let raw_msg = Eio.Stream.take retry_stream in
              let attempt  = get_attempt  raw_msg.Kafka_consumer.headers in
              let retry_at = get_retry_at raw_msg.Kafka_consumer.headers in
              let delay = max 0.0 (retry_at -. Unix.gettimeofday ()) in
              if delay > 0.001 then begin
                Kafka_raw.pause_partition retry_rk
                  raw_msg.Kafka_consumer.topic raw_msg.Kafka_consumer.partition;
                Eio.Time.sleep clock delay;
                Kafka_raw.resume_partition retry_rk
                  raw_msg.Kafka_consumer.topic raw_msg.Kafka_consumer.partition
              end;
              let acked = ref false in
              let ack () =
                if not !acked then begin
                  acked := true;
                  ignore (Kafka_consumer.commit retry_consumer raw_msg)
                end
              in
              (match decode_retry raw_msg ~ack ~attempt with
               | Kafka_consumer.Stop                                 -> ()
               | Kafka_consumer.Continue | Kafka_consumer.Error _ -> loop ())
            in
            (try loop () with Eio.Cancel.Cancelled _ -> ());
            Kafka_consumer.close retry_consumer
          )
       );
       (* Main handler: intercept Error _ and route to retry topic. *)
       let decode_and_handle raw_msg ~ack =
         let trace_ctx = Obs_trace.extract_from_headers raw_msg.Kafka_consumer.headers in
         let raw_bytes = raw_msg.Kafka_consumer.value in
         let headers   = raw_msg.Kafka_consumer.headers in
         let partition = raw_msg.Kafka_consumer.partition in
         match decode_wire raw_bytes with
         | Error e -> on_decode_error e ~raw_bytes ~ack
         | Ok (_schema_id, json_str) ->
           match
             (try Ok (Yojson.Safe.from_string json_str)
              with exn -> Error (Printexc.to_string exn))
           with
           | Error e -> on_decode_error ("json parse: " ^ e) ~raw_bytes ~ack
           | Ok json ->
             match topic.decode json with
             | Error e -> on_decode_error ("message decode: " ^ e) ~raw_bytes ~ack
             | Ok msg  ->
               match handler msg ~ack ~trace_ctx with
               | Kafka_consumer.Continue -> Kafka_consumer.Continue
               | Kafka_consumer.Stop     -> Kafka_consumer.Stop
               | Kafka_consumer.Error _  ->
                 let target, delay =
                   if max_attempts <= 1 then (dlq_topic_name, 0.0)
                   else (retry_topic_name, backoff_s 1)
                 in
                 (match publish_raw ~target_topic:target ~attempt:1
                          ~raw_bytes ~headers ~delay_s:delay ~partition with
                  | Ok ()  -> ack ()
                  | Error _ -> ());
                 Kafka_consumer.Continue
       in
       (* No in-memory retry: Error never fires (we return Continue after publishing). *)
       let no_retry : Kafka_consumer.retry_policy =
         { base_delay_s = 0.0; max_delay_s = 0.0; max_attempts = 0 }
       in
       let result =
         Kafka_consumer.consume_partitioned consumer ~sw ~clock
           ~retry:no_retry
           ~on_retry:(fun ~partition:_ ~attempt:_ ~delay_s:_ -> ())
           ~handler:decode_and_handle ()
       in
       Kafka_consumer.close consumer;
       result)
