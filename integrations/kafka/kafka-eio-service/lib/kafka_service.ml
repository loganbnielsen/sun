module type MESSAGE = Kafka_service_intf.MESSAGE

type 'a topic = 'a Kafka_service_intf.topic = {
  name      : string;
  schema_id : int;
  encode    : 'a -> Yojson.Safe.t;
  decode    : Yojson.Safe.t -> ('a, string) result;
}

type config = Kafka_service_intf.config = {
  brokers             : string list;
  schema_registry_url : string;
  admin_url           : string;
  linger_ms           : int;
  partitions          : int;
  security            : Kafka_security.t;
}

type t = Kafka_service_intf.t = {
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
let config_of_env = Kafka_service_config.config_of_env

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
      Kafka_service_intf.producer;
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
    match Kafka_service_intf.query_topic_partitions net ~clock
            ~admin_url:svc.admin_url ~topic_name:M.topic_name with
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
  match Kafka_service_intf.ensure_topic rk ~topic_name:M.topic_name ~partitions:svc.partitions with
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
      Ok { Kafka_service_intf.name = M.topic_name; schema_id; encode = M.encode; decode = M.decode }

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

let decode_dispatch raw_msg topic ~on_ok ~on_error =
  let raw_bytes = raw_msg.Kafka_consumer.value in
  match decode_wire raw_bytes with
  | Error e -> on_error e ~raw_bytes
  | Ok (_schema_id, json_str) ->
    match (try Ok (Yojson.Safe.from_string json_str)
           with exn -> Error (Printexc.to_string exn)) with
    | Error e -> on_error ("json parse: " ^ e) ~raw_bytes
    | Ok json ->
      match topic.decode json with
      | Error e -> on_error ("message decode: " ^ e) ~raw_bytes
      | Ok msg  -> on_ok msg

let consume svc topic ~group_id ~sw
    ?(on_ready = ignore)
    ?(on_decode_error = default_on_decode_error)
    ?ot
    ~handler () =
  let on_decode_error =
    Kafka_service_intf.wrap_on_decode_error ~ot ~topic_name:topic.name on_decode_error
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
      decode_dispatch raw_msg topic
        ~on_ok:(fun msg -> handler msg ~ack ~trace_ctx)
        ~on_error:(fun e ~raw_bytes -> on_decode_error e ~raw_bytes ~ack)
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
  let on_decode_error =
    Kafka_service_intf.wrap_on_decode_error ~ot ~topic_name:topic.name on_decode_error
  in
  match retry_strategy with
  | In_memory retry ->
    let consumer_cfg : Kafka_consumer.config = {
      brokers      = svc.brokers;
      group_id;
      topics       = [topic.name];
      offset_reset = Kafka_consumer.Latest;
      auto_commit  = false;
      on_rebalance = None;
      security     = svc.security;
    } in
    (match Kafka_consumer.create ~on_ready consumer_cfg ~sw with
     | Error e -> Error e
     | Ok consumer ->
       let decode_and_handle raw_msg ~ack =
         let trace_ctx = Obs_trace.extract_from_headers raw_msg.Kafka_consumer.headers in
         decode_dispatch raw_msg topic
           ~on_ok:(fun msg -> handler msg ~ack ~trace_ctx)
           ~on_error:(fun e ~raw_bytes -> on_decode_error e ~raw_bytes ~ack)
       in
       let result =
         Kafka_consumer.consume_partitioned consumer ~sw ~clock ~retry ~on_retry
           ~handler:decode_and_handle ()
       in
       Kafka_consumer.close consumer;
       result)
  | Retry_topics { max_attempts } ->
    Kafka_service_retry_topics.consume svc topic ~group_id ~sw ~clock
      ~max_attempts ~on_ready ~on_decode_error ~on_retry ~handler ()
