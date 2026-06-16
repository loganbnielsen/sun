let decode_message (topic : 'a Kafka_service_intf.topic)
    ~on_decode_error
    (raw_msg : Kafka_consumer.message)
    ~ack
    handler =
  let trace_ctx = Obs_trace.extract_from_headers raw_msg.Kafka_consumer.headers in
  let raw_bytes = raw_msg.Kafka_consumer.value in
  match Kafka_service_schema.decode_wire raw_bytes with
  | Error e -> on_decode_error e ~raw_bytes ~ack
  | Ok (_schema_id, json_str) ->
    match (try Ok (Yojson.Safe.from_string json_str)
           with exn -> Error (Printexc.to_string exn)) with
    | Error e -> on_decode_error ("json parse: " ^ e) ~raw_bytes ~ack
    | Ok json ->
      match topic.decode json with
      | Error e -> on_decode_error ("message decode: " ^ e) ~raw_bytes ~ack
      | Ok msg  -> handler msg ~ack ~trace_ctx
