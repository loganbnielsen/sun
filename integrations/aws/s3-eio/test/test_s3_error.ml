let test_404_is_not_found () =
  Alcotest.(check bool) "404 classifies as Not_found" true
    (match S3_error.of_response ~status:404 ~body:"" with
     | Not_found -> true
     | _ -> false)

let test_404_is_not_found_even_with_a_body () =
  (* 404 is unconditionally Not_found in v1, even if the body happens to look
     like a parseable error document — see s3-eio.md. *)
  let body = {|<?xml version="1.0"?><Error><Code>NoSuchKey</Code><Message>x</Message></Error>|} in
  Alcotest.(check bool) "404 with a body is still Not_found" true
    (match S3_error.of_response ~status:404 ~body with
     | Not_found -> true
     | _ -> false)

let test_parseable_error_body () =
  let body =
    {|<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>AccessDenied</Code>
  <Message>Access Denied</Message>
  <RequestId>ABC123</RequestId>
</Error>|}
  in
  match S3_error.of_response ~status:403 ~body with
  | Service_error { code; message; status } ->
    Alcotest.(check string) "code" "AccessDenied" code;
    Alcotest.(check string) "message" "Access Denied" message;
    Alcotest.(check int) "status" 403 status
  | _ -> Alcotest.fail "expected Service_error"

let test_unparseable_body () =
  Alcotest.(check bool) "malformed body is Unparseable_error_response" true
    (match S3_error.of_response ~status:500 ~body:"not xml at all" with
     | Unparseable_error_response { status = 500; body = "not xml at all" } -> true
     | _ -> false)

let test_empty_body_is_unparseable () =
  (* HEAD responses never carry a body (HTTP semantics), so a non-404 HEAD
     error always lands here with an empty body — expected, not a bug. *)
  Alcotest.(check bool) "empty body (e.g. from a HEAD response) is Unparseable_error_response" true
    (match S3_error.of_response ~status:500 ~body:"" with
     | Unparseable_error_response { status = 500; body = "" } -> true
     | _ -> false)

let () =
  Alcotest.run "s3_error"
    [ ( "of_response",
        [ Alcotest.test_case "404 -> Not_found" `Quick test_404_is_not_found;
          Alcotest.test_case "404 -> Not_found even with a parseable body" `Quick
            test_404_is_not_found_even_with_a_body;
          Alcotest.test_case "parseable <Error> body -> Service_error" `Quick test_parseable_error_body;
          Alcotest.test_case "malformed body -> Unparseable_error_response" `Quick test_unparseable_body;
          Alcotest.test_case "empty body -> Unparseable_error_response" `Quick test_empty_body_is_unparseable;
        ] );
    ]
