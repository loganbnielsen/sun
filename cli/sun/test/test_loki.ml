let check_string = Alcotest.(check string)
let check_int    = Alcotest.(check int)

module L = Sun_cli_loki

(* ── split_body_and_status ──────────────────────────────────────────── *)

let test_split_body_and_status_normal () =
  let (body, code) = L.split_body_and_status "{\"a\":1}\n200" in
  check_string "body" "{\"a\":1}" body;
  Alcotest.(check (option int)) "code" (Some 200) code

let test_split_body_and_status_no_newline () =
  let (body, code) = L.split_body_and_status "no newline here" in
  check_string "whole string is body" "no newline here" body;
  Alcotest.(check (option int)) "no code" None code

(* ── parse_query_range_body ─────────────────────────────────────────── *)

let success_body = {|
{"status": "success",
 "data": {"resultType": "streams",
   "result": [
     {"stream": {"app": "charge-svc"},
      "values": [["1693500002000000000", "second"], ["1693500001000000000", "first"]]}
   ]}}
|}

let empty_body = {|{"status": "success", "data": {"resultType": "streams", "result": []}}|}

let error_body = {|{"status": "error", "error": "parse error", "errorType": "bad_data"}|}

let test_parse_success_orders_oldest_first () =
  match L.parse_query_range_body success_body with
  | Ok [ a; b ] ->
    check_string "oldest first" "first" a.L.text;
    check_string "then newest" "second" b.L.text
  | Ok _ -> Alcotest.fail "expected exactly two lines"
  | Error e -> Alcotest.fail ("expected Ok, got Error " ^ e)

let test_parse_empty_result_is_ok_empty () =
  match L.parse_query_range_body empty_body with
  | Ok [] -> ()
  | Ok _ -> Alcotest.fail "expected an empty list"
  | Error e -> Alcotest.fail ("expected Ok [], got Error " ^ e)

let test_parse_error_status_is_error () =
  match L.parse_query_range_body error_body with
  | Ok _ -> Alcotest.fail "expected Error for status=error"
  | Error _ -> ()

let test_parse_malformed_json_is_error () =
  match L.parse_query_range_body "not json at all {" with
  | Ok _ -> Alcotest.fail "expected Error for malformed JSON"
  | Error _ -> ()

(* ── classify_process_error ─────────────────────────────────────────── *)

let test_classify_timeout () =
  match L.classify_process_error (Sun_cli_process.Timeout 5.0) with
  | L.Timeout -> ()
  | _ -> Alcotest.fail "expected Timeout"

let test_classify_curl_timeout_exit_code () =
  match L.classify_process_error (Sun_cli_process.Non_zero { exit_code = 28; stderr = "" }) with
  | L.Timeout -> ()
  | _ -> Alcotest.fail "expected Timeout for curl exit 28"

let test_classify_connection_failed () =
  match L.classify_process_error (Sun_cli_process.Non_zero { exit_code = 7; stderr = "" }) with
  | L.Connection_failed -> ()
  | _ -> Alcotest.fail "expected Connection_failed for curl exit 7"

let test_classify_other () =
  match L.classify_process_error (Sun_cli_process.Non_zero { exit_code = 22; stderr = "boom" }) with
  | L.Other msg -> check_int "message mentions exit code" 1
      (if String.length msg > 0 then 1 else 0)
  | _ -> Alcotest.fail "expected Other"

(* ── query_range_argv ───────────────────────────────────────────────── *)

let test_query_range_argv_contains_logql_labels () =
  let argv = L.query_range_argv ~base_url:"http://localhost:3100" ~ns:"acme-payments"
      ~k8s_name:"charge-svc" ~limit:50 ~timeout_s:5.0 in
  let joined = String.concat " " argv in
  check_int "mentions namespace label" 1
    (if (try ignore (Str.search_forward (Str.regexp_string "acme-payments") joined 0); true
         with Not_found -> false) then 1 else 0);
  check_int "mentions app label" 1
    (if (try ignore (Str.search_forward (Str.regexp_string "charge-svc") joined 0); true
         with Not_found -> false) then 1 else 0)

let () =
  Alcotest.run "loki"
    [ ("split_body_and_status",
       [ Alcotest.test_case "normal" `Quick test_split_body_and_status_normal;
         Alcotest.test_case "no newline" `Quick test_split_body_and_status_no_newline;
       ]);
      ("parse_query_range_body",
       [ Alcotest.test_case "success orders oldest first" `Quick test_parse_success_orders_oldest_first;
         Alcotest.test_case "empty result is Ok []" `Quick test_parse_empty_result_is_ok_empty;
         Alcotest.test_case "error status is Error" `Quick test_parse_error_status_is_error;
         Alcotest.test_case "malformed JSON is Error" `Quick test_parse_malformed_json_is_error;
       ]);
      ("classify_process_error",
       [ Alcotest.test_case "Timeout" `Quick test_classify_timeout;
         Alcotest.test_case "curl exit 28 -> Timeout" `Quick test_classify_curl_timeout_exit_code;
         Alcotest.test_case "curl exit 7 -> Connection_failed" `Quick test_classify_connection_failed;
         Alcotest.test_case "other exit code -> Other" `Quick test_classify_other;
       ]);
      ("query_range_argv",
       [ Alcotest.test_case "contains logql labels" `Quick test_query_range_argv_contains_logql_labels;
       ]);
    ]
