(* ── Fixtures ───────────────────────────────────────────────────────────── *)

module Ok_fn = struct
  let schedule = "0 * * * *"
  let run () = Ok ()
end

module Err_fn = struct
  let schedule = "0 * * * *"
  let run () = Error "something went wrong"
end

module Exn_fn = struct
  let schedule = "0 * * * *"
  let run () = raise (Failure "boom")
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
  ]
