let default_bounds =
  [| 0.005; 0.01; 0.025; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0 |]

(* ------------------------------------------------------------------ *)
(* Internal state                                                      *)
(* ------------------------------------------------------------------ *)

type label_key = (string * string) list

let sort_labels labels =
  List.sort (fun (a, _) (b, _) -> String.compare a b) labels

type counter_state = { mutable c_value : float }
type gauge_state   = { mutable g_value : float }

type hist_state = {
  h_bounds : float array;
  mutable h_counts : int array;   (* length = Array.length h_bounds + 1; last slot = +Inf *)
  mutable h_sum    : float;
  mutable h_count  : int;
}

type family =
  | FCounter of {
      f_help   : string;
      f_series : (label_key, counter_state) Hashtbl.t;
    }
  | FGauge of {
      f_help   : string;
      f_series : (label_key, gauge_state) Hashtbl.t;
    }
  | FHistogram of {
      f_help   : string;
      f_bounds : float array;
      f_series : (label_key, hist_state) Hashtbl.t;
    }

type registry = {
  r_families : (string, family) Hashtbl.t;
  r_mutex    : Mutex.t;
}

(* ------------------------------------------------------------------ *)
(* Accumulation                                                        *)
(* ------------------------------------------------------------------ *)

let get_or_create tbl key make =
  match Hashtbl.find_opt tbl key with
  | Some v -> v
  | None ->
    let v = make () in
    Hashtbl.add tbl key v;
    v

let emit reg (e : Obs.metric_event) =
  let key = sort_labels e.labels in
  Mutex.lock reg.r_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock reg.r_mutex) (fun () ->
    match e.kind with
    | `Counter delta ->
      let fam =
        get_or_create reg.r_families e.name (fun () ->
          FCounter { f_help = e.help; f_series = Hashtbl.create 4 })
      in
      (match fam with
       | FCounter { f_series; _ } ->
         let s = get_or_create f_series key (fun () -> { c_value = 0.0 }) in
         s.c_value <- s.c_value +. float_of_int delta
       | _ -> ())
    | `Gauge v ->
      let fam =
        get_or_create reg.r_families e.name (fun () ->
          FGauge { f_help = e.help; f_series = Hashtbl.create 4 })
      in
      (match fam with
       | FGauge { f_series; _ } ->
         let s = get_or_create f_series key (fun () -> { g_value = 0.0 }) in
         s.g_value <- v
       | _ -> ())
    | `Histogram obs ->
      let fam =
        get_or_create reg.r_families e.name (fun () ->
          FHistogram {
            f_help   = e.help;
            f_bounds = default_bounds;
            f_series = Hashtbl.create 4;
          })
      in
      (match fam with
       | FHistogram { f_bounds; f_series; _ } ->
         let n_bounds = Array.length f_bounds in
         let s =
           get_or_create f_series key (fun () -> {
             h_bounds = f_bounds;
             h_counts = Array.make (n_bounds + 1) 0;
             h_sum    = 0.0;
             h_count  = 0;
           })
         in
         (* Prometheus cumulative histogram: increment all buckets where le >= obs. *)
         Array.iteri (fun i le ->
           if obs <= le then s.h_counts.(i) <- s.h_counts.(i) + 1
         ) f_bounds;
         s.h_counts.(n_bounds) <- s.h_counts.(n_bounds) + 1;  (* +Inf always *)
         s.h_sum   <- s.h_sum +. obs;
         s.h_count <- s.h_count + 1
       | _ -> ()))

(* ------------------------------------------------------------------ *)
(* Renderer                                                            *)
(* ------------------------------------------------------------------ *)

(* Snapshot types — immutable copies taken while the mutex is held. *)
type family_snap =
  | SCounter   of string * (label_key * float) list
  | SGauge     of string * (label_key * float) list
  | SHistogram of string * float array * (label_key * int array * float * int) list

let snapshot reg =
  Mutex.lock reg.r_mutex;
  let result =
    Hashtbl.fold (fun name fam acc ->
      let snap = match fam with
        | FCounter { f_help; f_series } ->
          let series =
            Hashtbl.fold (fun k s acc -> (k, s.c_value) :: acc) f_series []
          in
          SCounter (f_help, series)
        | FGauge { f_help; f_series } ->
          let series =
            Hashtbl.fold (fun k s acc -> (k, s.g_value) :: acc) f_series []
          in
          SGauge (f_help, series)
        | FHistogram { f_help; f_bounds; f_series } ->
          let series =
            Hashtbl.fold (fun k s acc ->
              (k, Array.copy s.h_counts, s.h_sum, s.h_count) :: acc
            ) f_series []
          in
          SHistogram (f_help, f_bounds, series)
      in
      (name, snap) :: acc)
    reg.r_families []
  in
  Mutex.unlock reg.r_mutex;
  List.sort (fun (a, _) (b, _) -> String.compare a b) result

let escape_label_value s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | '\\' -> Buffer.add_string buf "\\\\"
    | '"'  -> Buffer.add_string buf "\\\""
    | '\n' -> Buffer.add_string buf "\\n"
    | c    -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let render_labels labels =
  match labels with
  | [] -> ""
  | _  ->
    "{" ^
    String.concat ","
      (List.map (fun (k, v) -> k ^ "=\"" ^ escape_label_value v ^ "\"") labels)
    ^ "}"

let render_float f =
  if Float.is_nan f      then "NaN"
  else if f = infinity   then "+Inf"
  else if f = neg_infinity then "-Inf"
  else Printf.sprintf "%g" f

let render reg =
  let snaps = snapshot reg in
  if snaps = [] then ""
  else
    let buf = Buffer.create 1024 in
    List.iter (fun (name, snap) ->
      match snap with
      | SCounter (help, series) ->
        Buffer.add_string buf ("# HELP " ^ name ^ " " ^ help ^ "\n");
        Buffer.add_string buf ("# TYPE " ^ name ^ " counter\n");
        List.iter (fun (labels, v) ->
          Buffer.add_string buf
            (name ^ render_labels labels ^ " " ^ render_float v ^ "\n")
        ) series;
        Buffer.add_char buf '\n'
      | SGauge (help, series) ->
        Buffer.add_string buf ("# HELP " ^ name ^ " " ^ help ^ "\n");
        Buffer.add_string buf ("# TYPE " ^ name ^ " gauge\n");
        List.iter (fun (labels, v) ->
          Buffer.add_string buf
            (name ^ render_labels labels ^ " " ^ render_float v ^ "\n")
        ) series;
        Buffer.add_char buf '\n'
      | SHistogram (help, bounds, series) ->
        Buffer.add_string buf ("# HELP " ^ name ^ " " ^ help ^ "\n");
        Buffer.add_string buf ("# TYPE " ^ name ^ " histogram\n");
        List.iter (fun (labels, counts, sum, count) ->
          Array.iteri (fun i le ->
            let le_labels = labels @ [("le", render_float le)] in
            Buffer.add_string buf
              (name ^ "_bucket" ^ render_labels le_labels ^ " " ^
               string_of_int counts.(i) ^ "\n")
          ) bounds;
          let inf_labels = labels @ [("le", "+Inf")] in
          Buffer.add_string buf
            (name ^ "_bucket" ^ render_labels inf_labels ^ " " ^
             string_of_int count ^ "\n");
          Buffer.add_string buf
            (name ^ "_sum" ^ render_labels labels ^ " " ^ render_float sum ^ "\n");
          Buffer.add_string buf
            (name ^ "_count" ^ render_labels labels ^ " " ^ string_of_int count ^ "\n")
        ) series;
        Buffer.add_char buf '\n'
    ) snaps;
    Buffer.contents buf

(* ------------------------------------------------------------------ *)
(* Pushgateway HTTP client                                            *)
(* ------------------------------------------------------------------ *)

let push ~net ~clock ~url ~job renderer =
  let body = renderer () in
  if body = "" then Ok ()
  else
    let base = Uri.of_string url in
    let encoded_job = Uri.pct_encode ~component:`Path job in
    let target = Uri.with_path base ("/metrics/job/" ^ encoded_job) in
    let headers =
      Http.Header.of_list
        [ ("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        ; ("Content-Length", string_of_int (String.length body))
        ; ("Connection", "close")
        ]
    in
    let body_src = Cohttp_eio.Body.of_string body in
    (try
       Eio.Time.with_timeout_exn clock 5.0 (fun () ->
         Eio.Switch.run (fun sw ->
           let client = Cohttp_eio.Client.make ~https:None net in
           let (resp, _body) =
             Cohttp_eio.Client.put client ~sw ~headers ~body:body_src target
           in
           let code = Http.Status.to_int (Http.Response.status resp) in
           if code >= 200 && code < 300 then Ok ()
           else Error (Printf.sprintf "Pushgateway returned HTTP %d" code)))
     with
     | Eio.Time.Timeout -> Error "Pushgateway push timed out after 5s"
     | exn              -> Error ("Pushgateway push: " ^ Printexc.to_string exn))

(* ------------------------------------------------------------------ *)
(* Public API                                                          *)
(* ------------------------------------------------------------------ *)

let create () =
  let reg = { r_families = Hashtbl.create 8; r_mutex = Mutex.create () } in
  let backend = {
    Obs.emit_span   = (fun _ -> ());
    Obs.emit_metric = emit reg;
  } in
  (backend, fun () -> render reg)
