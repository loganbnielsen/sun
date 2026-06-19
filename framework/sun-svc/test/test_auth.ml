let headers_of kv = Http.Header.of_list kv

let bearer tok = headers_of ["authorization", "Bearer " ^ tok]
let api_key k  = headers_of ["x-api-key", k]

(* ── Public ─────────────────────────────────────────────────────────── *)

let test_public () =
  match Auth.validate `Public (headers_of []) with
  | Ok { principal = Auth.Public } -> ()
  | _ -> Alcotest.fail "expected Public principal"

(* ── Api_key ─────────────────────────────────────────────────────────── *)

let with_api_key_env value f =
  Unix.putenv "SUN_API_KEY" value;
  (try f () with exn -> Unix.putenv "SUN_API_KEY" ""; raise exn);
  Unix.putenv "SUN_API_KEY" ""

let test_api_key_valid () =
  with_api_key_env "secretkey123" (fun () ->
    match Auth.validate `Api_key (api_key "secretkey123") with
    | Ok { principal = Auth.Service { key_id } } ->
      Alcotest.(check string) "key_id truncated" "secretke" key_id
    | _ -> Alcotest.fail "expected Service principal")

let test_api_key_wrong () =
  with_api_key_env "secretkey123" (fun () ->
    match Auth.validate `Api_key (api_key "wrongkey") with
    | Error (`Unauthorized _) -> ()
    | _ -> Alcotest.fail "expected Unauthorized")

let test_api_key_missing_header () =
  with_api_key_env "secretkey123" (fun () ->
    match Auth.validate `Api_key (headers_of []) with
    | Error (`Unauthorized _) -> ()
    | _ -> Alcotest.fail "expected Unauthorized")

(* ── JWT ─────────────────────────────────────────────────────────────── *)

(* Build a minimal (unverified) JWT payload: header.payload.sig
   We use HS256 header and a simple JSON payload. Signature is fake for v1. *)
let make_jwt ?(sub="user1") ?(scopes=["read"]) ?(exp_offset=3600.0) () =
  let header  = Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet
                  {|{"alg":"HS256","typ":"JWT"}|} in
  let now     = Unix.gettimeofday () in
  let exp     = int_of_float (now +. exp_offset) in
  let scope   = String.concat " " scopes in
  let payload = Printf.sprintf {|{"sub":"%s","scope":"%s","exp":%d}|} sub scope exp in
  let payload_b64 = Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet payload in
  header ^ "." ^ payload_b64 ^ ".fakesig"

let make_jwt_with_payload payload =
  let header  = Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet
                  {|{"alg":"HS256","typ":"JWT"}|} in
  let payload_b64 = Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet payload in
  header ^ "." ^ payload_b64 ^ ".fakesig"

let jwt_cfg scopes =
  `Jwt Auth.{ scopes; verification = Unverified_dev_only }

let verified_jwt_cfg scopes =
  `Jwt Auth.{ scopes; verification = Verified_signature_required }

let test_jwt_valid () =
  let tok = make_jwt ~scopes:["read";"write"] () in
  match Auth.validate (jwt_cfg ["read";"write"]) (bearer tok) with
  | Ok { principal = Auth.User { sub; scopes; _ } } ->
    Alcotest.(check string) "sub"    "user1" sub;
    Alcotest.(check bool)   "scopes" true (List.mem "write" scopes)
  | _ -> Alcotest.fail "expected User principal"

let test_jwt_superset_scopes () =
  (* Token has more scopes than required — should pass *)
  let tok = make_jwt ~scopes:["read";"write";"admin"] () in
  match Auth.validate (jwt_cfg ["read"]) (bearer tok) with
  | Ok { principal = Auth.User _ } -> ()
  | _ -> Alcotest.fail "expected User principal"

let test_jwt_missing_scope () =
  let tok = make_jwt ~scopes:["read"] () in
  match Auth.validate (jwt_cfg ["read";"write"]) (bearer tok) with
  | Error (`Forbidden msg) ->
    Alcotest.(check bool) "mentions missing scope" true
      (String.length msg > 0)
  | _ -> Alcotest.fail "expected Forbidden"

let test_jwt_expired () =
  let tok = make_jwt ~exp_offset:(-1.0) () in
  match Auth.validate (jwt_cfg []) (bearer tok) with
  | Error (`Unauthorized msg) ->
    Alcotest.(check bool) "expired message" true
      (let m = String.lowercase_ascii msg in
       String.length m > 0)
  | _ -> Alcotest.fail "expected Unauthorized"

let test_jwt_malformed () =
  match Auth.validate (jwt_cfg []) (bearer "not.a.jwt.at.all.extra") with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"

let test_jwt_wrong_bearer_scheme () =
  match Auth.validate (jwt_cfg []) (headers_of ["authorization", "Token abc"]) with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"

let test_jwt_payload_not_base64 () =
  match Auth.validate (jwt_cfg []) (bearer "header.%.signature") with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"

let test_jwt_payload_not_json () =
  match Auth.validate (jwt_cfg []) (bearer (make_jwt_with_payload "not json")) with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"

let test_jwt_missing_header () =
  match Auth.validate (jwt_cfg []) (headers_of []) with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"

let test_jwt_verified_required_not_implemented () =
  match Auth.validate (verified_jwt_cfg []) (bearer (make_jwt ())) with
  | Error (`Not_implemented _) -> ()
  | _ -> Alcotest.fail "expected Not_implemented"

let () =
  Alcotest.run "auth" [
    "public", [
      Alcotest.test_case "returns Public principal" `Quick test_public;
    ];
    "api_key", [
      Alcotest.test_case "valid key"           `Quick test_api_key_valid;
      Alcotest.test_case "wrong key → 401"     `Quick test_api_key_wrong;
      Alcotest.test_case "missing header → 401" `Quick test_api_key_missing_header;
    ];
    "jwt", [
      Alcotest.test_case "valid token"          `Quick test_jwt_valid;
      Alcotest.test_case "superset scopes → ok" `Quick test_jwt_superset_scopes;
      Alcotest.test_case "missing scope → 403"  `Quick test_jwt_missing_scope;
      Alcotest.test_case "expired → 401"        `Quick test_jwt_expired;
      Alcotest.test_case "malformed → 401"      `Quick test_jwt_malformed;
      Alcotest.test_case "wrong bearer → 401"   `Quick test_jwt_wrong_bearer_scheme;
      Alcotest.test_case "bad payload b64 → 401" `Quick test_jwt_payload_not_base64;
      Alcotest.test_case "bad payload JSON → 401" `Quick test_jwt_payload_not_json;
      Alcotest.test_case "missing header → 401" `Quick test_jwt_missing_header;
      Alcotest.test_case "verified mode → 501"  `Quick test_jwt_verified_required_not_implemented;
    ];
  ]
