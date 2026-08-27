(* ── Fixtures ───────────────────────────────────────────────────────────── *)

module Ok_fn = struct
  let trigger = Fn.Cron "0 * * * *"
  let run () = Ok ()
end

module Err_fn = struct
  let trigger = Fn.Cron "0 * * * *"
  let run () = Error "something went wrong"
end

module Exn_fn = struct
  let trigger = Fn.Cron "0 * * * *"
  let run () = raise (Failure "boom")
end

module Lambda_fn = struct
  let trigger = Fn.Lambda
  let run () = Ok ()
end

let contains needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else if nl > hl then false
  else
    let found = ref false in
    for i = 0 to hl - nl do
      if not !found then begin
        let rec eq j =
          j >= nl ||
          (String.unsafe_get haystack (i + j) = String.unsafe_get needle j && eq (j + 1))
        in
        if eq 0 then found := true
      end
    done;
    !found

(* ── Test: run_ok ───────────────────────────────────────────────────────── *)

let test_run_ok () =
  Eio_main.run @@ fun env ->
  let module M = Fn.Make(Ok_fn) in
  M.run ~env ()

(* ── Test: run_error ────────────────────────────────────────────────────── *)

let test_run_error () =
  Eio_main.run @@ fun env ->
  let module M = Fn.Make(Err_fn) in
  let raised = ref false in
  (try M.run ~env ()
   with Failure msg ->
     if msg = "something went wrong" then raised := true);
  Alcotest.(check bool) "Failure raised" true !raised

(* ── Test: run_exception ────────────────────────────────────────────────── *)

let test_run_exception () =
  Eio_main.run @@ fun env ->
  let module M = Fn.Make(Exn_fn) in
  let raised = ref false in
  (try M.run ~env ()
   with Failure msg ->
     if msg = "boom" then raised := true);
  Alcotest.(check bool) "exception propagated" true !raised

(* ── Test: metrics_ok_counter ───────────────────────────────────────────── *)

let test_metrics_ok_counter () =
  Eio_main.run @@ fun env ->
  let module M = Fn.Make(Ok_fn) in
  let pair = Obs_prometheus.create () in
  let _, renderer = pair in
  M.run ~env ~backend:pair ();
  let output = renderer () in
  Alcotest.(check bool) "counter family present"
    true (contains "sun_fn_invocations_total" output);
  Alcotest.(check bool) "status=ok label present"
    true (contains {|status="ok"|} output)

(* ── Test: metrics_error_counter ────────────────────────────────────────── *)

let test_metrics_error_counter () =
  Eio_main.run @@ fun env ->
  let module M = Fn.Make(Err_fn) in
  let pair = Obs_prometheus.create () in
  let _, renderer = pair in
  (try M.run ~env ~backend:pair () with Failure _ -> ());
  let output = renderer () in
  Alcotest.(check bool) "status=error label present"
    true (contains {|status="error"|} output)

(* ── Test: metrics_duration ─────────────────────────────────────────────── *)

let test_metrics_duration () =
  Eio_main.run @@ fun env ->
  let module M = Fn.Make(Ok_fn) in
  let pair = Obs_prometheus.create () in
  let _, renderer = pair in
  M.run ~env ~backend:pair ();
  let output = renderer () in
  Alcotest.(check bool) "duration histogram present"
    true (contains "sun_fn_duration_seconds" output)

(* ── Test: push_error_no_raise ──────────────────────────────────────────── *)

(* Port 1 refuses connections — push_metrics must swallow the error and
   still return normally (or raise Failure for error runs, never hang). *)
let test_push_error_no_raise () =
  Eio_main.run @@ fun env ->
  let module M = Fn.Make(Ok_fn) in
  M.run ~env ~pushgateway_url:"http://127.0.0.1:1" ()

(* ── Test: lambda_trigger_requires_runtime_api ──────────────────────────── *)

(* Fn.Lambda's actual loop (Lambda_runtime.run_loop) is thoroughly tested in
   lambda-eio's own test suite, and the metrics-recording logic it calls
   into (record_and_push) is the exact same code path already exercised by
   every Cron test above — Fn.Lambda's marginal, sun-fn-specific surface is
   just "read AWS_LAMBDA_RUNTIME_API and fail fast if it's not set,
   otherwise hand off to the loop." That's what's tested here; a full
   run_loop iteration isn't separately re-tested at this layer, since doing
   so would mean either sending real OS signals to the test process (racy,
   and this module installs a single global Sys.set_signal handler that
   different tests would fight over) or re-deriving lambda-eio's own
   already-passing mock-server tests here for no new coverage. *)
(* Relies on AWS_LAMBDA_RUNTIME_API being unset in this test environment —
   true for any normal dev machine or CI runner, since it's an AWS-Lambda-
   execution-environment-specific variable nothing else would set. Not
   forced to be unset here: OCaml's Unix module in this version has no
   unsetenv (confirmed while writing https-eio's own tests earlier), so
   there's no clean way to force-clear it mid-test-suite if it somehow were
   set; skip rather than fake it if that assumption ever turns out false. *)
let test_lambda_trigger_requires_runtime_api () =
  if Sys.getenv_opt "AWS_LAMBDA_RUNTIME_API" <> None then
    Printf.printf "[skip] AWS_LAMBDA_RUNTIME_API is set in this environment — skipping\n%!"
  else
    Eio_main.run @@ fun env ->
    let module M = Fn.Make (Lambda_fn) in
    Alcotest.check_raises "Lambda trigger without AWS_LAMBDA_RUNTIME_API set raises Failure"
      (Failure "sun-fn: AWS_LAMBDA_RUNTIME_API is not set — not running in a Lambda execution environment (or a \
                local Runtime Interface Emulator)")
      (fun () -> M.run ~env ())

(* ── Runner ─────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "sun-fn" [
    "lifecycle", [
      Alcotest.test_case "run_ok"             `Quick test_run_ok;
      Alcotest.test_case "run_error"          `Quick test_run_error;
      Alcotest.test_case "run_exception"      `Quick test_run_exception;
    ];
    "metrics", [
      Alcotest.test_case "metrics_ok_counter"    `Quick test_metrics_ok_counter;
      Alcotest.test_case "metrics_error_counter" `Quick test_metrics_error_counter;
      Alcotest.test_case "metrics_duration"      `Quick test_metrics_duration;
    ];
    "push", [
      Alcotest.test_case "push_error_no_raise" `Quick test_push_error_no_raise;
    ];
    "lambda", [
      Alcotest.test_case "requires AWS_LAMBDA_RUNTIME_API" `Quick test_lambda_trigger_requires_runtime_api;
    ];
  ]
