(* ------------------------------------------------------------------ *)
(* Types                                                               *)
(* ------------------------------------------------------------------ *)

type level = Debug | Info | Warn | Error

type span_event = {
  trace_ctx : Obs_trace.t;
  name      : string;
  service   : string;
  start_ns  : int64;
  end_ns    : int64;
  status    : [ `Ok | `Error of string ];
  fields    : (string * string) list;
  context   : (string * string) list;
}

type metric_event = {
  name    : string;
  help    : string;
  kind    : [ `Counter of int | `Gauge of float | `Histogram of float * float list ];
  labels  : (string * string) list;
  context : (string * string) list;
  service : string;
}

type backend = {
  emit_span   : span_event   -> unit;
  emit_metric : metric_event -> unit;
}

(* ------------------------------------------------------------------ *)
(* Handle and span                                                     *)
(* ------------------------------------------------------------------ *)

type t = {
  service  : string;
  get_time : unit -> Mtime.t;  (* closure over mono_clock *)
  backend  : backend;
  context  : (string * string) list;
}

type span = {
  sp_ctx     : Obs_trace.t;
  sp_name    : string;
  sp_service : string;
  sp_start   : int64;
  (* Accumulates (level, message, extra_fields) in reverse call order. *)
  sp_log_buf : (level * string * (string * string) list) list ref;
  sp_ot      : t;
}

(* ------------------------------------------------------------------ *)
(* Helpers                                                             *)
(* ------------------------------------------------------------------ *)

let now_ns t = Mtime.to_uint64_ns (t.get_time ())

let level_string = function
  | Debug -> "debug" | Info -> "info" | Warn -> "warn" | Error -> "error"

let flatten_logs buf =
  List.concat_map (fun (lvl, msg, fields) ->
    [("log.level", level_string lvl); ("log.msg", msg)] @ fields
  ) (List.rev !buf)

(* ------------------------------------------------------------------ *)
(* Built-in backends                                                   *)
(* ------------------------------------------------------------------ *)

let noop = {
  emit_span   = (fun _ -> ());
  emit_metric = (fun _ -> ());
}

let pp_kv pairs =
  String.concat " " (List.map (fun (k, v) -> k ^ "=" ^ String.escaped v) pairs)

let stdout =
  let pp_trace ctx =
    let (hi, lo) = ctx.Obs_trace.trace_id in
    Printf.sprintf "trace=%016Lx%016Lx span=%016Lx" hi lo ctx.Obs_trace.span_id
  in
  { emit_span = (fun e ->
      let dur_ms = Int64.(to_float (sub e.end_ns e.start_ns)) /. 1e6 in
      let status = match e.status with `Ok -> "ok" | `Error s -> "error:" ^ s in
      Printf.printf "SPAN  svc=%s name=%s %s status=%s dur=%.2fms%s\n%!"
        e.service e.name (pp_trace e.trace_ctx) status dur_ms
        (if e.fields = [] then "" else " | " ^ pp_kv e.fields));
    emit_metric = (fun e ->
      let kind = match e.kind with
        | `Counter n   -> Printf.sprintf "counter=%d" n
        | `Gauge f     -> Printf.sprintf "gauge=%g" f
        | `Histogram (f, _) -> Printf.sprintf "hist=%g" f
      in
      Printf.printf "METRIC svc=%s name=%s %s%s%s\n%!"
        e.service e.name kind
        (if e.labels  = [] then "" else " labels={" ^ pp_kv e.labels ^ "}")
        (if e.context = [] then "" else " ctx={"    ^ pp_kv e.context ^ "}"));
  }

let compose a b = {
  emit_span   = (fun e -> a.emit_span e;   b.emit_span e);
  emit_metric = (fun e -> a.emit_metric e; b.emit_metric e);
}

(* ------------------------------------------------------------------ *)
(* Create                                                              *)
(* ------------------------------------------------------------------ *)

let create ~service ~mono_clock ~backend = {
  service;
  get_time = (fun () -> Eio.Time.Mono.now mono_clock);
  backend;
  context = [];
}

(* ------------------------------------------------------------------ *)
(* Context                                                             *)
(* ------------------------------------------------------------------ *)

let with_context t extra =
  (* Merge: new keys override existing; unlisted keys are preserved. *)
  let merged = List.fold_left (fun acc (k, v) ->
    (k, v) :: List.filter (fun (k2, _) -> k2 <> k) acc
  ) t.context extra in
  { t with context = merged }

(* ------------------------------------------------------------------ *)
(* Spans                                                               *)
(* ------------------------------------------------------------------ *)

let with_span t ?parent name f =
  let sp_ctx = match parent with
    | None   -> Obs_trace.generate ()
    | Some p -> Obs_trace.child_span p
  in
  let sp_start = now_ns t in
  let sp = { sp_ctx; sp_name = name; sp_service = t.service;
             sp_start; sp_log_buf = ref []; sp_ot = t } in
  let outcome = ref `Ok in
  Fun.protect
    ~finally:(fun () ->
      let end_ns = now_ns t in
      t.backend.emit_span {
        trace_ctx = sp_ctx; name; service = t.service;
        start_ns = sp_start; end_ns;
        status = !outcome;
        fields = flatten_logs sp.sp_log_buf;
        context = t.context;
      })
    (fun () ->
      match f sp with
      | v -> v
      | exception exn ->
        outcome := `Error (Printexc.to_string exn);
        raise exn)

let log sp level ?(fields = []) message =
  sp.sp_log_buf := (level, message, fields) :: !(sp.sp_log_buf)

let log_t t level ?(fields = []) message =
  with_span t "log" (fun sp -> log sp level ~fields message)

let current_trace_ctx sp = sp.sp_ctx

(* ------------------------------------------------------------------ *)
(* Metrics                                                             *)
(* ------------------------------------------------------------------ *)

let filter_labels ~label_names labels =
  List.filter (fun (k, _) -> List.mem k label_names) labels

let register_counter t ~name ~help ~label_names : Obs_metrics.counter_fn =
  fun ?(labels = []) value ->
    t.backend.emit_metric {
      name; help; kind = `Counter value;
      labels = filter_labels ~label_names labels;
      context = t.context; service = t.service;
    }

let register_gauge t ~name ~help ~label_names : Obs_metrics.gauge_fn =
  fun ?(labels = []) value ->
    t.backend.emit_metric {
      name; help; kind = `Gauge value;
      labels = filter_labels ~label_names labels;
      context = t.context; service = t.service;
    }

let register_histogram t ~name ~help ~label_names ?(buckets = []) : Obs_metrics.histogram_fn =
  fun ?(labels = []) value ->
    t.backend.emit_metric {
      name; help; kind = `Histogram (value, buckets);
      labels = filter_labels ~label_names labels;
      context = t.context; service = t.service;
    }
