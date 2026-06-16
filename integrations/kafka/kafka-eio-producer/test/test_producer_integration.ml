(** Integration tests for kafka-eio-producer against a local Redpanda broker.
    Requires: rpk redpanda start (or equivalent) before running.
    Override broker location with the standard Kafka broker environment variable. *)

let test_topic = "sun-producer-test"

let test_produce_fire_and_forget () =
  Eio_main.run @@ fun _ ->
    Eio.Switch.run @@ fun sw ->
      match Kafka_producer.create (Kafka_test_helpers.default_producer_config ()) ~sw with
      | Error e ->
        Alcotest.failf "create failed: %s" (Kafka_error.to_string e)
      | Ok producer ->
        (match Kafka_producer.produce producer ~topic:test_topic
                 ~value:(Bytes.of_string "hello-fire-and-forget") () with
         | Error e -> Alcotest.failf "produce failed: %s" (Kafka_error.to_string e)
         | Ok () ->
           match Kafka_producer.flush producer ~timeout_ms:5000 with
           | Error e -> Alcotest.failf "flush failed: %s" (Kafka_error.to_string e)
           | Ok ()   -> ());
        Kafka_producer.close producer

let test_produce_await () =
  Eio_main.run @@ fun _ ->
    Eio.Switch.run @@ fun sw ->
      match Kafka_producer.create (Kafka_test_helpers.default_producer_config ()) ~sw with
      | Error e ->
        Alcotest.failf "create failed: %s" (Kafka_error.to_string e)
      | Ok producer ->
        let promise =
          Kafka_producer.produce_await producer
            ~topic:test_topic
            ~value:(Bytes.of_string "hello-awaited") ()
        in
        (match Eio.Promise.await promise with
         | Error e -> Alcotest.failf "produce_await failed: %s" (Kafka_error.to_string e)
         | Ok ()   -> ());
        Kafka_producer.close producer

let test_produce_with_key () =
  Eio_main.run @@ fun _ ->
    Eio.Switch.run @@ fun sw ->
      match Kafka_producer.create (Kafka_test_helpers.default_producer_config ()) ~sw with
      | Error e ->
        Alcotest.failf "create failed: %s" (Kafka_error.to_string e)
      | Ok producer ->
        let promise =
          Kafka_producer.produce_await producer
            ~topic:test_topic
            ~value:(Bytes.of_string "hello-keyed")
            ~key:(Bytes.of_string "my-key") ()
        in
        (match Eio.Promise.await promise with
         | Error e -> Alcotest.failf "produce_await with key failed: %s" (Kafka_error.to_string e)
         | Ok ()   -> ());
        Kafka_producer.close producer

let test_produce_many () =
  Eio_main.run @@ fun _ ->
    Eio.Switch.run @@ fun sw ->
      match Kafka_producer.create (Kafka_test_helpers.default_producer_config ()) ~sw with
      | Error e ->
        Alcotest.failf "create failed: %s" (Kafka_error.to_string e)
      | Ok producer ->
        let promises = List.init 100 (fun i ->
          Kafka_producer.produce_await producer
            ~topic:test_topic
            ~value:(Bytes.of_string (Printf.sprintf "msg-%04d" i)) ()
        ) in
        List.iter (fun p ->
          match Eio.Promise.await p with
          | Error e -> Alcotest.failf "batch produce_await failed: %s" (Kafka_error.to_string e)
          | Ok ()   -> ()
        ) promises;
        Kafka_producer.close producer

let () =
  let open Alcotest in
  run "kafka_producer_integration" [
    "produce", [
      test_case "fire-and-forget" `Slow test_produce_fire_and_forget;
      test_case "produce_await"   `Slow test_produce_await;
      test_case "with key"        `Slow test_produce_with_key;
      test_case "100 messages"    `Slow test_produce_many;
    ];
  ]
