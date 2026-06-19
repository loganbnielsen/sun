(** Unit tests for obs-eio. No broker required. *)

let () = Random.init 42  (* deterministic trace IDs *)

(* ------------------------------------------------------------------ *)
(* Obs_trace                                                           *)
(* ------------------------------------------------------------------ *)

let test_traceparent_roundtrip () =
  let ctx = Obs_trace.generate () in
  match Obs_trace.of_traceparent (Obs_trace.to_traceparent ctx) with
  | None -> Alcotest.fail "of_traceparent returned None on valid traceparent"
  | Some ctx2 ->
    Alcotest.(check bool) "trace_id preserved" true (ctx.trace_id = ctx2.trace_id);
    Alcotest.(check bool) "span_id preserved"  true (ctx.span_id  = ctx2.span_id);
    Alcotest.(check char) "flags preserved"    ctx.trace_flags ctx2.trace_flags

let test_child_span () =
  let root  = Obs_trace.generate () in
  let child = Obs_trace.child_span root in
  Alcotest.(check bool) "same trace_id"     true  (root.trace_id = child.trace_id);
  Alcotest.(check bool) "different span_id" false (root.span_id  = child.span_id)

let test_of_traceparent_malformed () =
  Alcotest.(check bool) "garbage" true (Obs_trace.of_traceparent "garbage" = None);
  Alcotest.(check bool) "wrong version" true
    (Obs_trace.of_traceparent
       "01-00000000000000000000000000000001-0000000000000001-01" = None)

let test_inject_extract_headers () =
  let ctx     = Obs_trace.generate () in
  let headers = Obs_trace.inject_to_headers ctx [("content-type", "application/json")] in
  Alcotest.(check bool) "traceparent present"
    true (List.mem_assoc Obs_trace.traceparent_header headers);
  Alcotest.(check bool) "original header preserved"
    true (List.assoc_opt "content-type" headers = Some "application/json");
  match Obs_trace.extract_from_headers headers with
  | None      -> Alcotest.fail "extract returned None"
  | Some ctx2 ->
    Alcotest.(check bool) "trace_id round-trips" true (ctx.trace_id = ctx2.trace_id);
    Alcotest.(check bool) "span_id round-trips"  true (ctx.span_id  = ctx2.span_id)

let test_inject_replaces_existing () =
  let ctx1    = Obs_trace.generate () in
  let ctx2    = Obs_trace.generate () in
  let headers = Obs_trace.inject_to_headers ctx1 [] in
  let headers = Obs_trace.inject_to_headers ctx2 headers in
  Alcotest.(check int) "exactly one traceparent"
    1
    (List.length
       (List.filter (fun (k, _) -> k = Obs_trace.traceparent_header) headers));
  match Obs_trace.extract_from_headers headers with
  | None      -> Alcotest.fail "extract returned None"
  | Some ctx3 -> Alcotest.(check bool) "latest wins" true (ctx2.span_id = ctx3.span_id)

let test_extract_headers_case_insensitive () =
  let ctx     = Obs_trace.generate () in
  let headers = [("TraceParent", Obs_trace.to_traceparent ctx)] in
  match Obs_trace.extract_from_headers headers with
  | None      -> Alcotest.fail "extract returned None"
  | Some ctx2 ->
    Alcotest.(check bool) "trace_id round-trips" true (ctx.trace_id = ctx2.trace_id);
    Alcotest.(check bool) "span_id round-trips"  true (ctx.span_id  = ctx2.span_id)

let test_inject_replaces_existing_case_insensitive () =
  let ctx1    = Obs_trace.generate () in
  let ctx2    = Obs_trace.generate () in
  let headers = [
    ("TraceParent", Obs_trace.to_traceparent ctx1);
    ("content-type", "application/json");
  ] in
  let headers = Obs_trace.inject_to_headers ctx2 headers in
  Alcotest.(check int) "exactly one traceparent variant"
    1 (List.length (List.filter
         (fun (k, _) -> String.lowercase_ascii k = Obs_trace.traceparent_header)
         headers));
  Alcotest.(check bool) "canonical traceparent present"
    true (List.mem_assoc Obs_trace.traceparent_header headers);
  Alcotest.(check bool) "original header preserved"
    true (List.assoc_opt "content-type" headers = Some "application/json");
  match Obs_trace.extract_from_headers headers with
  | None      -> Alcotest.fail "extract returned None"
  | Some ctx3 -> Alcotest.(check bool) "latest wins" true (ctx2.span_id = ctx3.span_id)

(* ------------------------------------------------------------------ *)
(* Context                                                             *)
(* ------------------------------------------------------------------ *)

let test_with_context_merges () =
  Eio_main.run @@ fun env ->
  let last_ctx = ref [] in
  let backend = {
    Obs.emit_span   = (fun _ -> ());
    Obs.emit_metric = (fun e -> last_ctx := e.Obs.context);
  } in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend in
  let ot = Obs.with_context ot [("env", "prod"); ("region", "us-east-1")] in
  let ot = Obs.with_context ot [("env", "staging")] in  (* override env *)
  let emit = Obs.register_counter ot ~name:"n" ~help:"" ~label_names:[] in
  emit 1;
  Alcotest.(check string) "env overridden to staging"
    "staging" (List.assoc "env" !last_ctx);
  Alcotest.(check bool) "region preserved"
    true (List.mem_assoc "region" !last_ctx)

let test_with_context_immutable () =
  Eio_main.run @@ fun env ->
  let ctxs = ref [] in
  let backend = {
    Obs.emit_span   = (fun _ -> ());
    Obs.emit_metric = (fun e -> ctxs := e.Obs.context :: !ctxs);
  } in
  let ot  = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend in
  let ot1 = Obs.with_context ot  [("req", "a")] in
  let ot2 = Obs.with_context ot  [("req", "b")] in
  let emit1 = Obs.register_counter ot1 ~name:"n" ~help:"" ~label_names:[] in
  let emit2 = Obs.register_counter ot2 ~name:"n" ~help:"" ~label_names:[] in
  emit1 1; emit2 1;
  (match !ctxs with
   | [ctx_b; ctx_a] ->
     Alcotest.(check string) "ot1 context unaffected"  "a" (List.assoc "req" ctx_a);
     Alcotest.(check string) "ot2 context independent" "b" (List.assoc "req" ctx_b)
   | _ -> Alcotest.fail "expected exactly 2 metric events")

(* ------------------------------------------------------------------ *)
(* Spans                                                               *)
(* ------------------------------------------------------------------ *)

let test_span_emitted () =
  Eio_main.run @@ fun env ->
  let spans = ref [] in
  let backend = {
    Obs.emit_span   = (fun e -> spans := e :: !spans);
    Obs.emit_metric = (fun _ -> ());
  } in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend in
  Obs.with_span ot "do_work" (fun _sp -> ());
  Alcotest.(check int)  "one span emitted"  1       (List.length !spans);
  Alcotest.(check string) "span name"  "do_work"    (List.hd !spans).Obs.name;
  Alcotest.(check string) "service"    "svc"        (List.hd !spans).Obs.service;
  Alcotest.(check bool)   "end >= start" true
    ((List.hd !spans).Obs.end_ns >= (List.hd !spans).Obs.start_ns)

let test_span_ok_status () =
  Eio_main.run @@ fun env ->
  let spans = ref [] in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:{ Obs.emit_span = (fun e -> spans := e :: !spans);
               emit_metric = (fun _ -> ()) } in
  Obs.with_span ot "op" (fun _sp -> ());
  Alcotest.(check bool) "ok status"
    true (match (List.hd !spans).Obs.status with `Ok -> true | _ -> false)

let test_span_error_status_on_exception () =
  Eio_main.run @@ fun env ->
  let spans = ref [] in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:{ Obs.emit_span = (fun e -> spans := e :: !spans);
               emit_metric = (fun _ -> ()) } in
  (try Obs.with_span ot "boom" (fun _sp -> raise Exit) with Exit -> ());
  Alcotest.(check bool) "error status on exception"
    true (match (List.hd !spans).Obs.status with `Error _ -> true | _ -> false)

let test_log_appends_to_span () =
  Eio_main.run @@ fun env ->
  let spans = ref [] in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:{ Obs.emit_span = (fun e -> spans := e :: !spans);
               emit_metric = (fun _ -> ()) } in
  Obs.with_span ot "op" (fun sp ->
    Obs.log sp Obs.Info ~fields:[("key", "val")] "first";
    Obs.log sp Obs.Warn "second");
  let span = List.hd !spans in
  Alcotest.(check (list (pair string string))) "span fields stay empty" [] span.Obs.fields;
  let entries = span.Obs.log_entries in
  Alcotest.(check int) "two log entries" 2 (List.length entries);
  (match entries with
   | [first; second] ->
     Alcotest.(check bool) "first level" true (first.Obs.level = Obs.Info);
     Alcotest.(check string) "first message" "first" first.Obs.message;
     Alcotest.(check bool) "extra field present"
       true (List.exists (fun (k, v) -> k = "key" && v = "val") first.Obs.fields);
     Alcotest.(check bool) "second level" true (second.Obs.level = Obs.Warn);
     Alcotest.(check string) "second message" "second" second.Obs.message
   | _ -> Alcotest.fail "expected exactly two log entries")

let test_log_order_preserved () =
  Eio_main.run @@ fun env ->
  let spans = ref [] in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:{ Obs.emit_span = (fun e -> spans := e :: !spans);
               emit_metric = (fun _ -> ()) } in
  Obs.with_span ot "op" (fun sp ->
    Obs.log sp Obs.Info "first";
    Obs.log sp Obs.Info "second");
  let msgs = (List.hd !spans).Obs.log_entries
    |> List.map (fun entry -> entry.Obs.message) in
  Alcotest.(check (list string)) "call order preserved" ["first"; "second"] msgs

let test_current_trace_ctx_child_of_parent () =
  Eio_main.run @@ fun env ->
  let ot     = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:Obs.noop in
  let parent = Obs_trace.generate () in
  Obs.with_span ot ~parent "child" (fun sp ->
    let ctx = Obs.current_trace_ctx sp in
    Alcotest.(check bool) "inherits trace_id"
      true (parent.Obs_trace.trace_id = ctx.Obs_trace.trace_id);
    Alcotest.(check bool) "new span_id"
      true (parent.Obs_trace.span_id <> ctx.Obs_trace.span_id))

let test_with_span_no_parent_generates_root () =
  Eio_main.run @@ fun env ->
  let spans = ref [] in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:{ Obs.emit_span = (fun e -> spans := e :: !spans);
               emit_metric = (fun _ -> ()) } in
  Obs.with_span ot "root" (fun _sp -> ());
  let tp = Obs_trace.to_traceparent (List.hd !spans).Obs.trace_ctx in
  Alcotest.(check bool) "valid traceparent"
    true (Obs_trace.of_traceparent tp <> None)

(* ------------------------------------------------------------------ *)
(* Metrics                                                             *)
(* ------------------------------------------------------------------ *)

let test_counter_emits_event () =
  Eio_main.run @@ fun env ->
  let metrics = ref [] in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:{ Obs.emit_span = (fun _ -> ());
               emit_metric = (fun e -> metrics := e :: !metrics) } in
  let c = Obs.register_counter ot ~name:"reqs" ~help:"desc" ~label_names:["method"] in
  c ~labels:[("method", "POST")] 1;
  Alcotest.(check int)    "one event"   1     (List.length !metrics);
  Alcotest.(check string) "name"        "reqs" (List.hd !metrics).Obs.name;
  Alcotest.(check string) "service"     "svc"  (List.hd !metrics).Obs.service;
  Alcotest.(check bool)   "is counter"  true
    (match (List.hd !metrics).Obs.kind with `Counter 1 -> true | _ -> false);
  Alcotest.(check string) "label value" "POST"
    (List.assoc "method" (List.hd !metrics).Obs.labels)

let test_histogram_emits_event () =
  Eio_main.run @@ fun env ->
  let metrics = ref [] in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:{ Obs.emit_span = (fun _ -> ());
               emit_metric = (fun e -> metrics := e :: !metrics) } in
  let h = Obs.register_histogram ot ~name:"latency_ms" ~help:"desc" ~label_names:[] in
  h 42.5;
  Alcotest.(check bool) "is histogram"
    true (match (List.hd !metrics).Obs.kind with `Histogram 42.5 -> true | _ -> false)

let test_counter_and_histogram_helper_emits_both () =
  Eio_main.run @@ fun env ->
  let metrics = ref [] in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:{ Obs.emit_span = (fun _ -> ());
               emit_metric = (fun e -> metrics := e :: !metrics) } in
  let c, h =
    Obs.register_counter_and_histogram ot
      ~counter_name:"items_total"
      ~counter_help:"Total items"
      ~counter_labels:["status"]
      ~histogram_name:"item_duration_seconds"
      ~histogram_help:"Item duration"
      ~histogram_labels:[]
  in
  c ~labels:[("status", "ok")] 1;
  h 0.25;
  let names = List.map (fun e -> e.Obs.name) (List.rev !metrics) in
  Alcotest.(check (list string)) "emits both metrics"
    ["items_total"; "item_duration_seconds"] names

let check_invalid_arg label f =
  match f () with
  | () -> Alcotest.fail (label ^ " should raise Invalid_argument")
  | exception Invalid_argument _ -> ()

let test_metric_name_validation () =
  Alcotest.(check string) "valid metric name"
    "http_requests_total" (Obs.metric_name "http_requests_total");
  Alcotest.(check string) "colon allowed in metric name"
    "sun:http_requests_total" (Obs.metric_name "sun:http_requests_total");
  check_invalid_arg "empty metric name" (fun () ->
    ignore (Obs.metric_name ""));
  check_invalid_arg "metric name starting with digit" (fun () ->
    ignore (Obs.metric_name "1_total"));
  check_invalid_arg "metric name containing dash" (fun () ->
    ignore (Obs.metric_name "http-requests-total"))

let test_label_name_validation () =
  Alcotest.(check string) "valid label name"
    "http_status" (Obs.label_name_to_string (Obs.label_name "http_status"));
  check_invalid_arg "empty label name" (fun () ->
    ignore (Obs.label_name ""));
  check_invalid_arg "label name starting with digit" (fun () ->
    ignore (Obs.label_name "1status"));
  check_invalid_arg "label name containing colon" (fun () ->
    ignore (Obs.label_name "http:status"))

let test_register_rejects_invalid_metric_name () =
  Eio_main.run @@ fun env ->
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:Obs.noop in
  check_invalid_arg "invalid counter name" (fun () ->
    let _emit : Obs_metrics.counter_fn =
      Obs.register_counter ot ~name:"bad-name" ~help:"desc" ~label_names:[]
    in
    ());
  check_invalid_arg "invalid gauge name" (fun () ->
    let _emit : Obs_metrics.gauge_fn =
      Obs.register_gauge ot ~name:"9bad" ~help:"desc" ~label_names:[]
    in
    ());
  check_invalid_arg "invalid histogram name" (fun () ->
    Obs.register_histogram ot ~name:"bad.name" ~help:"desc" ~label_names:[] 1.0)

let test_register_rejects_invalid_label_name () =
  Eio_main.run @@ fun env ->
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:Obs.noop in
  check_invalid_arg "invalid counter label" (fun () ->
    let _emit : Obs_metrics.counter_fn =
      Obs.register_counter ot
        ~name:"requests_total" ~help:"desc" ~label_names:["bad-label"]
    in
    ());
  check_invalid_arg "invalid gauge label" (fun () ->
    let _emit : Obs_metrics.gauge_fn =
      Obs.register_gauge ot
        ~name:"queue_depth" ~help:"desc" ~label_names:["9host"]
    in
    ());
  check_invalid_arg "invalid histogram label" (fun () ->
    Obs.register_histogram ot
      ~name:"request_duration_seconds" ~help:"desc"
      ~label_names:["bad.label"]
      1.0)

let test_noop_compiles_and_runs () =
  Eio_main.run @@ fun env ->
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:Obs.noop in
  Obs.with_span ot "op" (fun sp ->
    Obs.log sp Obs.Info "hello";
    let c = Obs.register_counter ot ~name:"n" ~help:"" ~label_names:[] in
    c 1)

(* ------------------------------------------------------------------ *)
(* compose                                                             *)
(* ------------------------------------------------------------------ *)

let test_compose_fans_out () =
  Eio_main.run @@ fun env ->
  let spans_a = ref 0 and spans_b = ref 0 in
  let backend_a = { Obs.emit_span = (fun _ -> incr spans_a); emit_metric = (fun _ -> ()) } in
  let backend_b = { Obs.emit_span = (fun _ -> incr spans_b); emit_metric = (fun _ -> ()) } in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:(Obs.compose backend_a backend_b) in
  Obs.with_span ot "op" (fun _sp -> ());
  Alcotest.(check int) "backend_a received span" 1 !spans_a;
  Alcotest.(check int) "backend_b received span" 1 !spans_b

(* ------------------------------------------------------------------ *)
(* TLS helper                                                          *)
(* ------------------------------------------------------------------ *)

let test_tls_authenticator_fails_closed_without_ca_bundle () =
  Alcotest.(check bool) "missing CA paths are rejected"
    true
    (match Obs_tls.authenticator
             ~ca_paths:["/sun/does/not/exist/ca-certificates.crt"] () with
     | Error `No_system_ca_bundle -> true
     | _ -> false)

let test_tls_authenticator_ignores_invalid_ca_bundle () =
  let path = Filename.temp_file "sun-invalid-ca" ".pem" in
  Fun.protect
    (fun () ->
       let oc = open_out path in
       output_string oc "not a pem certificate";
       close_out oc;
       Alcotest.(check bool) "invalid CA file is rejected"
         true
         (match Obs_tls.authenticator ~ca_paths:[path] () with
          | Error `No_system_ca_bundle -> true
          | _ -> false))
    ~finally:(fun () -> Sys.remove path)

let test_tls_wrapper_returns_typed_error_without_ca_bundle () =
  Alcotest.(check bool) "wrapper setup returns typed CA error"
    true
    (match Obs_tls.make_https_wrapper
             ~ca_paths:["/sun/does/not/exist/ca-certificates.crt"] () with
     | Error `No_system_ca_bundle -> true
     | _ -> false)

(* ------------------------------------------------------------------ *)
(* Test runner                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run "obs_eio" [
    "trace_context", [
      test_case "traceparent round-trips"         `Quick test_traceparent_roundtrip;
      test_case "child_span inherits trace_id"    `Quick test_child_span;
      test_case "malformed traceparent → None"    `Quick test_of_traceparent_malformed;
      test_case "inject/extract headers"          `Quick test_inject_extract_headers;
      test_case "inject replaces existing header" `Quick test_inject_replaces_existing;
      test_case "extract mixed-case header"       `Quick test_extract_headers_case_insensitive;
      test_case "inject replaces mixed-case header" `Quick
        test_inject_replaces_existing_case_insensitive;
    ];
    "context", [
      test_case "with_context merges and overrides" `Quick test_with_context_merges;
      test_case "with_context is immutable"         `Quick test_with_context_immutable;
    ];
    "spans", [
      test_case "span emitted on close"           `Quick test_span_emitted;
      test_case "ok status on normal return"      `Quick test_span_ok_status;
      test_case "error status on exception"       `Quick test_span_error_status_on_exception;
      test_case "log appends entries to span"     `Quick test_log_appends_to_span;
      test_case "log order preserved"             `Quick test_log_order_preserved;
      test_case "current_trace_ctx child of parent" `Quick test_current_trace_ctx_child_of_parent;
      test_case "root span has valid traceparent" `Quick test_with_span_no_parent_generates_root;
    ];
    "metrics", [
      test_case "counter emits metric event"   `Quick test_counter_emits_event;
      test_case "histogram emits metric event" `Quick test_histogram_emits_event;
      test_case "counter and histogram helper emits both" `Quick test_counter_and_histogram_helper_emits_both;
      test_case "metric name validation"       `Quick test_metric_name_validation;
      test_case "label name validation"        `Quick test_label_name_validation;
      test_case "register rejects invalid metric names" `Quick test_register_rejects_invalid_metric_name;
      test_case "register rejects invalid label names" `Quick test_register_rejects_invalid_label_name;
      test_case "noop backend runs silently"   `Quick test_noop_compiles_and_runs;
    ];
    "compose", [
      test_case "compose fans out to both backends" `Quick test_compose_fans_out;
    ];
    "tls", [
      test_case "authenticator fails closed without CA bundle" `Quick
        test_tls_authenticator_fails_closed_without_ca_bundle;
      test_case "authenticator ignores invalid CA bundle" `Quick
        test_tls_authenticator_ignores_invalid_ca_bundle;
      test_case "wrapper returns typed error without CA bundle" `Quick
        test_tls_wrapper_returns_typed_error_without_ca_bundle;
    ];
  ]
