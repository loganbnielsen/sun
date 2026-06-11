(** Integration tests for kafka-eio-consumer against a local Redpanda broker.
    Seeds test messages via kafka-eio-producer, then consumes and verifies them.
    Run with: KAFKA_BROKERS=localhost:9092 dune test *)

let brokers =
  match Sys.getenv_opt "KAFKA_BROKERS" with
  | Some b -> [b]
  | None   -> ["localhost:9092"]

let test_topic = "sun-consumer-test"

let seed_messages sw n =
  let cfg : Kafka_producer.config = {
    brokers;
    delivery_mode = Kafka_producer.At_least_once;
    linger_ms = None;
    security  = Kafka_security.default;
  } in
  match Kafka_producer.create cfg ~sw with
  | Error e -> Alcotest.failf "seed producer create failed: %s" (Kafka_error.to_string e)
  | Ok producer ->
    let promises = List.init n (fun i ->
      Kafka_producer.produce_await producer
        ~topic:test_topic
        ~key:(Bytes.of_string (string_of_int i))
        ~value:(Bytes.of_string (Printf.sprintf "message-%04d" i)) ()
    ) in
    List.iter (fun p ->
      match Eio.Promise.await p with
      | Error e -> Alcotest.failf "seed produce_await failed: %s" (Kafka_error.to_string e)
      | Ok () -> ()
    ) promises;
    Kafka_producer.close producer

let make_consumer_config () : Kafka_consumer.config = {
  brokers;
  group_id     = Printf.sprintf "sun-test-%d" (Unix.getpid ());
  topics       = [test_topic];
  offset_reset = Kafka_consumer.Earliest;
  auto_commit  = false;
  on_rebalance = None;
  security     = Kafka_security.default;
}

let test_poll_messages () =
  Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
      seed_messages sw 5;

      match Kafka_consumer.create (make_consumer_config ()) ~sw with
      | Error e ->
        Alcotest.failf "consumer create failed: %s" (Kafka_error.to_string e)
      | Ok consumer ->
        let received = ref [] in
        let stream = Kafka_consumer.stream consumer in
        (match Eio.Time.with_timeout env#clock 10.0 (fun () ->
          while List.length !received < 5 do
            let msg = Eio.Stream.take stream in
            received := msg :: !received;
            ignore (Kafka_consumer.commit consumer msg)
          done;
          Ok ()
        ) with
        | Error `Timeout -> Alcotest.fail "timed out waiting for messages"
        | Ok () -> ());
        Alcotest.(check int) "received 5 messages" 5 (List.length !received);
        Kafka_consumer.close consumer

let test_consume_with_ack () =
  Eio_main.run @@ fun _env ->
    Eio.Switch.run @@ fun sw ->
      seed_messages sw 3;

      match Kafka_consumer.create (make_consumer_config ()) ~sw with
      | Error e ->
        Alcotest.failf "consumer create failed: %s" (Kafka_error.to_string e)
      | Ok consumer ->
        let count = ref 0 in
        let _ =
          Kafka_consumer.consume consumer ~handler:(fun _msg ~ack ->
            ack ();
            incr count;
            if !count >= 3 then Kafka_consumer.Stop
            else Kafka_consumer.Continue
          )
        in
        Alcotest.(check int) "consumed 3 messages" 3 !count;
        Kafka_consumer.close consumer

let test_stream_api () =
  Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
      seed_messages sw 4;

      match Kafka_consumer.create (make_consumer_config ()) ~sw with
      | Error e ->
        Alcotest.failf "consumer create failed: %s" (Kafka_error.to_string e)
      | Ok consumer ->
        let stream = Kafka_consumer.stream consumer in
        let msgs = ref [] in
        (match Eio.Time.with_timeout env#clock 10.0 (fun () ->
          for _ = 1 to 4 do
            let msg = Eio.Stream.take stream in
            msgs := msg :: !msgs
          done;
          Ok ()
        ) with
        | Error `Timeout -> Alcotest.fail "timed out waiting for stream messages"
        | Ok () -> ());
        Alcotest.(check int) "stream yielded 4 messages" 4 (List.length !msgs);
        Kafka_consumer.close consumer

let () =
  let open Alcotest in
  run "kafka_consumer_integration" [
    "consume", [
      test_case "poll messages"    `Slow test_poll_messages;
      test_case "consume with ack" `Slow test_consume_with_ack;
      test_case "stream api"       `Slow test_stream_api;
    ];
  ]
