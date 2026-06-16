(* ------------------------------------------------------------------ *)
(* TLS helper                                                          *)
(* ------------------------------------------------------------------ *)

let https_wrapper = Sun_tls.make_https_wrapper ~caller:"obs-loki"

(* ------------------------------------------------------------------ *)
(* HTTP client (cohttp-eio + Uri)                                      *)
(* ------------------------------------------------------------------ *)

let http_post ~net ~clock ~url ~body =
  let push_url = Uri.with_path (Uri.of_string url) "/loki/api/v1/push" in
  let headers =
    Http.Header.of_list [ ("Content-Type", "application/json") ]
  in
  let body_src = Cohttp_eio.Body.of_string body in
  try
    Eio.Time.with_timeout_exn clock 5.0 (fun () ->
      Eio.Switch.run (fun sw ->
        let client = Cohttp_eio.Client.make ~https:(Some (Lazy.force https_wrapper)) net in
        let (resp, resp_body) =
          Cohttp_eio.Client.post client ~sw ~headers ~body:body_src push_url
        in
        let code = Http.Status.to_int (Http.Response.status resp) in
        if code >= 200 && code < 300 then begin
          (* Drain body to avoid connection-level warnings. *)
          ignore (Eio.Buf_read.of_flow ~max_size:(64 * 1024) resp_body
                  |> Eio.Buf_read.take_while (fun _ -> true));
          Ok ()
        end else begin
          let raw =
            try
              Eio.Buf_read.of_flow ~max_size:(64 * 1024) resp_body
              |> Eio.Buf_read.take_while (fun _ -> true)
            with _ -> ""
          in
          let truncated = String.sub raw 0 (min (String.length raw) 512) in
          let detail = if truncated = "" then "" else ": " ^ String.trim truncated in
          Error (Printf.sprintf "Loki returned HTTP %d%s" code detail)
        end))
  with
  | Eio.Time.Timeout -> Error "Loki push timed out after 5s"
  | exn              -> Error ("Loki push: " ^ Printexc.to_string exn)

(* ------------------------------------------------------------------ *)
(* Encoding helpers                                                    *)
(* ------------------------------------------------------------------ *)

(* Logfmt for log line bodies.
   Values containing spaces, = or control chars are quoted. *)
let logfmt_val s =
  let needs_quotes = String.exists
    (fun c -> c = ' ' || c = '=' || c = '"' || c = '\n' || c = '\r') s in
  if needs_quotes then Printf.sprintf "%S" s else s

let logfmt pairs =
  String.concat " "
    (List.map (fun (k, v) -> k ^ "=" ^ logfmt_val v) pairs)

(* Logfmt fields for trace context, included in the log line body.
   Structured metadata (Loki 3.x 3-element tuples) is incompatible with
   Loki 2.x (the loki-stack Helm chart); including trace_id/span_id in
   the line body keeps them searchable on both versions. *)
let trace_fields trace_id span_id =
  [("trace_id", trace_id); ("span_id", span_id)]

(* ------------------------------------------------------------------ *)
(* Log entry reconstruction                                            *)
(* ------------------------------------------------------------------ *)

(* span_event.fields is a flat list of (key, value) pairs produced by
   flatten_logs.  Each Obs.log call contributes ("log.level", _) and
   ("log.msg", _) followed by any caller-supplied extra fields.
   Split into per-entry sublists by grouping on "log.level" boundaries. *)
let split_log_entries fields =
  let rec go entries cur = function
    | [] ->
      if cur = [] then List.rev entries
      else List.rev (List.rev cur :: entries)
    | (("log.level", _) as kv) :: rest ->
      let entries' =
        if cur = [] then entries else List.rev cur :: entries
      in
      go entries' [kv] rest
    | kv :: rest -> go entries (kv :: cur) rest
  in
  go [] [] fields

(* ------------------------------------------------------------------ *)
(* Payload construction (Yojson)                                       *)
(* ------------------------------------------------------------------ *)

let trace_id_hex (hi, lo) = Printf.sprintf "%016Lx%016Lx" hi lo
let span_id_hex id        = Printf.sprintf "%016Lx" id

(* Wall-clock nanoseconds from the Eio clock as a decimal string —
   Loki's timestamp format. *)
let unix_ns_string clock =
  Printf.sprintf "%Ld"
    (Int64.of_float (Eio.Time.now clock *. 1e9))

(* Stream labels as a JSON object built with Yojson. *)
let stream_labels_json pairs =
  `Assoc (List.map (fun (k, v) -> (k, `String v)) pairs)

(* Each value is a 2-element JSON array [timestamp_ns, log_line],
   compatible with Loki 2.x (loki-stack Helm chart) and Loki 3.x. *)
let loki_push_body ~stream_labels ~values =
  let stream_obj = stream_labels_json stream_labels in
  let values_json =
    `List (List.map (fun (ts, line) ->
      `List [ `String ts; `String line ]
    ) values)
  in
  let payload =
    `Assoc [
      "streams", `List [
        `Assoc [
          "stream", stream_obj;
          "values", values_json;
        ]
      ]
    ]
  in
  Yojson.Safe.to_string payload

(* ------------------------------------------------------------------ *)
(* Backend                                                             *)
(* ------------------------------------------------------------------ *)

let create ~net ~clock ~url ?(label_names = []) () : Obs.backend =
  let emit_span (e : Obs.span_event) =
    let stream_labels =
      ("service", e.service) ::
      List.filter_map (fun name ->
        Option.map (fun v -> (name, v)) (List.assoc_opt name e.context)
      ) label_names
    in
    let ts       = unix_ns_string clock in
    let trace_id = trace_id_hex e.trace_ctx.Obs_trace.trace_id in
    let span_id  = span_id_hex  e.trace_ctx.Obs_trace.span_id  in
    let trace    = trace_fields trace_id span_id in
    let entries  = split_log_entries e.fields in
    let values =
      if entries = [] then
        (* Span had no Obs.log calls — emit a single span-completion line. *)
        let status = match e.status with `Ok -> "ok" | `Error s -> "error:" ^ s in
        let line = logfmt
          ([("level", "info"); ("span", e.name); ("status", status)] @ trace)
        in
        [ (ts, line) ]
      else
        List.map (fun entry ->
          let level = Option.value ~default:"info"
              (List.assoc_opt "log.level" entry) in
          let msg   = Option.value ~default:""
              (List.assoc_opt "log.msg" entry) in
          let extra =
            List.filter (fun (k, _) -> k <> "log.level" && k <> "log.msg") entry
          in
          let line = logfmt
            ([ ("level", level); ("msg", msg); ("span", e.name) ] @ extra @ trace)
          in
          (ts, line)
        ) entries
    in
    let body = loki_push_body ~stream_labels ~values in
    (match http_post ~net ~clock ~url ~body with
     | Ok ()      -> ()
     | Error msg  -> Printf.eprintf "[obs-loki] %s\n%!" msg)
  in
  { Obs.emit_span; emit_metric = (fun _ -> ()) }
