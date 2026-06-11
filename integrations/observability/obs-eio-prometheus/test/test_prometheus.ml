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
(* Live Pushgateway tests (require PUSHGATEWAY_URL env var)           *)
(* ------------------------------------------------------------------ *)

(* Simple Prometheus instant-query helper — GET /api/v1/query?query=<metric> *)
let prometheus_query ~net ~url ~query =
  let pct q =
    let buf = Buffer.create (String.length q) in
    String.iter (fun c ->
      match c with
      | 'A'..'Z' | 'a'..'z' | '0'..'9' | '-' | '_' | '.' | '~' ->
        Buffer.add_char buf c
      | c -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c))
    ) q;
    Buffer.contents buf
  in
  let parse_host_port u default_port =
    let s = if String.length u >= 7 && String.sub u 0 7 = "http://"
            then String.sub u 7 (String.length u - 7) else u in
    let hp = match String.index_opt s '/' with
      | None -> s | Some i -> String.sub s 0 i in
    match String.rindex_opt hp ':' with
    | None -> (hp, default_port)
    | Some i ->
      let h = String.sub hp 0 i in
      let p = String.sub hp (i+1) (String.length hp - i - 1) in
      (match int_of_string_opt p with Some n -> (h, n) | None -> (hp, default_port))
  in
  let (host, port) = parse_host_port url 9090 in
  let path = "/api/v1/query?query=" ^ pct query in
  let req = String.concat "\r\n" [
    "GET " ^ path ^ " HTTP/1.1";
    Printf.sprintf "Host: %s:%d" host port;
    "Accept: application/json";
    "Connection: close";
    ""; "";
  ] in
  Eio.Net.with_tcp_connect net ~host ~service:(string_of_int port) (fun flow ->
    Eio.Flow.copy_string req flow;
    let buf = Eio.Buf_read.of_flow ~max_size:(256 * 1024) flow in
    ignore (Eio.Buf_read.line buf);
    let content_length = ref 0 in
    let rec read_headers () =
      let line = Eio.Buf_read.line buf in
      if line = "" then ()
      else begin
        let lower = String.lowercase_ascii line in
        if String.length lower > 15 && String.sub lower 0 15 = "content-length:" then
          (match int_of_string_opt (String.trim (String.sub line 15 (String.length line - 15)))
           with Some n -> content_length := n | None -> ());
        read_headers ()
      end
    in
    read_headers ();
    Eio.Buf_read.take !content_length buf)

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
      test_case "label values are escaped"              `Quick test_label_value_escaping;
    ];
    "concurrency", [
      test_case "no lost updates under concurrent emit" `Quick test_concurrent_emit;
    ];
    "live", [
      test_case "push to Pushgateway and verify in Prometheus" `Slow test_live_push;
    ];
  ]
