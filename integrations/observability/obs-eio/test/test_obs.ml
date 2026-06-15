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
    true (List.mem_assoc "traceparent" headers);
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
    1 (List.length (List.filter (fun (k, _) -> k = "traceparent") headers));
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
  let fields = (List.hd !spans).Obs.fields in
  Alcotest.(check bool) "fields non-empty"     true (fields <> []);
  Alcotest.(check bool) "log.msg present"
    true (List.exists (fun (k, _) -> k = "log.msg") fields);
  Alcotest.(check bool) "log.level present"
    true (List.exists (fun (k, _) -> k = "log.level") fields);
  Alcotest.(check bool) "extra field present"
    true (List.exists (fun (k, v) -> k = "key" && v = "val") fields)

let test_log_order_preserved () =
  Eio_main.run @@ fun env ->
  let spans = ref [] in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:{ Obs.emit_span = (fun e -> spans := e :: !spans);
               emit_metric = (fun _ -> ()) } in
  Obs.with_span ot "op" (fun sp ->
    Obs.log sp Obs.Info "first";
    Obs.log sp Obs.Info "second");
  let msgs = (List.hd !spans).Obs.fields
    |> List.filter_map (fun (k, v) -> if k = "log.msg" then Some v else None) in
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
    true (match (List.hd !metrics).Obs.kind with `Histogram (42.5, []) -> true | _ -> false)

let test_noop_compiles_and_runs () =
  Eio_main.run @@ fun env ->
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:Obs.noop in
  Obs.with_span ot "op" (fun sp ->
    Obs.log sp Obs.Info "hello";
    let c = Obs.register_counter ot ~name:"n" ~help:"" ~label_names:[] in
    c 1)

let test_undeclared_labels_filtered () =
  Eio_main.run @@ fun env ->
  let metrics = ref [] in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:{ Obs.emit_span = (fun _ -> ());
               emit_metric = (fun e -> metrics := e :: !metrics) } in
  let c = Obs.register_counter ot ~name:"n" ~help:"" ~label_names:["method"] in
  c ~labels:[("method", "GET"); ("undeclared", "oops")] 1;
  let labels = (List.hd !metrics).Obs.labels in
  Alcotest.(check bool) "declared label present"
    true (List.mem_assoc "method" labels);
  Alcotest.(check bool) "undeclared label removed"
    false (List.mem_assoc "undeclared" labels)

let test_missing_declared_label_ok () =
  Eio_main.run @@ fun env ->
  let metrics = ref [] in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:{ Obs.emit_span = (fun _ -> ());
               emit_metric = (fun e -> metrics := e :: !metrics) } in
  let c = Obs.register_counter ot ~name:"n" ~help:"" ~label_names:["method"; "status"] in
  c ~labels:[("method", "GET")] 1;
  let labels = (List.hd !metrics).Obs.labels in
  Alcotest.(check int) "only one label emitted" 1 (List.length labels);
  Alcotest.(check string) "method label present" "GET" (List.assoc "method" labels)

let test_histogram_custom_buckets_forwarded () =
  Eio_main.run @@ fun env ->
  let metrics = ref [] in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock
    ~backend:{ Obs.emit_span = (fun _ -> ());
               emit_metric = (fun e -> metrics := e :: !metrics) } in
  let h = Obs.register_histogram ot ~name:"rtt" ~help:"desc" ~label_names:[]
            ~buckets:[0.01; 0.05; 0.1; 0.5; 1.0] in
  h 0.03;
  Alcotest.(check bool) "custom buckets forwarded"
    true (match (List.hd !metrics).Obs.kind with
          | `Histogram (_, [0.01; 0.05; 0.1; 0.5; 1.0]) -> true
          | _ -> false)

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
    ];
    "context", [
      test_case "with_context merges and overrides" `Quick test_with_context_merges;
      test_case "with_context is immutable"         `Quick test_with_context_immutable;
    ];
    "spans", [
      test_case "span emitted on close"           `Quick test_span_emitted;
      test_case "ok status on normal return"      `Quick test_span_ok_status;
      test_case "error status on exception"       `Quick test_span_error_status_on_exception;
      test_case "log appends fields to span"      `Quick test_log_appends_to_span;
      test_case "log order preserved"             `Quick test_log_order_preserved;
      test_case "current_trace_ctx child of parent" `Quick test_current_trace_ctx_child_of_parent;
      test_case "root span has valid traceparent" `Quick test_with_span_no_parent_generates_root;
    ];
    "metrics", [
      test_case "counter emits metric event"         `Quick test_counter_emits_event;
      test_case "histogram emits metric event"       `Quick test_histogram_emits_event;
      test_case "noop backend runs silently"         `Quick test_noop_compiles_and_runs;
      test_case "undeclared labels are filtered"     `Quick test_undeclared_labels_filtered;
      test_case "missing declared label is ok"       `Quick test_missing_declared_label_ok;
      test_case "custom histogram buckets forwarded" `Quick test_histogram_custom_buckets_forwarded;
    ];
    "compose", [
      test_case "compose fans out to both backends" `Quick test_compose_fans_out;
    ];
  ]
