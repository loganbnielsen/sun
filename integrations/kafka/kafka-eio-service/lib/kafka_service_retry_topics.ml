let backoff_s n = Float.min (1.0 *. (2. ** Float.of_int n)) 600.0

let hdr_attempt  = "X-Sun-Attempt"
let hdr_retry_at = "X-Sun-Retry-At"

let get_int_hdr key headers =
  match List.assoc_opt key headers with
  | Some s -> Option.value ~default:0 (int_of_string_opt s)
  | None   -> 0

let get_float_hdr key headers =
  match List.assoc_opt key headers with
  | Some s -> Option.value ~default:0.0 (float_of_string_opt s)
  | None   -> 0.0

let strip_sun_hdrs headers =
  List.filter (fun (k, _) -> k <> hdr_attempt && k <> hdr_retry_at) headers

let consume (svc : Kafka_service_intf.t) (topic : 'a Kafka_service_intf.topic)
    ~group_id ~sw ~clock ~max_attempts ~on_ready
    ~on_decode_error ~on_retry ~handler () =
  let retry_topic_name = topic.name ^ "-retry" in
  let dlq_topic_name   = topic.name ^ "-dlq"   in
  let rk_prod = Kafka_producer.raw_handle svc.producer in
  (match Kafka_service_intf.ensure_topic rk_prod ~topic_name:retry_topic_name
           ~partitions:svc.partitions with
   | Error e -> Printf.eprintf "warn: kafka_service: %s\n%!" e
   | Ok ()   -> ());
  (match Kafka_service_intf.ensure_topic rk_prod ~topic_name:dlq_topic_name
           ~partitions:svc.partitions with
   | Error e -> Printf.eprintf "warn: kafka_service: %s\n%!" e
   | Ok ()   -> ());
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
         match Kafka_service_schema.decode_message topic raw_msg with
         | Error (e, raw_bytes) -> on_decode_error e ~raw_bytes ~ack
         | Ok (msg, trace_ctx)  ->
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
           let attempt  = get_int_hdr   hdr_attempt  raw_msg.Kafka_consumer.headers in
           let retry_at = get_float_hdr hdr_retry_at raw_msg.Kafka_consumer.headers in
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
      let headers   = raw_msg.Kafka_consumer.headers in
      let partition = raw_msg.Kafka_consumer.partition in
      match Kafka_service_schema.decode_message topic raw_msg with
      | Error (e, raw_bytes) -> on_decode_error e ~raw_bytes ~ack
      | Ok (msg, trace_ctx)  ->
        match handler msg ~ack ~trace_ctx with
        | Kafka_consumer.Continue -> Kafka_consumer.Continue
        | Kafka_consumer.Stop     -> Kafka_consumer.Stop
        | Kafka_consumer.Error _  ->
          let target, delay =
            if max_attempts <= 1 then (dlq_topic_name, 0.0)
            else (retry_topic_name, backoff_s 1)
          in
          (match publish_raw ~target_topic:target ~attempt:1
                   ~raw_bytes:raw_msg.Kafka_consumer.value
                   ~headers ~delay_s:delay ~partition with
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
    result
