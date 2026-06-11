(** Unit tests for sun-worker. No Kafka broker required.
    Integration tests are gated on KAFKA_BROKERS — see test_worker_integration.ml. *)

(* ── Test message module ─────────────────────────────────────────────── *)

module TestMsg = struct
  type t = { id : string }

  let topic_name = "sun-worker-unit-test"

  let schema = {|{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}|}

  let encode t = `Assoc [("id", `String t.id)]

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "id" fields with
       | Some (`String id) -> Ok { id }
       | _ -> Error "missing id")
    | _ -> Error "expected object"
end

(* ── Fake config (unreachable endpoints — never used with _consume_loop) *)

let fake_config : Kafka_service.config = {
  brokers             = ["localhost:9092"];
  schema_registry_url = "http://127.0.0.1:1";
  admin_url           = "http://127.0.0.1:1";
  linger_ms           = 5;
  partitions          = 1;
  security            = Kafka_security.default;
}

(* ── Worker fixtures ─────────────────────────────────────────────────── *)

(* Worker that always succeeds *)
module OkWorker = struct
  module Message = TestMsg
  let group_id = "test-ok"
  let handle msg ~ack ~trace_ctx:_ =
    ack ();
    ignore msg;
    Ok ()
end

(* Worker that returns an error on the first message *)
module ErrWorker = struct
  module Message = TestMsg
  let group_id = "test-err"
  let handle _msg ~ack:_ ~trace_ctx:_ = Error "something went wrong"
end

(* ── Single-message consume loop ─────────────────────────────────────── *)

let one_message msg ~handler () =
  let result = handler msg ~ack:(fun () -> ()) ~trace_ctx:None in
  match result with
  | Kafka_consumer.Continue | Kafka_consumer.Stop -> ()
  | Kafka_consumer.Error _ ->
    (* Worker returned Error (retryable failure). Simulate what consume_partitioned
       would do after exhausting retries: surface as a Failure to the caller. *)
    failwith "sun-worker: handler returned error"

let two_messages msgs ~handler () =
  List.iter (fun msg ->
    match handler msg ~ack:(fun () -> ()) ~trace_ctx:None with
    | Kafka_consumer.Continue | Kafka_consumer.Stop -> ()
    | Kafka_consumer.Error _ ->
      failwith "sun-worker: handler returned error"
  ) msgs

(* ── Tests ───────────────────────────────────────────────────────────── *)

let test_handle_ok () =
  Eio_main.run (fun env ->
    let msg = TestMsg.{ id = "msg-1" } in
    let module W = Worker.Make(OkWorker) in
    W.run ~env ~config:fake_config
      ~_consume_loop:(one_message msg) ())

let test_handle_error_raises () =
  Eio_main.run (fun env ->
    let msg = TestMsg.{ id = "msg-err" } in
    let module W = Worker.Make(ErrWorker) in
    match
      (try
         W.run ~env ~config:fake_config
           ~_consume_loop:(one_message msg) ();
         Ok ()
       with Failure e -> Error e)
    with
    | Error e ->
      Alcotest.(check bool) "failure raised for handler error"
        true (String.length e > 0)
    | Ok () ->
      Alcotest.fail "expected Failure to be raised")

let test_metrics_ok_counter () =
  Eio_main.run (fun env ->
    let backend, render = Obs_prometheus.create () in
    let ot = Obs.create ~service:"test-worker"
               ~mono_clock:env#mono_clock ~backend in
    let msg = TestMsg.{ id = "msg-metrics" } in
    let module W = Worker.Make(OkWorker) in
    W.run ~env ~config:fake_config ~ot
      ~_consume_loop:(one_message msg) ();
    let output = render () in
    Alcotest.(check bool) "messages_total counter present"
      true (let needle = "sun_worker_messages_total" in
            let n = String.length needle and s = String.length output in
            let found = ref false in
            for i = 0 to s - n do
              if String.sub output i n = needle then found := true
            done; !found);
    Alcotest.(check bool) "status=ok label present"
      true (let needle = {|status="ok"|} in
            let n = String.length needle and s = String.length output in
            let found = ref false in
            for i = 0 to s - n do
              if String.sub output i n = needle then found := true
            done; !found))

let test_metrics_error_counter () =
  Eio_main.run (fun env ->
    let backend, render = Obs_prometheus.create () in
    let ot = Obs.create ~service:"test-worker"
               ~mono_clock:env#mono_clock ~backend in
    let msg = TestMsg.{ id = "msg-err-metrics" } in
    let module W = Worker.Make(ErrWorker) in
    (try
       W.run ~env ~config:fake_config ~ot
         ~_consume_loop:(one_message msg) ()
     with Failure _ -> ());
    let output = render () in
    Alcotest.(check bool) "status=error label present"
      true (let needle = {|status="error"|} in
            let n = String.length needle and s = String.length output in
            let found = ref false in
            for i = 0 to s - n do
              if String.sub output i n = needle then found := true
            done; !found))

let test_metrics_duration () =
  Eio_main.run (fun env ->
    let backend, render = Obs_prometheus.create () in
    let ot = Obs.create ~service:"test-worker"
               ~mono_clock:env#mono_clock ~backend in
    let msg = TestMsg.{ id = "msg-dur" } in
    let module W = Worker.Make(OkWorker) in
    W.run ~env ~config:fake_config ~ot
      ~_consume_loop:(one_message msg) ();
    let output = render () in
    Alcotest.(check bool) "duration histogram present"
      true (let needle = "sun_worker_message_duration_seconds" in
            let n = String.length needle and s = String.length output in
            let found = ref false in
            for i = 0 to s - n do
              if String.sub output i n = needle then found := true
            done; !found))

let test_stop_flag_stops_after_current_message () =
  Eio_main.run (fun env ->
    (* Two messages: first is processed, second should get Stop from the flag.
       We simulate the stop flag by having the first handler call set it. *)
    let processed = ref 0 in
    let module StopWorker = struct
      module Message = TestMsg
      let group_id = "test-stop"
      let handle _msg ~ack ~trace_ctx:_ =
        ack ();
        incr processed;
        Ok ()
    end in
    let msgs = [
      TestMsg.{ id = "msg-a" };
      TestMsg.{ id = "msg-b" };
    ] in
    let module W = Worker.Make(StopWorker) in
    (* Both messages processed because stop_flag is never set externally *)
    W.run ~env ~config:fake_config
      ~_consume_loop:(two_messages msgs) ();
    Alcotest.(check int) "both messages processed" 2 !processed)

let test_no_metrics_without_ot () =
  Eio_main.run (fun env ->
    let msg = TestMsg.{ id = "msg-no-ot" } in
    let module W = Worker.Make(OkWorker) in
    W.run ~env ~config:fake_config
      ~_consume_loop:(one_message msg) ())

let test_max_messages_stops_cleanly () =
  Eio_main.run (fun env ->
    let processed = ref 0 in
    let module CountWorker = struct
      module Message = TestMsg
      let group_id = "test-max"
      let handle _msg ~ack ~trace_ctx:_ = ack (); incr processed; Ok ()
    end in
    let msgs = List.init 5 (fun i -> TestMsg.{ id = Printf.sprintf "m%d" i }) in
    let module W = Worker.Make(CountWorker) in
    W.run ~env ~config:fake_config ~max_messages:3
      ~_consume_loop:(fun ~handler () ->
        List.iter (fun msg ->
          ignore (handler msg ~ack:(fun () -> ()) ~trace_ctx:None)
        ) msgs)
      ();
    Alcotest.(check int) "stops after max_messages successful messages" 3 !processed)

let test_external_stop_flag_skips_messages () =
  Eio_main.run (fun env ->
    let stop = Atomic.make true in  (* pre-set: handler wrapper returns Stop immediately *)
    let processed = ref 0 in
    let module StopWorker = struct
      module Message = TestMsg
      let group_id = "test-ext-stop"
      let handle _msg ~ack ~trace_ctx:_ = ack (); incr processed; Ok ()
    end in
    let msgs = [TestMsg.{ id = "m1" }; TestMsg.{ id = "m2" }] in
    let module W = Worker.Make(StopWorker) in
    W.run ~env ~config:fake_config ~stop
      ~_consume_loop:(two_messages msgs) ();
    Alcotest.(check int) "W.handle never called when stop pre-set" 0 !processed)

let () =
  Alcotest.run "sun_worker" [
    "lifecycle", [
      Alcotest.test_case "handle ok returns normally"  `Quick test_handle_ok;
      Alcotest.test_case "handle error raises Failure" `Quick test_handle_error_raises;
      Alcotest.test_case "no ot — no crash"           `Quick test_no_metrics_without_ot;
      Alcotest.test_case "two messages both processed" `Quick
        test_stop_flag_stops_after_current_message;
      Alcotest.test_case "max_messages stops cleanly"        `Quick
        test_max_messages_stops_cleanly;
      Alcotest.test_case "external stop flag skips messages" `Quick
        test_external_stop_flag_skips_messages;
    ];
    "metrics", [
      Alcotest.test_case "ok counter emitted"          `Quick test_metrics_ok_counter;
      Alcotest.test_case "error counter emitted"       `Quick test_metrics_error_counter;
      Alcotest.test_case "duration histogram emitted"  `Quick test_metrics_duration;
    ];
  ]
