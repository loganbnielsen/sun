module type MESSAGE = Kafka_service_intf.MESSAGE

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

module Schema = Kafka_service_schema.Schema
module Confluent_wire = Kafka_service_schema.Confluent_wire

let encode_wire = Kafka_service_schema.encode_wire
let decode_wire = Kafka_service_schema.decode_wire

(* ------------------------------------------------------------------ *)
(* Topic provisioning                                                  *)
(* ------------------------------------------------------------------ *)

let ensure_topic rk ~topic_name ~partitions =
  let err = Kafka_raw.create_topic rk topic_name partitions 1 in
  if err <> 0 then
    Error (Printf.sprintf "could not provision topic %s: %s" topic_name (Kafka_raw.err2str err))
  else
    Ok ()

let query_topic_partitions net ~clock ~admin_url ~topic_name =
  match Kafka_service_http.http_get net ~clock ~base_url:admin_url
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
    match Kafka_service_schema.register_schema net ~clock
            ~registry_url:svc.schema_registry_url
            ~topic_name:M.topic_name ~schema:M.schema with
    | Error e -> Error e
    | Ok schema_id ->
      (match Kafka_service_schema.set_subject_compatibility net ~clock
               ~registry_url:svc.schema_registry_url
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
