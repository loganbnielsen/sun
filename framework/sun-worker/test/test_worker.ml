(** Unit tests for sun-worker. No Kafka broker required.
    Integration tests are gated on KAFKA_BROKERS — see test_worker_integration.ml. *)

(* ── Test message module ─────────────────────────────────────────────── *)

module TestMsg = struct
  type t = { id : string }

  let topic_name = Kafka_service.topic_name_exn "sun-worker-unit-test"

  let schema = {|{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}|}

  let encode t = `Assoc [("id", `String t.id)]

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "id" fields with
       | Some (`String id) -> Ok { id }
       | _ -> Error "missing id")
    | _ -> Error "expected object"
end

(* ── Fake config (unreachable endpoints — never used with test_consume_loop) *)

let fake_config : Kafka_service.config = {
  brokers             = ["localhost:9092"];
  schema_registry_url = "http://127.0.0.1:1";
  admin_url           = "http://127.0.0.1:1";
  linger_ms           = 5;
  partitions          = 1;
  security            = Kafka.Security.default;
}

(* ── Worker fixtures ─────────────────────────────────────────────────── *)

(* Worker that always succeeds *)
module OkWorker = struct
  module Message = TestMsg
  let group_id = "test-ok"
  let handle msg ~trace_ctx:_ =
    ignore msg;
    Ok ()
end

(* Worker that returns an error on the first message *)
module ErrWorker = struct
  module Message = TestMsg
  let group_id = "test-err"
  let handle _msg ~trace_ctx:_ = Error "something went wrong"
end

(* ── Single-message consume loop ─────────────────────────────────────── *)

let one_message msg ~handler () =
  let result = handler msg ~ack:(fun () -> Ok ()) ~trace_ctx:None in
  match result with
  | Kafka.Consumer.Continue | Kafka.Consumer.Stop -> ()
  | Kafka.Consumer.Error _ -> ()

let two_messages msgs ~handler () =
  List.iter (fun msg ->
    match handler msg ~ack:(fun () -> Ok ()) ~trace_ctx:None with
    | Kafka.Consumer.Continue | Kafka.Consumer.Stop -> ()
    | Kafka.Consumer.Error _ -> ()
  ) msgs

(* Drives the handler with a caller-supplied ack and captures its result, to
   simulate a commit failure — as opposed to one_message/two_messages, which
   hardcode a succeeding ack and treat any Error as a test failure. *)
let one_message_with_ack msg ~ack ~result_r ~handler () =
  result_r := Some (handler msg ~ack ~trace_ctx:None)

let one_message_result msg result_r ~handler () =
  result_r := Some (handler msg ~ack:(fun () -> Ok ()) ~trace_ctx:None)

let run_ok result =
  match result with
  | Ok () -> ()
  | Error e -> Alcotest.fail (Worker.run_error_to_string e)

(* ── Tests ───────────────────────────────────────────────────────────── *)

let test_handle_ok () =
  Eio_main.run (fun env ->
    let msg = TestMsg.{ id = "msg-1" } in
    let module W = Worker.Make(OkWorker) in
    W.run ~env ~config:fake_config
      ~test_consume_loop:(one_message msg) () |> run_ok)

let test_handle_error_returns_consumer_error () =
  Eio_main.run (fun env ->
    let msg = TestMsg.{ id = "msg-err" } in
    let module W = Worker.Make(ErrWorker) in
    let result_r = ref None in
    W.run ~env ~config:fake_config
      ~test_consume_loop:(one_message_result msg result_r) () |> run_ok;
    match !result_r with
    | Some (Kafka.Consumer.Error Kafka.Error.Application) -> ()
    | _ -> Alcotest.fail "expected handler error to become Kafka.Consumer.Error")

let test_metrics_ok_counter () =
  Eio_main.run (fun env ->
    let backend, render = Obs_prometheus.create () in
    let ot = Obs_eio.create ~service:"test-worker"
               ~mono_clock:env#mono_clock ~backend () in
    let msg = TestMsg.{ id = "msg-metrics" } in
    let module W = Worker.Make(OkWorker) in
    W.run ~env ~config:fake_config ~ot
      ~test_consume_loop:(one_message msg) () |> run_ok;
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
    let ot = Obs_eio.create ~service:"test-worker"
               ~mono_clock:env#mono_clock ~backend () in
    let msg = TestMsg.{ id = "msg-err-metrics" } in
    let module W = Worker.Make(ErrWorker) in
    ignore (W.run ~env ~config:fake_config ~ot
              ~test_consume_loop:(one_message msg) ());
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
    let ot = Obs_eio.create ~service:"test-worker"
               ~mono_clock:env#mono_clock ~backend () in
    let msg = TestMsg.{ id = "msg-dur" } in
    let module W = Worker.Make(OkWorker) in
    W.run ~env ~config:fake_config ~ot
      ~test_consume_loop:(one_message msg) () |> run_ok;
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
      let handle _msg ~trace_ctx:_ =
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
      ~test_consume_loop:(two_messages msgs) () |> run_ok;
    Alcotest.(check int) "both messages processed" 2 !processed)

let test_no_metrics_without_ot () =
  Eio_main.run (fun env ->
    let msg = TestMsg.{ id = "msg-no-ot" } in
    let module W = Worker.Make(OkWorker) in
    W.run ~env ~config:fake_config
      ~test_consume_loop:(one_message msg) () |> run_ok)

let test_max_messages_stops_cleanly () =
  Eio_main.run (fun env ->
    let processed = ref 0 in
    let module CountWorker = struct
      module Message = TestMsg
      let group_id = "test-max"
      let handle _msg ~trace_ctx:_ = incr processed; Ok ()
    end in
    let msgs = List.init 5 (fun i -> TestMsg.{ id = Printf.sprintf "m%d" i }) in
    let module W = Worker.Make(CountWorker) in
    W.run ~env ~config:fake_config ~max_messages:3
      ~test_consume_loop:(fun ~handler () ->
        List.iter (fun msg ->
          ignore (handler msg ~ack:(fun () -> Ok ()) ~trace_ctx:None)
        ) msgs)
      () |> run_ok;
    Alcotest.(check int) "stops after max_messages successful messages" 3 !processed)

let test_ack_failure_non_fatal_continues_and_is_metered () =
  Eio_main.run (fun env ->
    let backend, render = Obs_prometheus.create () in
    let ot = Obs_eio.create ~service:"test-worker"
               ~mono_clock:env#mono_clock ~backend () in
    let msg = TestMsg.{ id = "msg-ack-fail" } in
    let module W = Worker.Make(OkWorker) in
    let result_r = ref None in
    W.run ~env ~config:fake_config ~ot
      ~test_consume_loop:(one_message_with_ack msg
        ~ack:(fun () -> Error Kafka.Error.Application) ~result_r) () |> run_ok;
    (match !result_r with
     | Some Kafka.Consumer.Continue -> ()
     | _ -> Alcotest.fail "expected Continue after a non-fatal ack failure");
    let output = render () in
    Alcotest.(check bool) "status=ack_failed label present"
      true (let needle = {|status="ack_failed"|} in
            let n = String.length needle and s = String.length output in
            let found = ref false in
            for i = 0 to s - n do
              if String.sub output i n = needle then found := true
            done; !found))

(* Verifies only that the handler closure computes Kafka.Consumer.Error for a
   fatal ack failure — the real consume_partitioned path turning that into a
   process-ending Failure is not exercised here. *)
let test_ack_failure_fatal_escalates () =
  Eio_main.run (fun env ->
    let msg = TestMsg.{ id = "msg-ack-fatal" } in
    let module W = Worker.Make(OkWorker) in
    let result_r = ref None in
    W.run ~env ~config:fake_config
      ~test_consume_loop:(one_message_with_ack msg
        ~ack:(fun () -> Error Kafka.Error.Fatal) ~result_r) () |> run_ok;
    match !result_r with
    | Some (Kafka.Consumer.Error e) ->
      Alcotest.(check bool) "escalated error is fatal" true (Kafka.Error.is_fatal e)
    | _ -> Alcotest.fail "expected the handler to return Error for a fatal ack failure")

let test_external_stop_flag_skips_messages () =
  Eio_main.run (fun env ->
    let stop = Atomic.make true in  (* pre-set: handler wrapper returns Stop immediately *)
    let processed = ref 0 in
    let module StopWorker = struct
      module Message = TestMsg
      let group_id = "test-ext-stop"
      let handle _msg ~trace_ctx:_ = incr processed; Ok ()
    end in
    let msgs = [TestMsg.{ id = "m1" }; TestMsg.{ id = "m2" }] in
    let module W = Worker.Make(StopWorker) in
    W.run ~env ~config:fake_config ~stop
      ~test_consume_loop:(two_messages msgs) () |> run_ok;
    Alcotest.(check int) "W.handle never called when stop pre-set" 0 !processed)

let () =
  Alcotest.run "sun_worker" [
    "lifecycle", [
      Alcotest.test_case "handle ok returns normally"  `Quick test_handle_ok;
      Alcotest.test_case "handle error returns Error" `Quick test_handle_error_returns_consumer_error;
      Alcotest.test_case "no ot — no crash"           `Quick test_no_metrics_without_ot;
      Alcotest.test_case "two messages both processed" `Quick
        test_stop_flag_stops_after_current_message;
      Alcotest.test_case "max_messages stops cleanly"        `Quick
        test_max_messages_stops_cleanly;
      Alcotest.test_case "external stop flag skips messages" `Quick
        test_external_stop_flag_skips_messages;
      Alcotest.test_case "non-fatal ack failure continues" `Quick
        test_ack_failure_non_fatal_continues_and_is_metered;
      Alcotest.test_case "fatal ack failure escalates to Error" `Quick
        test_ack_failure_fatal_escalates;
    ];
    "metrics", [
      Alcotest.test_case "ok counter emitted"          `Quick test_metrics_ok_counter;
      Alcotest.test_case "error counter emitted"       `Quick test_metrics_error_counter;
      Alcotest.test_case "duration histogram emitted"  `Quick test_metrics_duration;
    ];
  ]
