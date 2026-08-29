let backoff_s n = Float.min (1.0 *. (2. ** Float.of_int n)) 600.0

let hdr_attempt  = "X-Sun-Attempt"
let hdr_retry_at = "X-Sun-Retry-At"

let get_int_hdr key headers =
  match Option.join (List.assoc_opt key headers) with
  | Some s -> Option.value ~default:0 (int_of_string_opt s)
  | None   -> 0

let get_float_hdr key headers =
  match Option.join (List.assoc_opt key headers) with
  | Some s -> Option.value ~default:0.0 (float_of_string_opt s)
  | None   -> 0.0

let strip_sun_hdrs headers =
  List.filter (fun (k, _) -> k <> hdr_attempt && k <> hdr_retry_at) headers

(** Typed outcome for a single retry-routing decision. *)
type retry_action =
  | Ack
  | Forward_retry of { target : Kafka_service_intf.topic_name; delay_s : float }
  | Forward_dlq   of { target : Kafka_service_intf.topic_name }

(** Decide where a failed message should go after [attempt] attempts.
    [attempt] is the attempt number that will be committed to the target topic
    (i.e. the already-incremented counter). *)
let decide_action ~retry_topic ~dlq_topic ~max_attempts ~attempt =
  if attempt >= max_attempts
  then Forward_dlq { target = dlq_topic }
  else Forward_retry { target = retry_topic; delay_s = backoff_s attempt }

(** Execute the side-effecting part of a retry action: publish then ack. *)
let execute_action action ~raw_msg ~attempt ~publish_raw ~ack =
  match action with
  | Ack -> ignore (ack ())
  | Forward_retry { target; delay_s } ->
    (match publish_raw ~target_topic:target ~attempt
             ~raw_bytes:raw_msg.Kafka.Consumer.value
             ~headers:raw_msg.Kafka.Consumer.headers
             ~delay_s
             ~partition:raw_msg.Kafka.Consumer.partition with
     | Ok ()   -> ignore (ack ())
     | Error _ -> ())
  | Forward_dlq { target } ->
    (match publish_raw ~target_topic:target ~attempt
             ~raw_bytes:raw_msg.Kafka.Consumer.value
             ~headers:raw_msg.Kafka.Consumer.headers
             ~delay_s:0.0
             ~partition:raw_msg.Kafka.Consumer.partition with
     | Ok ()   -> ignore (ack ())
     | Error _ -> ())

let consume (svc : Kafka_service_intf.t) (topic : 'a Kafka_service_intf.topic)
    ~group_id ~sw ~clock ~max_attempts ~on_ready
    ~on_decode_error ~on_retry ~handler () =
  let retry_topic_name =
    Kafka_service_intf.topic_name_exn
      (topic.name ^ "-retry")
  in
  let dlq_topic_name =
    Kafka_service_intf.topic_name_exn
      (topic.name ^ "-dlq")
  in
  (match Kafka_service_intf.ensure_topic svc.producer ~topic_name:retry_topic_name
           ~partitions:svc.partitions with
   | Error e -> Printf.eprintf "warn: kafka_service: %s\n%!" e
   | Ok ()   -> ());
  (match Kafka_service_intf.ensure_topic svc.producer ~topic_name:dlq_topic_name
           ~partitions:svc.partitions with
   | Error e -> Printf.eprintf "warn: kafka_service: %s\n%!" e
   | Ok ()   -> ());
  let publish_raw ~target_topic ~attempt ~raw_bytes ~headers ~delay_s ~partition =
    on_retry ~partition ~attempt ~delay_s;
    let retry_at = Unix.gettimeofday () +. delay_s in
    let new_headers =
      (hdr_attempt,  Some (string_of_int   attempt)) ::
      (hdr_retry_at, Some (string_of_float retry_at)) ::
      strip_sun_hdrs headers
    in
    match Eio.Promise.await (
      Kafka.Producer.produce_await svc.producer
        ~topic:target_topic
        ~value:raw_bytes ~headers:new_headers ()
    ) with
    | Ok ()  -> Ok ()
    | Error e ->
      Printf.eprintf
        "sun-worker: PUBLISH_FAILED target=%s attempt=%d error=%s — not acking\n%!"
        target_topic
        attempt (Kafka.Error.to_string e);
      Error e
  in
  let consumer_cfg : Kafka.Consumer.config = {
    brokers      = svc.brokers;
    group_id;
    topics       = [topic.name];
    offset_reset = Kafka.Consumer.Earliest;
    auto_commit  = false;
    security     = svc.security;
    properties   = [];
  } in
  match Kafka.Consumer.create ~on_ready consumer_cfg ~sw with
  | Error e -> Error e
  | Ok consumer ->
    let retry_consumer_cfg : Kafka.Consumer.config = {
      brokers      = svc.brokers;
      group_id     = group_id ^ "-sun-retry";
      topics       = [retry_topic_name];
      offset_reset = Kafka.Consumer.Earliest;
      auto_commit  = false;
      security     = svc.security;
      properties   = [];
    } in
    (match Kafka.Consumer.create retry_consumer_cfg ~sw with
     | Error e ->
       Printf.eprintf "warn: kafka_service: retry consumer: %s\n%!" (Kafka.Error.to_string e)
     | Ok retry_consumer ->
       let decode_retry raw_msg ~ack ~attempt =
         match Kafka_service_schema.decode_message topic raw_msg with
         | Error (e, raw_bytes) -> on_decode_error e ~raw_bytes ~ack
         | Ok (msg, trace_ctx)  ->
           match handler msg ~ack ~trace_ctx with
           | Kafka.Consumer.Continue -> Kafka.Consumer.Continue
           | Kafka.Consumer.Stop     -> Kafka.Consumer.Stop
           | Kafka.Consumer.Error _  ->
             let next   = attempt + 1 in
             let action = decide_action ~retry_topic:retry_topic_name
                            ~dlq_topic:dlq_topic_name
                            ~max_attempts ~attempt:next in
             execute_action action ~raw_msg ~attempt:next ~publish_raw ~ack;
             Kafka.Consumer.Continue
       in
       Eio.Fiber.fork ~sw (fun () ->
         let retry_stream = Kafka.Consumer.stream retry_consumer in
         let rec loop () =
           let raw_msg = Eio.Stream.take retry_stream in
           let attempt  = get_int_hdr   hdr_attempt  raw_msg.Kafka.Consumer.headers in
           let retry_at = get_float_hdr hdr_retry_at raw_msg.Kafka.Consumer.headers in
           let delay = max 0.0 (retry_at -. Unix.gettimeofday ()) in
           (* ponytail: kafka-eio 0.1 hid Kafka_raw, so this loop can no longer
              librdkafka-pause the partition during the backoff sleep; the retry
              stream's bounded capacity still caps how far ahead librdkafka can
              prefetch. Revisit if that prefetch overhead matters. *)
           if delay > 0.001 then Eio.Time.sleep clock delay;
           let acked = ref false in
           let ack () =
             if not !acked then begin
               acked := true;
               Kafka.Consumer.commit retry_consumer raw_msg
             end else Ok ()
           in
           (match decode_retry raw_msg ~ack ~attempt with
            | Kafka.Consumer.Stop                                 -> ()
            | Kafka.Consumer.Continue | Kafka.Consumer.Error _ -> loop ())
         in
         (try loop () with Eio.Cancel.Cancelled _ -> ());
         Kafka.Consumer.close retry_consumer
       )
    );
    let decode_and_handle raw_msg ~ack =
      match Kafka_service_schema.decode_message topic raw_msg with
      | Error (e, raw_bytes) -> on_decode_error e ~raw_bytes ~ack
      | Ok (msg, trace_ctx)  ->
        match handler msg ~ack ~trace_ctx with
        | Kafka.Consumer.Continue -> Kafka.Consumer.Continue
        | Kafka.Consumer.Stop     -> Kafka.Consumer.Stop
        | Kafka.Consumer.Error _  ->
          let action = decide_action ~retry_topic:retry_topic_name
                         ~dlq_topic:dlq_topic_name
                         ~max_attempts ~attempt:1 in
          execute_action action ~raw_msg ~attempt:1 ~publish_raw ~ack;
          Kafka.Consumer.Continue
    in
    let no_retry : Kafka.Consumer.retry_policy =
      { base_delay_s = 0.0; max_delay_s = 0.0; max_attempts = 0 }
    in
    let result =
      Kafka.Consumer.consume_partitioned consumer ~sw ~clock
        ~retry:no_retry
        ~on_retry:(fun ~partition:_ ~attempt:_ ~delay_s:_ -> ())
        ~handler:decode_and_handle ()
    in
    Kafka.Consumer.close consumer;
    result
