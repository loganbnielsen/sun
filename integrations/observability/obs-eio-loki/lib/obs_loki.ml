(* ------------------------------------------------------------------ *)
(* HTTP client                                                         *)
(* ------------------------------------------------------------------ *)

let parse_url url =
  let s =
    if String.length url >= 7 && String.sub url 0 7 = "http://"
    then String.sub url 7 (String.length url - 7)
    else url
  in
  let hostport = match String.index_opt s '/' with
    | None   -> s
    | Some i -> String.sub s 0 i
  in
  match String.rindex_opt hostport ':' with
  | None -> (hostport, 3100)
  | Some i ->
    let host   = String.sub hostport 0 i in
    let port_s = String.sub hostport (i + 1) (String.length hostport - i - 1) in
    (match int_of_string_opt port_s with
     | Some p -> (host, p)
     | None   -> (hostport, 3100))

let http_post ~net ~clock ~url ~body =
  let (host, port) = parse_url url in
  let req =
    String.concat "\r\n" [
      "POST /loki/api/v1/push HTTP/1.1";
      Printf.sprintf "Host: %s:%d" host port;
      "Content-Type: application/json";
      Printf.sprintf "Content-Length: %d" (String.length body);
      "Connection: close";
      "";
      "";
    ] ^ body
  in
  try
    Eio.Time.with_timeout_exn clock 5.0 (fun () ->
      Eio.Net.with_tcp_connect net ~host ~service:(string_of_int port) (fun flow ->
        Eio.Flow.copy_string req flow;
        let buf = Eio.Buf_read.of_flow ~max_size:(64 * 1024) flow in
        let status_line = Eio.Buf_read.line buf in
        match String.split_on_char ' ' status_line with
        | _ :: code :: _ ->
          (match int_of_string_opt code with
           | Some n when n >= 200 && n < 300 -> Ok ()
           | Some n ->
             (* Drain headers to reach the body, then read up to 512 bytes. *)
             let body =
               try
                 let rec skip_headers () =
                   let line = Eio.Buf_read.line buf in
                   if line = "" || line = "\r" then () else skip_headers ()
                 in
                 skip_headers ();
                 (* take_while avoids End_of_file on bodies shorter than 512 bytes. *)
                 let s = Eio.Buf_read.take_while (fun _ -> true) buf in
                 String.sub s 0 (min (String.length s) 512)
               with _ -> ""
             in
             let detail = if body = "" then "" else ": " ^ String.trim body in
             Error (Printf.sprintf "Loki returned HTTP %d%s" n detail)
           | None   -> Error ("unexpected Loki response: " ^ status_line))
        | _ -> Error ("unexpected Loki response: " ^ status_line)))
  with
  | Eio.Time.Timeout -> Error "Loki push timed out after 5s"
  | exn              -> Error ("Loki push: " ^ Printexc.to_string exn)

(* ------------------------------------------------------------------ *)
(* Encoding helpers                                                    *)
(* ------------------------------------------------------------------ *)

(* JSON string — used for stream labels and structured metadata only. *)
let jstr s = Printf.sprintf "%S" s

let jobj pairs =
  "{" ^
  String.concat ","
    (List.map (fun (k, v) -> jstr k ^ ":" ^ jstr v) pairs)
  ^ "}"

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
(* Payload construction                                                *)
(* ------------------------------------------------------------------ *)

let trace_id_hex (hi, lo) = Printf.sprintf "%016Lx%016Lx" hi lo
let span_id_hex id        = Printf.sprintf "%016Lx" id

(* Wall-clock nanoseconds as a decimal string — Loki's timestamp format. *)
let unix_ns_string () =
  Printf.sprintf "%Ld" (Int64.of_float (Unix.gettimeofday () *. 1e9))

(* Each value is a 2-element tuple [timestamp_ns, log_line], compatible
   with Loki 2.x (loki-stack Helm chart) and Loki 3.x. *)
let loki_push_body ~stream_labels ~values =
  let stream = jobj stream_labels in
  let vals =
    "[" ^
    String.concat ","
      (List.map (fun (ts, line) ->
         "[" ^ jstr ts ^ "," ^ jstr line ^ "]") values)
    ^ "]"
  in
  Printf.sprintf {|{"streams":[{"stream":%s,"values":%s}]}|} stream vals

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
    let ts       = unix_ns_string () in
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
