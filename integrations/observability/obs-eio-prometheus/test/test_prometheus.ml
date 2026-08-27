(** Unit tests for obs-eio-prometheus. No external infrastructure required. *)

(* ------------------------------------------------------------------ *)
(* Helpers                                                             *)
(* ------------------------------------------------------------------ *)

let has_line output line =
  List.mem line (String.split_on_char '\n' output)

let contains s sub =
  let ls = String.length s and lp = String.length sub in
  if lp = 0 then true
  else if ls < lp then false
  else
    let rec go i =
      if i > ls - lp then false
      else if String.sub s i lp = sub then true
      else go (i + 1)
    in
    go 0

let make_event ?(labels = []) ?(context = []) ~name ~help kind =
  { Obs.name; help; kind; labels; context; service = "svc" }

let capture_stderr f =
  let old_stderr = Unix.dup Unix.stderr in
  let read_fd, write_fd = Unix.pipe () in
  Unix.dup2 write_fd Unix.stderr;
  Unix.close write_fd;
  let restored = ref false in
  let restore () =
    if not !restored then begin
      Unix.dup2 old_stderr Unix.stderr;
      Unix.close old_stderr;
      restored := true
    end
  in
  match f () with
  | result ->
    flush stderr;
    restore ();
    let ic = Unix.in_channel_of_descr read_fd in
    let buf = Buffer.create 128 in
    (try
       while true do
         Buffer.add_string buf (input_line ic);
         Buffer.add_char buf '\n'
       done
     with End_of_file -> ());
    close_in ic;
    (result, Buffer.contents buf)
  | exception exn ->
    restore ();
    Unix.close read_fd;
    raise exn

(* ------------------------------------------------------------------ *)
(* Counter                                                             *)
(* ------------------------------------------------------------------ *)

let test_counter_accumulates () =
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric
    (make_event ~name:"reqs" ~help:"Total requests" ~labels:[("method", "POST")]
       (`Counter 5));
  backend.Obs.emit_metric
    (make_event ~name:"reqs" ~help:"Total requests" ~labels:[("method", "POST")]
       (`Counter 3));
  backend.Obs.emit_metric
    (make_event ~name:"reqs" ~help:"Total requests" ~labels:[("method", "GET")]
       (`Counter 10));
  let out = render () in
  Alcotest.(check bool) "# TYPE counter"
    true (has_line out "# TYPE reqs counter");
  Alcotest.(check bool) "POST sum is 8"
    true (has_line out {|reqs{method="POST"} 8|});
  Alcotest.(check bool) "GET sum is 10"
    true (has_line out {|reqs{method="GET"} 10|})

let test_counter_no_labels () =
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric (make_event ~name:"total" ~help:"desc" (`Counter 7));
  backend.Obs.emit_metric (make_event ~name:"total" ~help:"desc" (`Counter 3));
  let out = render () in
  Alcotest.(check bool) "unlabeled counter sums to 10"
    true (has_line out "total 10")

(* ------------------------------------------------------------------ *)
(* Gauge                                                               *)
(* ------------------------------------------------------------------ *)

let test_gauge_last_write_wins () =
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric
    (make_event ~name:"queue_depth" ~help:"Queue depth" (`Gauge 100.0));
  backend.Obs.emit_metric
    (make_event ~name:"queue_depth" ~help:"Queue depth" (`Gauge 42.0));
  let out = render () in
  Alcotest.(check bool) "# TYPE gauge"
    true (has_line out "# TYPE queue_depth gauge");
  Alcotest.(check bool) "latest value wins"
    true (has_line out "queue_depth 42")

let test_gauge_labeled_independent () =
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric
    (make_event ~name:"g" ~help:"g" ~labels:[("host", "a")] (`Gauge 1.0));
  backend.Obs.emit_metric
    (make_event ~name:"g" ~help:"g" ~labels:[("host", "b")] (`Gauge 2.0));
  backend.Obs.emit_metric
    (make_event ~name:"g" ~help:"g" ~labels:[("host", "a")] (`Gauge 9.0));
  let out = render () in
  Alcotest.(check bool) {|host="a" updated to 9|}
    true (has_line out {|g{host="a"} 9|});
  Alcotest.(check bool) {|host="b" unchanged at 2|}
    true (has_line out {|g{host="b"} 2|})

(* ------------------------------------------------------------------ *)
(* Histogram                                                           *)
(* ------------------------------------------------------------------ *)

let test_histogram_buckets () =
  let (backend, render) = Obs_prometheus.create () in
  (* 0.007 falls in le=0.01 bucket; 0.042 falls in le=0.05 bucket *)
  backend.Obs.emit_metric
    (make_event ~name:"dur" ~help:"Duration" (`Histogram 0.007));
  backend.Obs.emit_metric
    (make_event ~name:"dur" ~help:"Duration" (`Histogram 0.042));
  let out = render () in
  Alcotest.(check bool) "# TYPE histogram"
    true (has_line out "# TYPE dur histogram");
  Alcotest.(check bool) "le=0.005 has 0 observations"
    true (has_line out {|dur_bucket{le="0.005"} 0|});
  Alcotest.(check bool) "le=0.01 has 1 observation"
    true (has_line out {|dur_bucket{le="0.01"} 1|});
  Alcotest.(check bool) "le=0.05 has 2 observations"
    true (has_line out {|dur_bucket{le="0.05"} 2|});
  Alcotest.(check bool) "+Inf has 2 observations"
    true (has_line out {|dur_bucket{le="+Inf"} 2|});
  Alcotest.(check bool) "sum is correct"
    true (has_line out "dur_sum 0.049");
  Alcotest.(check bool) "count is 2"
    true (has_line out "dur_count 2")

let test_histogram_labeled () =
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric
    (make_event ~name:"lat" ~help:"Latency" ~labels:[("route", "/charge")]
       (`Histogram 0.1));
  let out = render () in
  Alcotest.(check bool) "labeled bucket line"
    true (has_line out {|lat_bucket{route="/charge",le="0.1"} 1|});
  Alcotest.(check bool) "labeled sum line"
    true (has_line out {|lat_sum{route="/charge"} 0.1|})

(* ------------------------------------------------------------------ *)
(* Renderer output format                                              *)
(* ------------------------------------------------------------------ *)

let test_renderer_empty_when_no_events () =
  let (_backend, render) = Obs_prometheus.create () in
  Alcotest.(check string) "empty output before any events" "" (render ())

let test_renderer_includes_help_and_type () =
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric
    (make_event ~name:"http_requests_total" ~help:"Total HTTP requests" (`Counter 1));
  let out = render () in
  Alcotest.(check bool) "# HELP line present"
    true (has_line out "# HELP http_requests_total Total HTTP requests");
  Alcotest.(check bool) "# TYPE line present"
    true (has_line out "# TYPE http_requests_total counter")

let test_label_value_escaping () =
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric
    (make_event ~name:"g" ~help:"g"
       ~labels:[("msg", "hello \"world\"\nnewline")]
       (`Gauge 1.0));
  let out = render () in
  Alcotest.(check bool) "backslash-escaped label value"
    true (has_line out {|g{msg="hello \"world\"\nnewline"} 1|})

let test_help_text_escaping () =
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric
    (make_event ~name:"g" ~help:"line one\\nliteral, then a real\nnewline" (`Gauge 1.0));
  let out = render () in
  Alcotest.(check bool) "backslash and newline escaped in HELP text"
    true (has_line out {|# HELP g line one\\nliteral, then a real\nnewline|})

let test_help_mismatch_is_logged () =
  let (out, err) =
    capture_stderr (fun () ->
      let (backend, render) = Obs_prometheus.create () in
      backend.Obs.emit_metric (make_event ~name:"m" ~help:"first help" (`Counter 1));
      backend.Obs.emit_metric (make_event ~name:"m" ~help:"second help" (`Counter 1));
      render ())
  in
  Alcotest.(check bool) "first HELP text wins in rendered output"
    true (has_line out "# HELP m first help");
  Alcotest.(check bool) "mismatch logged to stderr"
    true (contains err
      "metric m registered with conflicting help text (keeping \"first help\", ignoring \"second help\")")

let test_kind_conflicts_are_logged () =
  let (out, err) =
    capture_stderr (fun () ->
      let (backend, render) = Obs_prometheus.create () in
      backend.Obs.emit_metric
        (make_event ~name:"same_metric" ~help:"counter" (`Counter 1));
      backend.Obs.emit_metric
        (make_event ~name:"same_metric" ~help:"gauge" (`Gauge 2.0));
      backend.Obs.emit_metric
        (make_event ~name:"same_metric" ~help:"histogram" (`Histogram 0.5));
      render ())
  in
  Alcotest.(check bool) "original counter family remains"
    true (has_line out "# TYPE same_metric counter");
  Alcotest.(check bool) "gauge conflict logged"
    true (contains err
      "metric family kind conflict for same_metric: existing counter, incoming gauge");
  Alcotest.(check bool) "histogram conflict logged"
    true (contains err
      "metric family kind conflict for same_metric: existing counter, incoming histogram")

let test_kind_conflicts_for_each_registered_kind () =
  let (_out, err) =
    capture_stderr (fun () ->
      let (backend, render) = Obs_prometheus.create () in
      backend.Obs.emit_metric
        (make_event ~name:"counter_first" ~help:"counter" (`Counter 1));
      backend.Obs.emit_metric
        (make_event ~name:"counter_first" ~help:"histogram" (`Histogram 0.5));
      backend.Obs.emit_metric
        (make_event ~name:"gauge_first" ~help:"gauge" (`Gauge 2.0));
      backend.Obs.emit_metric
        (make_event ~name:"gauge_first" ~help:"counter" (`Counter 1));
      backend.Obs.emit_metric
        (make_event ~name:"histogram_first" ~help:"histogram" (`Histogram 0.5));
      backend.Obs.emit_metric
        (make_event ~name:"histogram_first" ~help:"gauge" (`Gauge 2.0));
      render ())
  in
  Alcotest.(check bool) "counter rejects histogram"
    true (contains err
      "metric family kind conflict for counter_first: existing counter, incoming histogram");
  Alcotest.(check bool) "gauge rejects counter"
    true (contains err
      "metric family kind conflict for gauge_first: existing gauge, incoming counter");
  Alcotest.(check bool) "histogram rejects gauge"
    true (contains err
      "metric family kind conflict for histogram_first: existing histogram, incoming gauge")

(* ------------------------------------------------------------------ *)
(* Concurrency                                                         *)
(* ------------------------------------------------------------------ *)

let test_concurrent_emit () =
  Eio_main.run @@ fun _env ->
  let (backend, render) = Obs_prometheus.create () in
  let n_fibers = 100 in
  let n_emits  = 10  in
  let tasks = List.init n_fibers (fun _ ->
    fun () ->
      for _ = 1 to n_emits do
        backend.Obs.emit_metric
          (make_event ~name:"count" ~help:"test counter" (`Counter 1))
      done)
  in
  Eio.Fiber.all tasks;
  let out = render () in
  let expected = Printf.sprintf "count %d" (n_fibers * n_emits) in
  Alcotest.(check bool) "no lost updates under concurrent emit"
    true (has_line out expected)

(* ------------------------------------------------------------------ *)
(* Mock Pushgateway tests (no external infrastructure required)       *)
(* ------------------------------------------------------------------ *)

(* Spin up a minimal cohttp-eio server on an ephemeral port, run [f]
   with the bound port number, then shut down.  The server records the
   last PUT request it received in [last_req] so tests can inspect it. *)
let with_mock_pushgateway env ~status_code f =
  Eio.Switch.run @@ fun sw ->
  let last_method  = ref "" in
  let last_path    = ref "" in
  let last_ct      = ref "" in
  let last_body    = ref "" in
  let stop, stop_r = Eio.Promise.create () in
  let callback _conn req body =
    last_method := Http.Method.to_string (Http.Request.meth req);
    last_path   := Uri.path (Uri.of_string (Http.Request.resource req));
    last_ct     := (match Http.Header.get (Http.Request.headers req) "content-type" with
                    | Some v -> v | None -> "");
    last_body   := (let buf = Eio.Buf_read.of_flow body ~max_size:(64 * 1024) in
                    Eio.Buf_read.take_all buf);
    Cohttp_eio.Server.respond
      ~status:(Http.Status.of_int status_code)
      ~body:(Cohttp_eio.Body.of_string "")
      ()
  in
  let server = Cohttp_eio.Server.make ~callback () in
  let addr   = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
  let socket = Eio.Net.listen ~backlog:1 ~sw env#net addr in
  let port   = Eio.Net.listening_addr socket |> (function
    | `Tcp (_, p) -> p
    | _ -> failwith "unexpected address family") in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run ~stop ~on_error:(fun _ -> ()) socket server;
    `Stop_daemon);
  let result = f ~port ~last_method ~last_path ~last_ct ~last_body in
  Eio.Promise.resolve stop_r ();
  result

let test_push_empty_renderer () =
  (* push must return Ok () immediately without hitting the network when
     the renderer produces no output. *)
  Eio_main.run @@ fun env ->
  let (_backend, render) = Obs_prometheus.create () in
  (* No metrics emitted — render () = "" *)
  let result = Obs_prometheus.push ~net:env#net ~clock:env#clock
                 ~url:"http://localhost:9091" ~job:"test" render in
  Alcotest.(check (result unit string)) "empty renderer → Ok ()" (Ok ()) result

let test_push_simple_job () =
  Eio_main.run @@ fun env ->
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric
    (make_event ~name:"g" ~help:"h" (`Gauge 1.0));
  with_mock_pushgateway env ~status_code:200 (fun ~port ~last_method ~last_path ~last_ct ~last_body ->
    let url = Printf.sprintf "http://localhost:%d" port in
    let result = Obs_prometheus.push ~net:env#net ~clock:env#clock
                   ~url ~job:"my-worker" render in
    Alcotest.(check (result unit string)) "simple job → Ok ()" (Ok ()) result;
    Alcotest.(check string) "method is PUT"  "PUT"                !last_method;
    Alcotest.(check string) "path is correct" "/metrics/job/my-worker" !last_path;
    Alcotest.(check bool)   "content-type header"
      true (contains !last_ct "text/plain");
    Alcotest.(check bool)   "body non-empty" true (!last_body <> ""))

let test_push_job_name_escaping () =
  (* Job names with special characters must be percent-encoded in the path. *)
  Eio_main.run @@ fun env ->
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric
    (make_event ~name:"g" ~help:"h" (`Gauge 1.0));
  with_mock_pushgateway env ~status_code:200 (fun ~port ~last_method:_ ~last_path ~last_ct:_ ~last_body:_ ->
    let url = Printf.sprintf "http://localhost:%d" port in
    let result = Obs_prometheus.push ~net:env#net ~clock:env#clock
                   ~url ~job:"my job/v2" render in
    Alcotest.(check (result unit string)) "escaped job → Ok ()" (Ok ()) result;
    (* Space → %20, slash → %2F (or %2f) — neither must appear raw in the path *)
    Alcotest.(check bool) "space not raw in path"
      false (contains !last_path " ");
    (* The path must start with /metrics/job/ and after that no literal '/'
       from the job name should appear. *)
    let suffix = String.sub !last_path 13 (String.length !last_path - 13) in
    Alcotest.(check bool) "slash after /metrics/job/ not raw"
      false (contains suffix "/"))

let test_push_explicit_port () =
  Eio_main.run @@ fun env ->
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric
    (make_event ~name:"g" ~help:"h" (`Gauge 1.0));
  with_mock_pushgateway env ~status_code:202 (fun ~port ~last_method ~last_path ~last_ct:_ ~last_body:_ ->
    let url = Printf.sprintf "http://127.0.0.1:%d" port in
    let result = Obs_prometheus.push ~net:env#net ~clock:env#clock
                   ~url ~job:"worker" render in
    Alcotest.(check (result unit string)) "explicit port → Ok ()" (Ok ()) result;
    Alcotest.(check string) "method PUT" "PUT" !last_method;
    Alcotest.(check string) "path" "/metrics/job/worker" !last_path)

let test_push_non_2xx_response () =
  Eio_main.run @@ fun env ->
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric
    (make_event ~name:"g" ~help:"h" (`Gauge 1.0));
  with_mock_pushgateway env ~status_code:400 (fun ~port ~last_method:_ ~last_path:_ ~last_ct:_ ~last_body:_ ->
    let url = Printf.sprintf "http://localhost:%d" port in
    let result = Obs_prometheus.push ~net:env#net ~clock:env#clock
                   ~url ~job:"worker" render in
    match result with
    | Ok ()    -> Alcotest.fail "expected Error for 400 response"
    | Error msg ->
      Alcotest.(check bool) "error message contains 400"
        true (contains msg "400"))

let test_push_500_response () =
  Eio_main.run @@ fun env ->
  let (backend, render) = Obs_prometheus.create () in
  backend.Obs.emit_metric
    (make_event ~name:"g" ~help:"h" (`Gauge 1.0));
  with_mock_pushgateway env ~status_code:500 (fun ~port ~last_method:_ ~last_path:_ ~last_ct:_ ~last_body:_ ->
    let url = Printf.sprintf "http://localhost:%d" port in
    let result = Obs_prometheus.push ~net:env#net ~clock:env#clock
                   ~url ~job:"worker" render in
    match result with
    | Ok ()    -> Alcotest.fail "expected Error for 500 response"
    | Error msg ->
      Alcotest.(check bool) "error message contains 500"
        true (contains msg "500"))

(* ------------------------------------------------------------------ *)
(* Live Pushgateway tests (require PUSHGATEWAY_URL env var)           *)
(* ------------------------------------------------------------------ *)

(* Simple Prometheus instant-query helper — GET /api/v1/query?query=<metric> *)
let prometheus_query ~net ~url ~query =
  let uri = Uri.of_string
    (url ^ "/api/v1/query?query=" ^ Uri.pct_encode ~component:`Query_key query) in
  let client = Cohttp_eio.Client.make ~https:None net in
  Eio.Switch.run @@ fun sw ->
  let hdrs = Http.Header.of_list [("Accept", "application/json")] in
  let _resp, body =
    Cohttp_eio.Client.call client ~sw ~headers:hdrs `GET uri
  in
  Eio.Buf_read.(parse_exn take_all) body ~max_size:(256 * 1024)

let test_live_push () =
  match Sys.getenv_opt "PUSHGATEWAY_URL", Sys.getenv_opt "PROMETHEUS_URL" with
  | None, _ ->
    Printf.printf "[skip] PUSHGATEWAY_URL not set — skipping live push test\n%!"
  | Some pg_url, prom_url_opt ->
    Eio_main.run @@ fun env ->
    let unique_job =
      Printf.sprintf "sun-obs-test-%d" (int_of_float (Unix.gettimeofday ()))
    in
    let (backend, render) = Obs_prometheus.create () in
    backend.Obs.emit_metric
      (make_event ~name:"obs_test_counter_total" ~help:"obs-eio-prometheus live test counter"
         ~labels:[("job_name", unique_job)] (`Counter 42));
    backend.Obs.emit_metric
      (make_event ~name:"obs_test_gauge" ~help:"obs-eio-prometheus live test gauge"
         (`Gauge 3.14));
    (match Obs_prometheus.push ~net:env#net ~clock:env#clock
             ~url:pg_url ~job:unique_job render with
     | Error msg -> Alcotest.failf "push failed: %s" msg
     | Ok () -> ());
    (* Optionally verify via Prometheus query API — requires PROMETHEUS_URL. *)
    (match prom_url_opt with
     | None ->
       Printf.printf "  [info] PROMETHEUS_URL not set — skipping Prometheus query verification\n%!"
     | Some prom_url ->
       (* Wait for Prometheus to scrape the Pushgateway (prometheus.yml uses 5s interval). *)
       Eio.Time.sleep env#clock 7.0;
       let resp = prometheus_query ~net:env#net ~url:prom_url
                    ~query:("obs_test_counter_total{job=\"" ^ unique_job ^ "\"}") in
       Alcotest.(check bool) "metric present in Prometheus after scrape"
         true (contains resp "\"result\":[{"))

(* ------------------------------------------------------------------ *)
(* Test runner                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run "obs_prometheus" [
    "counter", [
      test_case "accumulates deltas across label sets"  `Quick test_counter_accumulates;
      test_case "unlabeled counter accumulates"         `Quick test_counter_no_labels;
    ];
    "gauge", [
      test_case "last write wins"                       `Quick test_gauge_last_write_wins;
      test_case "different label sets are independent"  `Quick test_gauge_labeled_independent;
    ];
    "histogram", [
      test_case "observations sorted into correct buckets" `Quick test_histogram_buckets;
      test_case "labeled histogram lines"                  `Quick test_histogram_labeled;
    ];
    "renderer", [
      test_case "empty string when no events"           `Quick test_renderer_empty_when_no_events;
      test_case "# HELP and # TYPE lines present"       `Quick test_renderer_includes_help_and_type;
      test_case "HELP text escapes backslash and newline" `Quick test_help_text_escaping;
      test_case "conflicting HELP text is logged"          `Quick test_help_mismatch_is_logged;
      test_case "label values are escaped"              `Quick test_label_value_escaping;
      test_case "conflicting metric kinds are logged"   `Quick test_kind_conflicts_are_logged;
      test_case "each family kind rejects conflicts"    `Quick test_kind_conflicts_for_each_registered_kind;
    ];
    "concurrency", [
      test_case "no lost updates under concurrent emit" `Quick test_concurrent_emit;
    ];
    "push", [
      test_case "empty renderer returns Ok immediately"       `Quick test_push_empty_renderer;
      test_case "simple job name PUT to correct path"        `Quick test_push_simple_job;
      test_case "job name with special chars is pct-encoded" `Quick test_push_job_name_escaping;
      test_case "explicit port in URL is honoured"           `Quick test_push_explicit_port;
      test_case "HTTP 400 response yields Error"             `Quick test_push_non_2xx_response;
      test_case "HTTP 500 response yields Error"             `Quick test_push_500_response;
    ];
    "live", [
      test_case "push to Pushgateway and verify in Prometheus" `Slow test_live_push;
    ];
  ]
