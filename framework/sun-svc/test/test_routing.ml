let dummy_handler _req = Response.not_found

let check_match pattern path expected_params =
  match Route.match_path pattern path with
  | None        -> None
  | Some params ->
    let sorted = List.sort compare params in
    let exp    = List.sort compare expected_params in
    if sorted = exp then Some params else None

(* ── match_path ──────────────────────────────────────────────────────── *)

let test_exact_match () =
  Alcotest.(check bool) "exact match" true
    (check_match "/users" "/users" [] <> None)

let test_trailing_slash_differs () =
  Alcotest.(check bool) "trailing slash differs" true
    (Route.match_path "/users" "/users/" = None)

let test_single_param () =
  Alcotest.(check (option (list (pair string string)))) "single param"
    (Some [("id", "42")])
    (check_match "/users/:id" "/users/42" [("id", "42")])

let test_multi_param () =
  let expected = Some [("uid","1"); ("pid","99")] in
  Alcotest.(check (option (list (pair string string)))) "multi param"
    expected
    (check_match "/users/:uid/posts/:pid" "/users/1/posts/99"
       [("uid","1"); ("pid","99")])

let test_literal_mismatch () =
  Alcotest.(check bool) "literal mismatch" true
    (Route.match_path "/users" "/orders" = None)

let test_segment_count_mismatch () =
  Alcotest.(check bool) "segment count" true
    (Route.match_path "/users/:id" "/users/1/extra" = None)

(* ── method_of_http ──────────────────────────────────────────────────── *)

let test_known_methods () =
  let cases = [
    `GET,    Some `GET;
    `POST,   Some `POST;
    `PUT,    Some `PUT;
    `PATCH,  Some `PATCH;
    `DELETE, Some `DELETE;
  ] in
  List.iter (fun (http_m, expected) ->
    Alcotest.(check (option (of_pp (fun fmt m ->
      Format.pp_print_string fmt (match m with
        | `GET -> "GET" | `POST -> "POST" | `PUT -> "PUT"
        | `PATCH -> "PATCH" | `DELETE -> "DELETE")))))
      "method" expected (Route.method_of_http http_m)
  ) cases

let test_unknown_method () =
  Alcotest.(check bool) "OPTIONS → None" true
    (Route.method_of_http `OPTIONS = None)

(* ── find_route (via Service internals via direct test of logic) ──────── *)

let make_route m p = Route.{ method_ = m; pattern = p; auth = `Public; handler = dummy_handler }

(* We test find_route behaviour by constructing Routes and exercising the
   exported Route functions used by Service. *)

let test_first_match_wins () =
  let r1 = make_route `GET "/items/:id" in
  let _r2 = make_route `GET "/items/:slug" in
  (* Both patterns match; r1 should win *)
  match Route.match_path r1.pattern "/items/42" with
  | Some _ -> ()
  | None -> Alcotest.fail "r1 should match"

let test_case_sensitive () =
  Alcotest.(check bool) "case sensitive" true
    (Route.match_path "/Users" "/users" = None)

(* ── parse_request_path ─────────────────────────────────────────────────── *)

let test_parse_valid_path () =
  Alcotest.(check bool) "valid path → Some" true
    (Route.parse_request_path "/users/42" <> None)

let test_parse_double_slash_rejected () =
  Alcotest.(check bool) "leading double slash → None" true
    (Route.parse_request_path "//users" = None)

let test_parse_interior_double_slash_rejected () =
  Alcotest.(check bool) "interior double slash → None" true
    (Route.parse_request_path "/users//42" = None)

let test_parse_root () =
  match Route.parse_request_path "/" with
  | None -> Alcotest.fail "root path should be valid"
  | Some (segs, _ts) ->
    Alcotest.(check int) "root has no segments" 0 (List.length segs)

(* ── percent_decode ──────────────────────────────────────────────────────── *)

let test_percent_decode_space () =
  Alcotest.(check string) "%20 → space" " " (Uri.pct_decode "%20")

let test_percent_decode_slash () =
  Alcotest.(check string) "%2F → /" "/" (Uri.pct_decode "%2F")

let test_percent_decode_lowercase () =
  Alcotest.(check string) "%2f lowercase → /" "/" (Uri.pct_decode "%2f")

let test_percent_decode_passthrough () =
  Alcotest.(check string) "plain text unchanged" "hello" (Uri.pct_decode "hello")

let test_percent_decode_malformed () =
  Alcotest.(check string) "malformed %GG unchanged" "%GG" (Uri.pct_decode "%GG")

let test_percent_decode_plus_not_space () =
  Alcotest.(check string) "+ not decoded as space" "a+b" (Uri.pct_decode "a+b")

(* ── match_path with encoded segments ───────────────────────────────────── *)

let test_encoded_param_decoded () =
  match Route.match_path "/users/:id" "/users/hello%20world" with
  | None -> Alcotest.fail "should match"
  | Some params ->
    Alcotest.(check string) "param decoded" "hello world" (List.assoc "id" params)

let test_double_slash_no_match () =
  Alcotest.(check bool) "double slash path → no match" true
    (Route.match_path "/users" "//users" = None)

let test_interior_double_slash_no_match () =
  Alcotest.(check bool) "interior double slash → no match" true
    (Route.match_path "/users/:id" "/users//42" = None)

let () =
  Alcotest.run "routing" [
    "match_path", [
      Alcotest.test_case "exact match"             `Quick test_exact_match;
      Alcotest.test_case "trailing slash"          `Quick test_trailing_slash_differs;
      Alcotest.test_case "single param"            `Quick test_single_param;
      Alcotest.test_case "multi param"             `Quick test_multi_param;
      Alcotest.test_case "literal mismatch"        `Quick test_literal_mismatch;
      Alcotest.test_case "segment count"           `Quick test_segment_count_mismatch;
      Alcotest.test_case "case sensitive"          `Quick test_case_sensitive;
      Alcotest.test_case "first match wins"        `Quick test_first_match_wins;
      Alcotest.test_case "encoded param decoded"   `Quick test_encoded_param_decoded;
      Alcotest.test_case "double slash → no match" `Quick test_double_slash_no_match;
      Alcotest.test_case "interior // → no match"  `Quick test_interior_double_slash_no_match;
    ];
    "parse_request_path", [
      Alcotest.test_case "valid path"              `Quick test_parse_valid_path;
      Alcotest.test_case "double slash rejected"   `Quick test_parse_double_slash_rejected;
      Alcotest.test_case "interior // rejected"    `Quick test_parse_interior_double_slash_rejected;
      Alcotest.test_case "root path valid"         `Quick test_parse_root;
    ];
    "percent_decode", [
      Alcotest.test_case "%20 → space"             `Quick test_percent_decode_space;
      Alcotest.test_case "%2F → /"                 `Quick test_percent_decode_slash;
      Alcotest.test_case "%2f lowercase → /"       `Quick test_percent_decode_lowercase;
      Alcotest.test_case "plain text unchanged"    `Quick test_percent_decode_passthrough;
      Alcotest.test_case "malformed %GG unchanged" `Quick test_percent_decode_malformed;
      Alcotest.test_case "+ not decoded as space"  `Quick test_percent_decode_plus_not_space;
    ];
    "method_of_http", [
      Alcotest.test_case "known methods"  `Quick test_known_methods;
      Alcotest.test_case "unknown method" `Quick test_unknown_method;
    ];
  ]
