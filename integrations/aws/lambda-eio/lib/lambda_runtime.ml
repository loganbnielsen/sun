type invocation = {
  request_id : string;
  deadline_ms : int64;
  invoked_function_arn : string;
  trace_id : string option;
  payload : string;
}

let runtime_api_base () =
  match Sys.getenv_opt "AWS_LAMBDA_RUNTIME_API" with
  | Some base -> Ok base
  | None ->
    Error
      "AWS_LAMBDA_RUNTIME_API is not set — not running in a Lambda execution environment (or a local Runtime \
       Interface Emulator)"

let max_response_body_bytes = 64 * 1024
(* The Runtime API's own JSON acknowledgement bodies are tiny; this isn't the
   6MB Lambda payload limit, which applies to next_invocation's body, read
   separately below with its own, larger bound. *)

let max_invocation_payload_bytes = 6 * 1024 * 1024

let read_body ~max_size body = Eio.Buf_read.(parse_exn take_all) body ~max_size

let client net = Cohttp_eio.Client.make ~https:None net

(* Parsing invocation-next's response headers is pure and separated from
   the network call so it's directly unit-testable with a synthetic
   Http.Header.t, in addition to the mock-server tests that exercise the
   whole request/response cycle. *)
let invocation_of_headers ~headers ~payload =
  match Http.Header.get headers "Lambda-Runtime-Aws-Request-Id" with
  | None -> Error "invocation/next response missing Lambda-Runtime-Aws-Request-Id header"
  | Some request_id ->
    let deadline_ms =
      match Http.Header.get headers "Lambda-Runtime-Deadline-Ms" with
      | Some s -> Option.value (Int64.of_string_opt s) ~default:0L
      | None -> 0L
    in
    let invoked_function_arn = Option.value (Http.Header.get headers "Lambda-Runtime-Invoked-Function-Arn") ~default:"" in
    let trace_id = Http.Header.get headers "Lambda-Runtime-Trace-Id" in
    Ok { request_id; deadline_ms; invoked_function_arn; trace_id; payload }

(* Eio.Cancel.Cancelled is always re-raised, never converted to an Error —
   it has to unwind the caller's structured concurrency correctly, not get
   reported as an ordinary result. *)
let next_invocation ~net ~sw ~base =
  let uri = Uri.of_string (Printf.sprintf "http://%s/2018-06-01/runtime/invocation/next" base) in
  match
    let resp, body = Cohttp_eio.Client.get (client net) ~sw uri in
    let status = Http.Response.status resp |> Http.Status.to_int in
    let payload = read_body ~max_size:max_invocation_payload_bytes body in
    (status, resp, payload)
  with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error ("next_invocation: " ^ Printexc.to_string exn)
  | status, _, _ when status < 200 || status >= 300 ->
    Error (Printf.sprintf "invocation/next returned HTTP %d" status)
  | _, resp, payload -> invocation_of_headers ~headers:(Http.Response.headers resp) ~payload

let post ~net ~sw ~uri ~headers ~body =
  match
    let resp, resp_body = Cohttp_eio.Client.post (client net) ~sw ~headers:(Http.Header.of_list headers) ~body:(Cohttp_eio.Body.of_string body) uri in
    let status = Http.Response.status resp |> Http.Status.to_int in
    ignore (read_body ~max_size:max_response_body_bytes resp_body);
    status
  with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Printexc.to_string exn)
  | status -> if status >= 200 && status < 300 then Ok () else Error (Printf.sprintf "runtime API returned HTTP %d" status)

let respond ~net ~sw ~base ~request_id ~body =
  let uri = Uri.of_string (Printf.sprintf "http://%s/2018-06-01/runtime/invocation/%s/response" base request_id) in
  post ~net ~sw ~uri ~headers:[] ~body

let error_body ~error_message ~error_type =
  Yojson.Safe.to_string (`Assoc [ ("errorMessage", `String error_message); ("errorType", `String error_type) ])

let respond_error ~net ~sw ~base ~request_id ~error_message ~error_type =
  let uri = Uri.of_string (Printf.sprintf "http://%s/2018-06-01/runtime/invocation/%s/error" base request_id) in
  post ~net ~sw ~uri ~headers:[ ("Lambda-Runtime-Function-Error-Type", "Unhandled") ]
    ~body:(error_body ~error_message ~error_type)

let init_error ~net ~sw ~base ~error_message ~error_type =
  let uri = Uri.of_string (Printf.sprintf "http://%s/2018-06-01/runtime/init/error" base) in
  post ~net ~sw ~uri ~headers:[ ("Lambda-Runtime-Function-Error-Type", "Unhandled") ]
    ~body:(error_body ~error_message ~error_type)

(* Cancellation (sun-fn's Lambda-mode graceful shutdown) is only meant to
   interrupt the *wait* for a new invocation, never abandon the ack for one
   already received — once next_invocation returns Ok, Lambda expects a
   response/error POST for that request_id no matter what. Eio.Cancel.protect
   defers any outer cancellation until the handler-and-ack sequence finishes;
   next_invocation itself stays outside the protected block, so it's still
   the natural, immediate place a stop signal takes effect. *)
let run_loop ~net ~sw ~base ~handler =
  let rec loop () =
    (match next_invocation ~net ~sw ~base with
     | Error msg ->
       (* Transient failures must not kill the loop — a warm execution
          environment is expected to keep calling next_invocation for its
          entire lifetime. *)
       Printf.eprintf "lambda-eio: next_invocation failed: %s\n%!" msg
     | Ok invocation ->
       Eio.Cancel.protect (fun () ->
         let result =
           try handler invocation with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn -> Error (Printexc.to_string exn)
         in
         match result with
         | Ok body -> (
           match respond ~net ~sw ~base ~request_id:invocation.request_id ~body with
           | Ok () -> ()
           | Error msg -> Printf.eprintf "lambda-eio: respond failed: %s\n%!" msg)
         | Error msg -> (
           match
             respond_error ~net ~sw ~base ~request_id:invocation.request_id ~error_message:msg
               ~error_type:"HandlerError"
           with
           | Ok () -> ()
           | Error post_msg -> Printf.eprintf "lambda-eio: respond_error failed: %s\n%!" post_msg)));
    loop ()
  in
  loop ()
