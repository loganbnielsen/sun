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
(* Minimal HTTP/1.1 client                                             *)
(* ------------------------------------------------------------------ *)

let parse_base_url url =
  if String.length url >= 8 && String.sub url 0 8 = "https://" then
    failwith ("kafka_service: HTTPS schema registry not yet supported — \
               set SCHEMA_REGISTRY_URL to an http:// address \
               (url: " ^ url ^ ")");
  let s =
    if String.length url >= 7 && String.sub url 0 7 = "http://" then
      String.sub url 7 (String.length url - 7)
    else url
  in
  match String.rindex_opt s ':' with
  | None -> (s, 80)
  | Some i ->
    let host = String.sub s 0 i in
    let port_s = String.sub s (i + 1) (String.length s - i - 1) in
    (match int_of_string_opt port_s with
     | Some p -> (host, p)
     | None -> (s, 80))

let http_do_once net ~meth ~base_url ~path ~content_type_opt ~body_opt =
  let (host, port) = parse_base_url base_url in
  let body = Option.value ~default:"" body_opt in
  let ct_header = match content_type_opt with
    | Some ct -> [Printf.sprintf "Content-Type: %s" ct]
    | None -> []
  in
  let headers =
    [ Printf.sprintf "%s %s HTTP/1.1" meth path
    ; Printf.sprintf "Host: %s:%d" host port
    ; "Connection: close"
    ; Printf.sprintf "Content-Length: %d" (String.length body)
    ; "Accept: application/json"
    ] @ ct_header
  in
  let req = String.concat "\r\n" headers ^ "\r\n\r\n" ^ body in
  try
    Ok (Eio.Net.with_tcp_connect net ~host ~service:(string_of_int port) (fun flow ->
      Eio.Flow.copy_string req flow;
      let buf = Eio.Buf_read.of_flow ~max_size:(4 * 1024 * 1024) flow in
      let status_line = Eio.Buf_read.line buf in
      let status =
        match String.split_on_char ' ' status_line with
        | _ :: code :: _ -> Option.value ~default:0 (int_of_string_opt code)
        | _ -> 0
      in
      let content_length = ref None in
      let is_chunked = ref false in
      let rec read_headers () =
        let line = Eio.Buf_read.line buf in
        if line = "" then ()
        else begin
          let lower = String.lowercase_ascii line in
          (if String.length lower > 15 && String.sub lower 0 15 = "content-length:" then
            content_length :=
              int_of_string_opt (String.trim (String.sub line 15 (String.length line - 15))));
          (if String.length lower > 18 && String.sub lower 0 18 = "transfer-encoding:" then
            let enc = String.trim (String.sub lower 18 (String.length lower - 18)) in
            if enc = "chunked" then is_chunked := true);
          read_headers ()
        end
      in
      read_headers ();
      let resp_body =
        if !is_chunked then begin
          let result = Buffer.create 1024 in
          let rec read_chunks () =
            let size_line = String.trim (Eio.Buf_read.line buf) in
            let chunk_size =
              try int_of_string ("0x" ^ size_line)
              with _ -> 0
            in
            if chunk_size = 0 then ()
            else begin
              Buffer.add_string result (Eio.Buf_read.take chunk_size buf);
              ignore (Eio.Buf_read.line buf);
              read_chunks ()
            end
          in
          read_chunks ();
          Buffer.contents result
        end else
          match !content_length with
          | Some n -> Eio.Buf_read.take n buf
          | None   -> Eio.Buf_read.take_all buf
      in
      (status, resp_body)
    ))
  with exn -> Error (Printexc.to_string exn)

let http_do net ~clock ~meth ~base_url ~path ~content_type_opt ~body_opt =
  try
    Eio.Time.with_timeout_exn clock 10.0
      (fun () -> http_do_once net ~meth ~base_url ~path ~content_type_opt ~body_opt)
  with Eio.Time.Timeout -> Error "HTTP request timed out after 10s"

let http_post net ~clock ~base_url ~path ~content_type ~body =
  http_do net ~clock ~meth:"POST" ~base_url ~path
    ~content_type_opt:(Some content_type) ~body_opt:(Some body)

let http_put net ~clock ~base_url ~path ~content_type ~body =
  http_do net ~clock ~meth:"PUT" ~base_url ~path
    ~content_type_opt:(Some content_type) ~body_opt:(Some body)

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

(* ------------------------------------------------------------------ *)
(* Confluent wire format: 0x00 + 4-byte big-endian schema_id + JSON   *)
(* ------------------------------------------------------------------ *)

let encode_wire ~schema_id json =
  let json_str = Yojson.Safe.to_string json in
  let json_len = String.length json_str in
  let buf = Bytes.create (5 + json_len) in
  Bytes.set buf 0 '\x00';
  Bytes.set buf 1 (Char.chr ((schema_id lsr 24) land 0xFF));
  Bytes.set buf 2 (Char.chr ((schema_id lsr 16) land 0xFF));
  Bytes.set buf 3 (Char.chr ((schema_id lsr  8) land 0xFF));
  Bytes.set buf 4 (Char.chr ( schema_id         land 0xFF));
  Bytes.blit_string json_str 0 buf 5 json_len;
  buf

let decode_wire bytes =
  if Bytes.length bytes < 5 then
    Error "wire format: message too short"
  else if Bytes.get bytes 0 <> '\x00' then
    Error "wire format: invalid magic byte"
  else
    let schema_id =
      (Char.code (Bytes.get bytes 1) lsl 24) lor
      (Char.code (Bytes.get bytes 2) lsl 16) lor
      (Char.code (Bytes.get bytes 3) lsl  8) lor
       Char.code (Bytes.get bytes 4)
    in
    let json_str = Bytes.sub_string bytes 5 (Bytes.length bytes - 5) in
    Ok (schema_id, json_str)

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

let default_on_decode_error e ~ack =
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
  let on_decode_error e ~ack =
    (match decode_err_count with Some c -> c 1 | None -> ());
    on_decode_error e ~ack
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
      match decode_wire raw_msg.Kafka_consumer.value with
      | Error e -> on_decode_error e ~ack
      | Ok (_schema_id, json_str) ->
        let json_result =
          try Ok (Yojson.Safe.from_string json_str)
          with exn -> Error (Printexc.to_string exn)
        in
        match json_result with
        | Error e -> on_decode_error ("json parse: " ^ e) ~ack
        | Ok json ->
          match topic.decode json with
          | Error e -> on_decode_error ("message decode: " ^ e) ~ack
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
  let on_decode_error e ~ack =
    (match decode_err_count with Some c -> c 1 | None -> ());
    on_decode_error e ~ack
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
         match decode_wire raw_msg.Kafka_consumer.value with
         | Error e -> on_decode_error e ~ack
         | Ok (_schema_id, json_str) ->
           let json_result =
             try Ok (Yojson.Safe.from_string json_str)
             with exn -> Error (Printexc.to_string exn)
           in
           match json_result with
           | Error e -> on_decode_error ("json parse: " ^ e) ~ack
           | Ok json ->
             match topic.decode json with
             | Error e -> on_decode_error ("message decode: " ^ e) ~ack
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
            match decode_wire raw_msg.Kafka_consumer.value with
            | Error e -> on_decode_error e ~ack
            | Ok (_schema_id, json_str) ->
              match
                (try Ok (Yojson.Safe.from_string json_str)
                 with exn -> Error (Printexc.to_string exn))
              with
              | Error e -> on_decode_error ("json parse: " ^ e) ~ack
              | Ok json ->
                match topic.decode json with
                | Error e -> on_decode_error ("message decode: " ^ e) ~ack
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
         | Error e -> on_decode_error e ~ack
         | Ok (_schema_id, json_str) ->
           match
             (try Ok (Yojson.Safe.from_string json_str)
              with exn -> Error (Printexc.to_string exn))
           with
           | Error e -> on_decode_error ("json parse: " ^ e) ~ack
           | Ok json ->
             match topic.decode json with
             | Error e -> on_decode_error ("message decode: " ^ e) ~ack
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
