(* invocation_of_headers: pure header-parsing, no network needed. *)

let test_invocation_of_headers_success () =
  let headers =
    Http.Header.of_list
      [ ("Lambda-Runtime-Aws-Request-Id", "req-123");
        ("Lambda-Runtime-Deadline-Ms", "1700000000000");
        ("Lambda-Runtime-Invoked-Function-Arn", "arn:aws:lambda:us-east-1:123456789012:function:my-fn");
        ("Lambda-Runtime-Trace-Id", "Root=1-abc");
      ]
  in
  match Lambda_runtime.invocation_of_headers ~headers ~payload:{|{"key":"value"}|} with
  | Error msg -> Alcotest.fail msg
  | Ok { request_id; deadline_ms; invoked_function_arn; trace_id; payload } ->
    Alcotest.(check string) "request_id" "req-123" request_id;
    Alcotest.(check int64) "deadline_ms" 1700000000000L deadline_ms;
    Alcotest.(check string) "invoked_function_arn" "arn:aws:lambda:us-east-1:123456789012:function:my-fn"
      invoked_function_arn;
    Alcotest.(check (option string)) "trace_id" (Some "Root=1-abc") trace_id;
    Alcotest.(check string) "payload" {|{"key":"value"}|} payload

let test_invocation_of_headers_missing_request_id () =
  Alcotest.(check bool) "missing Lambda-Runtime-Aws-Request-Id is rejected" true
    (match Lambda_runtime.invocation_of_headers ~headers:(Http.Header.init ()) ~payload:"{}" with
     | Error _ -> true
     | Ok _ -> false)

let test_invocation_of_headers_missing_optional_fields () =
  (* deadline_ms/invoked_function_arn/trace_id are all best-effort — only
     the request id is load-bearing enough to reject on. *)
  let headers = Http.Header.of_list [ ("Lambda-Runtime-Aws-Request-Id", "req-1") ] in
  match Lambda_runtime.invocation_of_headers ~headers ~payload:"{}" with
  | Error msg -> Alcotest.fail msg
  | Ok { deadline_ms; invoked_function_arn; trace_id; _ } ->
    Alcotest.(check int64) "deadline_ms defaults to 0" 0L deadline_ms;
    Alcotest.(check string) "invoked_function_arn defaults to empty" "" invoked_function_arn;
    Alcotest.(check (option string)) "trace_id defaults to None" None trace_id

(* Mock Runtime API server — plain HTTP, no TLS/SNI blocker here (unlike
   s3-eio/dynamo-eio's aws-eio-backed tests), so this exercises the real
   wire path end to end. *)
let with_mock_runtime_api env ~callback f =
  Eio.Switch.run @@ fun sw ->
  let server = Cohttp_eio.Server.make ~callback () in
  let socket = Eio.Net.listen ~backlog:5 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with `Tcp (_, port) -> port | _ -> failwith "unexpected address family" in
  let stop, stop_r = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Cohttp_eio.Server.run ~stop ~on_error:(fun _ -> ()) socket server;
      `Stop_daemon);
  Fun.protect ~finally:(fun () -> Eio.Promise.resolve stop_r ()) (fun () -> f ~sw ~base:(Printf.sprintf "127.0.0.1:%d" port))

let test_next_invocation_real_call () =
  Eio_main.run @@ fun env ->
  let callback _conn (req : Http.Request.t) _body =
    Alcotest.(check string) "path" "/2018-06-01/runtime/invocation/next" (Http.Request.resource req);
    let headers =
      Http.Header.of_list
        [ ("Lambda-Runtime-Aws-Request-Id", "req-abc"); ("Lambda-Runtime-Deadline-Ms", "123") ]
    in
    Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body:{|{"hello":"world"}|} ()
  in
  with_mock_runtime_api env ~callback (fun ~sw ~base ->
      match Lambda_runtime.next_invocation ~net:env#net ~sw ~base with
      | Error msg -> Alcotest.fail msg
      | Ok { request_id; payload; _ } ->
        Alcotest.(check string) "request_id" "req-abc" request_id;
        Alcotest.(check string) "payload" {|{"hello":"world"}|} payload)

let test_respond_posts_to_the_right_path_with_the_right_body () =
  Eio_main.run @@ fun env ->
  let callback _conn (req : Http.Request.t) body =
    Alcotest.(check string) "method" "POST" (Http.Request.meth req |> Http.Method.to_string);
    Alcotest.(check string) "path" "/2018-06-01/runtime/invocation/req-1/response" (Http.Request.resource req);
    let received = Eio.Buf_read.(parse_exn take_all) body ~max_size:1024 in
    Alcotest.(check string) "body" {|{"result":"ok"}|} received;
    Cohttp_eio.Server.respond_string ~status:`Accepted ~body:"" ()
  in
  with_mock_runtime_api env ~callback (fun ~sw ~base ->
      match Lambda_runtime.respond ~net:env#net ~sw ~base ~request_id:"req-1" ~body:{|{"result":"ok"}|} with
      | Ok () -> ()
      | Error msg -> Alcotest.fail msg)

let test_respond_error_posts_error_shape_and_header () =
  Eio_main.run @@ fun env ->
  let callback _conn (req : Http.Request.t) body =
    Alcotest.(check string) "path" "/2018-06-01/runtime/invocation/req-2/error" (Http.Request.resource req);
    Alcotest.(check (option string)) "Lambda-Runtime-Function-Error-Type header" (Some "Unhandled")
      (Http.Header.get (Http.Request.headers req) "Lambda-Runtime-Function-Error-Type");
    let received = Eio.Buf_read.(parse_exn take_all) body ~max_size:1024 in
    (match Yojson.Safe.from_string received with
     | `Assoc fields ->
       Alcotest.(check bool) "errorMessage present" true (List.mem_assoc "errorMessage" fields);
       Alcotest.(check bool) "errorType present" true (List.mem_assoc "errorType" fields)
     | _ -> Alcotest.fail "expected a JSON object");
    Cohttp_eio.Server.respond_string ~status:`Accepted ~body:"" ()
  in
  with_mock_runtime_api env ~callback (fun ~sw ~base ->
      match
        Lambda_runtime.respond_error ~net:env#net ~sw ~base ~request_id:"req-2" ~error_message:"boom"
          ~error_type:"RuntimeError"
      with
      | Ok () -> ()
      | Error msg -> Alcotest.fail msg)

let test_post_error_status_is_reported () =
  Eio_main.run @@ fun env ->
  let callback _conn _req _body = Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"" () in
  with_mock_runtime_api env ~callback (fun ~sw ~base ->
      Alcotest.(check bool) "a non-2xx response from the Runtime API itself is surfaced as an error" true
        (match Lambda_runtime.respond ~net:env#net ~sw ~base ~request_id:"req-3" ~body:"{}" with
         | Error _ -> true
         | Ok () -> false))

(* A broken/misconfigured Runtime API endpoint could return a non-2xx status
   while still carrying a stale Lambda-Runtime-Aws-Request-Id header (e.g.
   from a caching proxy); next_invocation must reject on status, not just on
   header presence. *)
let test_next_invocation_rejects_non_2xx () =
  Eio_main.run @@ fun env ->
  let callback _conn (req : Http.Request.t) _body =
    let headers = Http.Header.of_list [ ("Lambda-Runtime-Aws-Request-Id", "stale-req") ] in
    ignore req;
    Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~headers ~body:"" ()
  in
  with_mock_runtime_api env ~callback (fun ~sw ~base ->
      Alcotest.(check bool) "a non-2xx invocation/next response is rejected" true
        (match Lambda_runtime.next_invocation ~net:env#net ~sw ~base with
         | Error _ -> true
         | Ok _ -> false))

let test_init_error_posts_to_the_right_path () =
  Eio_main.run @@ fun env ->
  let callback _conn (req : Http.Request.t) body =
    Alcotest.(check string) "path" "/2018-06-01/runtime/init/error" (Http.Request.resource req);
    Alcotest.(check (option string)) "Lambda-Runtime-Function-Error-Type header" (Some "Unhandled")
      (Http.Header.get (Http.Request.headers req) "Lambda-Runtime-Function-Error-Type");
    ignore (Eio.Buf_read.(parse_exn take_all) body ~max_size:1024);
    Cohttp_eio.Server.respond_string ~status:`Accepted ~body:"" ()
  in
  with_mock_runtime_api env ~callback (fun ~sw ~base ->
      match
        Lambda_runtime.init_error ~net:env#net ~sw ~base ~error_message:"bad config" ~error_type:"ConfigError"
      with
      | Ok () -> ()
      | Error msg -> Alcotest.fail msg)

(* No automated test for Cancelled re-raising in next_invocation/post: any
   test built on Eio.Fiber.first racing a cancellation swallows the losing
   fiber's Cancelled as part of its own cleanup regardless of whether the
   loser's code is correct or buggy, so it can't distinguish the two.
   Verified by inspection instead. *)

let () =
  Alcotest.run "lambda_runtime"
    [ ( "invocation_of_headers",
        [ Alcotest.test_case "parses all fields" `Quick test_invocation_of_headers_success;
          Alcotest.test_case "rejects a missing request id" `Quick test_invocation_of_headers_missing_request_id;
          Alcotest.test_case "defaults optional fields" `Quick test_invocation_of_headers_missing_optional_fields;
        ] );
      ( "wire protocol (real local mock server)",
        [ Alcotest.test_case "next_invocation" `Quick test_next_invocation_real_call;
          Alcotest.test_case "respond" `Quick test_respond_posts_to_the_right_path_with_the_right_body;
          Alcotest.test_case "respond_error" `Quick test_respond_error_posts_error_shape_and_header;
          Alcotest.test_case "non-2xx from the Runtime API is reported" `Quick test_post_error_status_is_reported;
          Alcotest.test_case "next_invocation rejects non-2xx" `Quick test_next_invocation_rejects_non_2xx;
          Alcotest.test_case "init_error" `Quick test_init_error_posts_to_the_right_path;
        ] );
    ]
