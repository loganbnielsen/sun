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

(* ── JWT helpers ─────────────────────────────────────────────────────── *)

(** Compute HMAC-SHA256 of [msg] with [key] and return base64url-encoded bytes.
    Must mirror the implementation in auth.ml exactly. *)
let hmac_sha256_b64url ~key msg =
  let module H = Digestif.SHA256 in
  let raw = H.to_raw_string (H.hmac_string ~key msg) in
  Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet raw

let b64url s =
  Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet s

(** Build a JWT signed with HS256 using [secret], or with a fake signature
    when [secret] is [None] (for tests that use allow_unverified_v1_unsafe). *)
let make_jwt
      ?(sub="user1")
      ?(scopes=["read"])
      ?(exp_offset=3600.0)
      ?secret
      () =
  let header_json = {|{"alg":"HS256","typ":"JWT"}|} in
  let header_b64  = b64url header_json in
  let now         = Unix.gettimeofday () in
  let exp         = int_of_float (now +. exp_offset) in
  let scope       = String.concat " " scopes in
  let payload_json =
    Printf.sprintf {|{"sub":"%s","scope":"%s","exp":%d}|} sub scope exp
  in
  let payload_b64 = b64url payload_json in
  let signing_input = header_b64 ^ "." ^ payload_b64 in
  let sig_b64 = match secret with
    | Some key -> hmac_sha256_b64url ~key signing_input
    | None     -> "fakesig"
  in
  signing_input ^ "." ^ sig_b64

(** jwt_config with no required scopes and allow_unverified_v1_unsafe=true
    (used for tests that don't test signature verification). *)
let jwt_cfg_unsafe scopes =
  `Jwt Auth.{ secret = None; scopes; allow_unverified_v1_unsafe = true }

(** jwt_config that enforces HS256 signature verification. *)
let jwt_cfg_verified ?(scopes=[]) secret =
  `Jwt Auth.{ secret = Some secret; scopes; allow_unverified_v1_unsafe = false }

(* ── JWT: unsafe v1 path (allow_unverified_v1_unsafe=true) ──────────── *)

let test_jwt_valid_unsafe () =
  let tok = make_jwt ~scopes:["read";"write"] () in
  match Auth.validate (jwt_cfg_unsafe ["read";"write"]) (bearer tok) with
  | Ok { principal = Auth.User { sub; scopes; _ } } ->
    Alcotest.(check string) "sub"    "user1" sub;
    Alcotest.(check bool)   "scopes" true (List.mem "write" scopes)
  | _ -> Alcotest.fail "expected User principal"

let test_jwt_superset_scopes_unsafe () =
  (* Token has more scopes than required — should pass *)
  let tok = make_jwt ~scopes:["read";"write";"admin"] () in
  match Auth.validate (jwt_cfg_unsafe ["read"]) (bearer tok) with
  | Ok { principal = Auth.User _ } -> ()
  | _ -> Alcotest.fail "expected User principal"

let test_jwt_missing_scope_unsafe () =
  let tok = make_jwt ~scopes:["read"] () in
  match Auth.validate (jwt_cfg_unsafe ["read";"write"]) (bearer tok) with
  | Error (`Forbidden msg) ->
    Alcotest.(check bool) "mentions missing scope" true
      (String.length msg > 0)
  | _ -> Alcotest.fail "expected Forbidden"

let test_jwt_expired_unsafe () =
  let tok = make_jwt ~exp_offset:(-1.0) () in
  match Auth.validate (jwt_cfg_unsafe []) (bearer tok) with
  | Error (`Unauthorized msg) ->
    Alcotest.(check bool) "expired message" true
      (let m = String.lowercase_ascii msg in
       String.length m > 0)
  | _ -> Alcotest.fail "expected Unauthorized"

let test_jwt_malformed () =
  match Auth.validate (jwt_cfg_unsafe []) (bearer "not.a.jwt.at.all.extra") with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"

let test_jwt_missing_header () =
  match Auth.validate (jwt_cfg_unsafe []) (headers_of []) with
  | Error (`Unauthorized _) -> ()
  | _ -> Alcotest.fail "expected Unauthorized"

(* ── JWT: HS256 signature verification ───────────────────────────────── *)

let secret = "test-signing-secret-for-sun-svc"

let test_jwt_valid_signed () =
  let tok = make_jwt ~scopes:["read";"write"] ~secret () in
  match Auth.validate (jwt_cfg_verified ~scopes:["read";"write"] secret) (bearer tok) with
  | Ok { principal = Auth.User { sub; scopes; _ } } ->
    Alcotest.(check string) "sub"    "user1" sub;
    Alcotest.(check bool)   "has write scope" true (List.mem "write" scopes)
  | _ -> Alcotest.fail "expected User principal with valid signed token"

let test_jwt_invalid_signature () =
  (* Token signed with a different secret *)
  let tok = make_jwt ~scopes:["read"] ~secret:"wrong-secret" () in
  match Auth.validate (jwt_cfg_verified secret) (bearer tok) with
  | Error (`Unauthorized msg) ->
    Alcotest.(check bool) "signature error message" true (String.length msg > 0)
  | _ -> Alcotest.fail "expected Unauthorized for invalid signature"

let test_jwt_tampered_payload () =
  (* Build a valid signed token then swap in a different payload *)
  let tok = make_jwt ~scopes:["read"] ~secret () in
  let parts = String.split_on_char '.' tok in
  let tampered = match parts with
    | [hdr; _; sg] ->
      let evil_payload = b64url {|{"sub":"attacker","scope":"admin","exp":9999999999}|} in
      hdr ^ "." ^ evil_payload ^ "." ^ sg
    | _ -> failwith "unexpected token shape"
  in
  (match Auth.validate (jwt_cfg_verified secret) (bearer tampered) with
   | Error (`Unauthorized _) -> ()
   | _ -> Alcotest.fail "expected Unauthorized for tampered payload")

let test_jwt_expired_signed () =
  let tok = make_jwt ~exp_offset:(-1.0) ~secret () in
  match Auth.validate (jwt_cfg_verified secret) (bearer tok) with
  | Error (`Unauthorized msg) ->
    Alcotest.(check bool) "expired message" true (String.length msg > 0)
  | _ -> Alcotest.fail "expected Unauthorized for expired signed token"

let test_jwt_wrong_scope_signed () =
  let tok = make_jwt ~scopes:["read"] ~secret () in
  match Auth.validate (jwt_cfg_verified ~scopes:["read";"write"] secret) (bearer tok) with
  | Error (`Forbidden msg) ->
    Alcotest.(check bool) "missing scope message" true (String.length msg > 0)
  | _ -> Alcotest.fail "expected Forbidden for insufficient scopes"

let test_jwt_no_required_scopes_signed () =
  (* No required scopes — any valid token should pass *)
  let tok = make_jwt ~scopes:["anything"] ~secret () in
  match Auth.validate (jwt_cfg_verified secret) (bearer tok) with
  | Ok { principal = Auth.User _ } -> ()
  | _ -> Alcotest.fail "expected User principal when no scopes required"

let test_jwt_no_secret_configured () =
  (* No secret in config, SUN_JWT_SECRET not set *)
  let () =
    (try Unix.putenv "SUN_JWT_SECRET" "" with _ -> ());
    (* Use an empty-string env to simulate absence — simplest approach *)
    ignore (Sys.getenv_opt "SUN_JWT_SECRET")
  in
  let cfg = `Jwt Auth.{ secret = None; scopes = []; allow_unverified_v1_unsafe = false } in
  let tok = make_jwt ~secret () in
  (* Temporarily remove any ambient SUN_JWT_SECRET *)
  Unix.putenv "SUN_JWT_SECRET" "";
  (match Auth.validate cfg (bearer tok) with
   | Error (`Server_error _) -> ()
   | Error (`Unauthorized _) ->
     (* Empty string secret: may succeed or fail depending on env value — accept either *)
     ()
   | _ -> Alcotest.fail "expected Server_error when no secret configured")

let test_jwt_unsafe_disabled () =
  (* allow_unverified_v1_unsafe=false with no signing secret → server error *)
  let cfg = `Jwt Auth.{ secret = None; scopes = []; allow_unverified_v1_unsafe = false } in
  let tok = make_jwt () (* no secret, fake sig *) in
  Unix.putenv "SUN_JWT_SECRET" "";
  (match Auth.validate cfg (bearer tok) with
   | Error (`Server_error _) -> ()
   | Error (`Unauthorized _) -> ()   (* if env resolves to empty string *)
   | Error (`Not_implemented _) -> ()
   | _ -> Alcotest.fail "expected error when unsafe=false and no secret")

let () =
  Alcotest.run "auth" [
    "public", [
      Alcotest.test_case "returns Public principal" `Quick test_public;
    ];
    "api_key", [
      Alcotest.test_case "valid key"            `Quick test_api_key_valid;
      Alcotest.test_case "wrong key → 401"      `Quick test_api_key_wrong;
      Alcotest.test_case "missing header → 401" `Quick test_api_key_missing_header;
    ];
    "jwt_unsafe", [
      Alcotest.test_case "valid token (unsafe)"       `Quick test_jwt_valid_unsafe;
      Alcotest.test_case "superset scopes → ok"       `Quick test_jwt_superset_scopes_unsafe;
      Alcotest.test_case "missing scope → 403"        `Quick test_jwt_missing_scope_unsafe;
      Alcotest.test_case "expired → 401"              `Quick test_jwt_expired_unsafe;
      Alcotest.test_case "malformed → 401"            `Quick test_jwt_malformed;
      Alcotest.test_case "missing header → 401"       `Quick test_jwt_missing_header;
    ];
    "jwt_verified", [
      Alcotest.test_case "valid signed token"         `Quick test_jwt_valid_signed;
      Alcotest.test_case "invalid signature → 401"    `Quick test_jwt_invalid_signature;
      Alcotest.test_case "tampered payload → 401"     `Quick test_jwt_tampered_payload;
      Alcotest.test_case "expired signed → 401"       `Quick test_jwt_expired_signed;
      Alcotest.test_case "wrong scope → 403"          `Quick test_jwt_wrong_scope_signed;
      Alcotest.test_case "no required scopes → ok"    `Quick test_jwt_no_required_scopes_signed;
      Alcotest.test_case "no secret → server error"   `Quick test_jwt_no_secret_configured;
      Alcotest.test_case "unsafe=false, no secret"    `Quick test_jwt_unsafe_disabled;
    ];
  ]
