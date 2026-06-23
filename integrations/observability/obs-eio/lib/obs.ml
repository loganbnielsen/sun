(* ------------------------------------------------------------------ *)
(* Types                                                               *)
(* ------------------------------------------------------------------ *)

type counter_fn   = ?labels:(string * string) list -> int   -> unit
type gauge_fn     = ?labels:(string * string) list -> float -> unit
type histogram_fn = ?labels:(string * string) list -> float -> unit

type level = Debug | Info | Warn | Error

type log_entry = {
  level   : level;
  message : string;
  fields  : (string * string) list;
}

type span_event = {
  trace_ctx : Obs_trace.t;
  name      : string;
  service   : string;
  start_ns  : int64;
  end_ns    : int64;
  status    : [ `Ok | `Error of string ];
  fields    : (string * string) list;
  log_entries : log_entry list;
  context   : (string * string) list;
}

type metric_event = {
  name    : string;
  help    : string;
  kind    : [ `Counter of int | `Gauge of float | `Histogram of float ];
  labels  : (string * string) list;
  context : (string * string) list;
  service : string;
}

type backend = {
  emit_span   : span_event   -> unit;
  emit_metric : metric_event -> unit;
}

type label_name = string

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
  (* Accumulates log entries in reverse call order. *)
  sp_log_buf : log_entry list ref;
  sp_ot      : t;
}

(* ------------------------------------------------------------------ *)
(* Helpers                                                             *)
(* ------------------------------------------------------------------ *)

let now_ns t = Mtime.to_uint64_ns (t.get_time ())

let level_string = function
  | Debug -> "debug" | Info -> "info" | Warn -> "warn" | Error -> "error"

let log_entry_fields entry =
  [("log.level", level_string entry.level); ("log.msg", entry.message)]
  @ entry.fields

let log_entries_fields entries =
  List.concat_map log_entry_fields entries

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
      let fields = e.fields @ log_entries_fields e.log_entries in
      Printf.printf "SPAN  svc=%s name=%s %s status=%s dur=%.2fms%s\n%!"
        e.service e.name (pp_trace e.trace_ctx) status dur_ms
        (if fields = [] then "" else " | " ^ pp_kv fields));
    emit_metric = (fun e ->
      let kind = match e.kind with
        | `Counter n   -> Printf.sprintf "counter=%d" n
        | `Gauge f     -> Printf.sprintf "gauge=%g" f
        | `Histogram f -> Printf.sprintf "hist=%g" f
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
      let log_entries = List.rev !(sp.sp_log_buf) in
      t.backend.emit_span {
        trace_ctx = sp_ctx; name; service = t.service;
        start_ns = sp_start; end_ns;
        status = !outcome;
        fields = [];
        log_entries;
        context = t.context;
      })
    (fun () ->
      match f sp with
      | v -> v
      | exception exn ->
        outcome := `Error (Printexc.to_string exn);
        raise exn)

let log sp level ?(fields = []) message =
  sp.sp_log_buf := { level; message; fields } :: !(sp.sp_log_buf)

let log_t t level ?(fields = []) message =
  with_span t "log" (fun sp -> log sp level ~fields message)

let current_trace_ctx sp = sp.sp_ctx

(* ------------------------------------------------------------------ *)
(* Metrics                                                             *)
(* ------------------------------------------------------------------ *)

let is_metric_initial_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '_' | ':' -> true
  | _ -> false

let is_label_initial_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
  | _ -> false

let is_name_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | ':' -> true
  | _ -> false

let is_label_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
  | _ -> false

let validate_name ~kind ~is_initial ~is_char name =
  if name = "" then
    invalid_arg ("Obs." ^ kind ^ ": name must not be empty");
  if not (is_initial name.[0]) then
    invalid_arg
      (Printf.sprintf "Obs.%s: invalid Prometheus name %S" kind name);
  String.iter (fun c ->
    if not (is_char c) then
      invalid_arg
        (Printf.sprintf "Obs.%s: invalid Prometheus name %S" kind name)
  ) name;
  name

let metric_name name =
  validate_name ~kind:"metric_name"
    ~is_initial:is_metric_initial_char
    ~is_char:is_name_char
    name

let label_name name =
  validate_name ~kind:"label_name"
    ~is_initial:is_label_initial_char
    ~is_char:is_label_char
    name

let label_name_to_string name = name

let duplicate_name names =
  let rec loop seen = function
    | [] -> None
    | name :: rest ->
      if List.mem name seen then Some name else loop (name :: seen) rest
  in
  loop [] names

let validate_label_names label_names =
  List.iter (fun name -> ignore (label_name name)) label_names;
  (match duplicate_name label_names with
   | None -> ()
   | Some name ->
     invalid_arg
       (Printf.sprintf "Obs.register_metric: duplicate label name %S" name));
  label_names

let validate_metric_labels ~name ~label_names labels =
  let emitted_label_names = List.map fst labels in
  match duplicate_name emitted_label_names with
  | Some label ->
    invalid_arg
      (Printf.sprintf "Obs.emit_metric %S: duplicate label %S" name label)
  | None ->
    let missing =
      List.filter (fun label -> not (List.mem_assoc label labels)) label_names
    in
    let extra =
      List.filter
        (fun label -> not (List.mem label label_names))
        emitted_label_names
    in
    match missing, extra with
    | [], [] -> ()
    | label :: _, _ ->
      invalid_arg
        (Printf.sprintf "Obs.emit_metric %S: missing label %S" name label)
    | [], label :: _ ->
      invalid_arg
        (Printf.sprintf "Obs.emit_metric %S: extra label %S" name label)

let register_counter t ~name ~help ~label_names : counter_fn =
  let name = metric_name name in
  let label_names = validate_label_names label_names in
  fun ?(labels = []) value ->
    validate_metric_labels ~name ~label_names labels;
    t.backend.emit_metric {
      name; help; kind = `Counter value; labels; context = t.context; service = t.service;
    }

let register_gauge t ~name ~help ~label_names : gauge_fn =
  let name = metric_name name in
  let label_names = validate_label_names label_names in
  fun ?(labels = []) value ->
    validate_metric_labels ~name ~label_names labels;
    t.backend.emit_metric {
      name; help; kind = `Gauge value; labels; context = t.context; service = t.service;
    }

let register_histogram t ~name ~help ~label_names ?(buckets = []) : histogram_fn =
  let name = metric_name name in
  let label_names = validate_label_names label_names in
  ignore buckets;
  fun ?(labels = []) value ->
    validate_metric_labels ~name ~label_names labels;
    t.backend.emit_metric {
      name; help; kind = `Histogram value; labels; context = t.context; service = t.service;
    }

let register_counter_and_histogram t
    ~counter_name ~counter_help ~counter_labels
    ~histogram_name ~histogram_help ~histogram_labels =
  let counter =
    register_counter t
      ~name:counter_name
      ~help:counter_help
      ~label_names:counter_labels
  in
  let histogram =
    register_histogram t
      ~name:histogram_name
      ~help:histogram_help
      ~label_names:histogram_labels
      ?buckets:None
  in
  (counter, histogram)
