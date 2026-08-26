let test_host_and_path_real_aws () =
  let config =
    { S3_client.bucket = "my-bucket"; region = "us-west-2";
      credentials = Aws_credentials.of_env ~region:"us-west-2" ();
      endpoint = None }
  in
  Alcotest.(check (pair string string)) "virtual-hosted-style"
    ("my-bucket.s3.us-west-2.amazonaws.com", "/path/to/object")
    (S3_client.host_and_path config ~key:"path/to/object")

let test_host_and_path_endpoint_override_ipv6 () =
  (* Regression test: split_host_port used to split on the *last* colon
     unconditionally, which cuts into an IPv6 literal's own colons instead
     of finding the port separator. "[::1]:9000" must parse as host "::1",
     not something mangled. *)
  let config =
    { S3_client.bucket = "my-bucket"; region = "us-west-2";
      credentials = Aws_credentials.of_env ~region:"us-west-2" ();
      endpoint = Some "[::1]:9000" }
  in
  Alcotest.(check (pair string string)) "IPv6-bracketed endpoint, port split off correctly"
    ("::1", "/my-bucket/path/to/object")
    (S3_client.host_and_path config ~key:"path/to/object")

let test_host_and_path_endpoint_override () =
  let config =
    { S3_client.bucket = "my-bucket"; region = "us-west-2";
      credentials = Aws_credentials.of_env ~region:"us-west-2" ();
      endpoint = Some "127.0.0.1:9000" }
  in
  Alcotest.(check (pair string string)) "path-style against the override host, port split off"
    ("127.0.0.1", "/my-bucket/path/to/object")
    (S3_client.host_and_path config ~key:"path/to/object")

(* Regression test for a real finding: config.bucket/region become an
   unencoded Host header and TCP connection target with no percent-encoding
   pass (unlike key), so a caller building config from less-trusted input
   (e.g. a per-tenant bucket name) could otherwise inject extra header
   lines. validate_config must fail closed, not silently proceed. *)
let test_validate_config_rejects_crlf_in_bucket () =
  let config =
    { S3_client.bucket = "evil\r\nX-Injected: 1"; region = "us-east-1";
      credentials = Aws_credentials.of_env ~region:"us-east-1" ();
      endpoint = None }
  in
  Alcotest.(check bool) "CRLF in bucket is rejected" true
    (match S3_client.validate_config config with Error (Invalid_config _) -> true | _ -> false)

let test_validate_config_rejects_crlf_in_region () =
  let config =
    { S3_client.bucket = "my-bucket"; region = "us-east-1\r\nX-Injected: 1";
      credentials = Aws_credentials.of_env ~region:"us-east-1" ();
      endpoint = None }
  in
  Alcotest.(check bool) "CRLF in region is rejected" true
    (match S3_client.validate_config config with Error (Invalid_config _) -> true | _ -> false)

let test_validate_config_accepts_normal_config () =
  let config =
    { S3_client.bucket = "my-bucket"; region = "us-east-1";
      credentials = Aws_credentials.of_env ~region:"us-east-1" ();
      endpoint = None }
  in
  Alcotest.(check bool) "ordinary config passes" true (Result.is_ok (S3_client.validate_config config))

(* interpret_* mappers are pure — see s3_client.ml's top comment on why
   operation tests exercise these directly instead of a mock server
   (signed_request always negotiates real TLS, which a bare-IP loopback mock
   can't satisfy). *)

let not_found_xml = {|<?xml version="1.0"?><Error><Code>NoSuchKey</Code><Message>x</Message></Error>|}

let test_interpret_put_success () =
  Alcotest.(check bool) "200 -> Ok ()" true (Result.is_ok (S3_client.interpret_put (200, [], "")))

let test_interpret_put_error () =
  match S3_client.interpret_put (403, [], not_found_xml) with
  | Error (S3_error.Service_error { code = "NoSuchKey"; status = 403; _ }) -> ()
  | _ -> Alcotest.fail "expected Service_error"

let test_interpret_get_success () =
  match S3_client.interpret_get (200, [], "object contents") with
  | Ok body -> Alcotest.(check string) "200 -> Ok body" "object contents" body
  | Error e -> Alcotest.fail (S3_error.to_string e)

let test_interpret_get_not_found () =
  Alcotest.(check bool) "404 -> Not_found" true
    (match S3_client.interpret_get (404, [], not_found_xml) with Error Not_found -> true | _ -> false)

let test_interpret_delete_success () =
  Alcotest.(check bool) "204 -> Ok ()" true (Result.is_ok (S3_client.interpret_delete (204, [], "")))

let test_interpret_head_success () =
  let headers =
    [ ("Content-Length", "42"); ("ETag", "\"abc123\""); ("Content-Type", "text/plain");
      ("Last-Modified", "Wed, 26 Aug 2026 00:00:00 GMT") ]
  in
  match S3_client.interpret_head (200, headers, "") with
  | Error e -> Alcotest.fail (S3_error.to_string e)
  | Ok { content_length; etag; content_type; last_modified } ->
    Alcotest.(check (option int)) "content_length" (Some 42) content_length;
    Alcotest.(check (option string)) "etag" (Some "\"abc123\"") etag;
    Alcotest.(check (option string)) "content_type" (Some "text/plain") content_type;
    Alcotest.(check (option string)) "last_modified" (Some "Wed, 26 Aug 2026 00:00:00 GMT") last_modified

let test_interpret_head_case_insensitive_headers () =
  (* Real servers vary header casing; header_ci must compare
     case-insensitively rather than expecting a canonical form. *)
  match S3_client.interpret_head (200, [ ("content-length", "7"); ("etag", "\"x\"") ], "") with
  | Error e -> Alcotest.fail (S3_error.to_string e)
  | Ok { content_length; etag; _ } ->
    Alcotest.(check (option int)) "content_length" (Some 7) content_length;
    Alcotest.(check (option string)) "etag" (Some "\"x\"") etag

let test_interpret_head_not_found_has_no_body_to_parse () =
  (* A HEAD 404 has an empty body (HTTP semantics) — of_response still
     classifies status 404 as Not_found unconditionally, body or no body. *)
  Alcotest.(check bool) "404 with empty body -> Not_found" true
    (match S3_client.interpret_head (404, [], "") with Error Not_found -> true | _ -> false)

let () =
  Alcotest.run "s3_client"
    [ ( "host_and_path",
        [ Alcotest.test_case "real AWS: virtual-hosted-style" `Quick test_host_and_path_real_aws;
          Alcotest.test_case "endpoint override: path-style" `Quick test_host_and_path_endpoint_override;
          Alcotest.test_case "endpoint override: IPv6-bracketed host:port" `Quick
            test_host_and_path_endpoint_override_ipv6;
        ] );
      ( "validate_config",
        [ Alcotest.test_case "rejects CRLF in bucket" `Quick test_validate_config_rejects_crlf_in_bucket;
          Alcotest.test_case "rejects CRLF in region" `Quick test_validate_config_rejects_crlf_in_region;
          Alcotest.test_case "accepts an ordinary config" `Quick test_validate_config_accepts_normal_config;
        ] );
      ( "interpret",
        [ Alcotest.test_case "put: success" `Quick test_interpret_put_success;
          Alcotest.test_case "put: error" `Quick test_interpret_put_error;
          Alcotest.test_case "get: success" `Quick test_interpret_get_success;
          Alcotest.test_case "get: not found" `Quick test_interpret_get_not_found;
          Alcotest.test_case "delete: success" `Quick test_interpret_delete_success;
          Alcotest.test_case "head: success, parses headers" `Quick test_interpret_head_success;
          Alcotest.test_case "head: header names compared case-insensitively" `Quick
            test_interpret_head_case_insensitive_headers;
          Alcotest.test_case "head: not found has no body to parse" `Quick
            test_interpret_head_not_found_has_no_body_to_parse;
        ] );
    ]
