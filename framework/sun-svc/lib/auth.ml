(** JWT configuration.

    [secret] is the HMAC-SHA256 signing secret used for HS256 verification.
    When [None] the library falls back to the [SUN_JWT_SECRET] environment
    variable.  If neither is present, signature verification fails with a
    server-error.

    [allow_unverified_v1_unsafe] is a **deprecated** escape-hatch that skips
    signature verification entirely.  It exists only for gradual migration and
    will be removed in a future release.  Setting it to [true] emits a warning
    at validation time. *)
type jwt_config =
  { secret                    : string option
        (** Optional in-process signing secret (HS256). *)
  ; scopes                    : string list
        (** Required scopes that must appear in the token's [scope] claim. *)
  ; allow_unverified_v1_unsafe : bool
        (** Deprecated: skip signature verification. DO NOT USE in production. *)
  }

type level =
  [ `Public
  | `Api_key
  | `Jwt of jwt_config
  ]

type principal =
  | Public
  | Service of { key_id : string }
  | User of
      { sub    : string
      ; scopes : string list
      ; claims : Yojson.Safe.t
      }

type context = { principal : principal }

(* ── Internal validation ───────────────────────────────────────────────── *)

type error =
  [ `Unauthorized    of string
  | `Forbidden       of string
  | `Server_error    of string
  | `Not_implemented of string
  ]

let key_cache : (float * string) option Atomic.t = Atomic.make None
let key_cache_mutex = Mutex.create ()

let read_api_key () =
  match Sys.getenv_opt "SUN_API_KEY_FILE" with
  | Some path ->
    let mtime =
      try Some (Unix.stat path).Unix.st_mtime
      with _ -> None
    in
    (match mtime with
     | None -> None
     | Some mtime ->
       match Atomic.get key_cache with
       | Some (cached_mtime, key) when cached_mtime = mtime -> Some key
       | _ ->
         Mutex.protect key_cache_mutex (fun () ->
           match Atomic.get key_cache with
           | Some (cached_mtime, key) when cached_mtime = mtime -> Some key
           | _ ->
             (try
                In_channel.with_open_text path (fun ic ->
                  let key = String.trim (input_line ic) in
                  Atomic.set key_cache (Some (mtime, key));
                  Some key)
              with _ -> None)))
  | None -> Sys.getenv_opt "SUN_API_KEY"

let constant_time_equal s1 s2 =
  let len1 = String.length s1 and len2 = String.length s2 in
  if len1 <> len2 then false
  else
    let res = ref 0 in
    for i = 0 to len1 - 1 do
      res := !res lor (Char.code s1.[i] lxor Char.code s2.[i])
    done;
    !res = 0

let validate_api_key headers =
  match Http.Header.get headers "x-api-key" with
  | None -> Error (`Unauthorized "Missing X-Api-Key header")
  | Some provided ->
    match read_api_key () with
    | None ->
      Error (`Server_error "API key not configured (set SUN_API_KEY or SUN_API_KEY_FILE)")
    | Some expected ->
      if constant_time_equal provided expected then
        let key_id = String.sub provided 0 (min 8 (String.length provided)) in
        Ok { principal = Service { key_id } }
      else
        Error (`Unauthorized "Invalid API key")

(* ── Base64url helpers ─────────────────────────────────────────────────── *)

let base64url_decode s =
  let s = String.map (function '-' -> '+' | '_' -> '/' | c -> c) s in
  let pad = match String.length s mod 4 with
    | 2 -> s ^ "=="
    | 3 -> s ^ "="
    | _ -> s
  in
  match Base64.decode pad with
  | Ok s    -> Some s
  | Error _ -> None

let base64url_encode s =
  Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet s

(* ── HS256 signature verification ──────────────────────────────────────── *)

(** Compute HMAC-SHA256 of [msg] with [key] and return the raw digest bytes. *)
let hmac_sha256 ~key msg =
  let module H = Digestif.SHA256 in
  let hmac = H.hmac_string ~key msg in
  H.to_raw_string hmac

(** Verify that [signing_input] (= "<b64hdr>.<b64payload>") matches the
    base64url-encoded [signature] under [key]. Uses constant-time comparison
    to prevent timing attacks. *)
let verify_hs256 ~key ~signing_input ~signature =
  let expected_raw  = hmac_sha256 ~key signing_input in
  let expected_b64  = base64url_encode expected_raw in
  constant_time_equal expected_b64 signature

(* ── Scope helpers ─────────────────────────────────────────────────────── *)

let token_scopes json =
  match Yojson.Safe.Util.member "scope" json with
  | `String s -> String.split_on_char ' ' s |> List.filter (fun s -> s <> "")
  | `List lst ->
    List.filter_map (function `String s -> Some s | _ -> None) lst
  | _ -> []

(* ── JWT validation ────────────────────────────────────────────────────── *)

(** Resolve the signing secret: prefer the in-config value, fall back to
    the SUN_JWT_SECRET environment variable. *)
let resolve_secret config =
  match config.secret with
  | Some s -> Some s
  | None   -> Sys.getenv_opt "SUN_JWT_SECRET"

let validate_jwt config headers =
  match Http.Header.get headers "authorization" with
  | None -> Error (`Unauthorized "Missing Authorization header")
  | Some auth ->
    let prefix = "Bearer " in
    let plen   = String.length prefix in
    if String.length auth < plen || String.sub auth 0 plen <> prefix then
      Error (`Unauthorized "Authorization header must be 'Bearer <token>'")
    else
      let token = String.sub auth plen (String.length auth - plen) in
      (match String.split_on_char '.' token with
       | [hdr_b64; payload_b64; sig_b64] ->
         (* ── 1. Decode and parse header ───────────────────────────────── *)
         let alg_result =
           match base64url_decode hdr_b64 with
           | None -> Error (`Unauthorized "Malformed JWT: cannot decode header")
           | Some hdr_str ->
             (match Yojson.Safe.from_string hdr_str with
              | exception _ -> Error (`Unauthorized "Malformed JWT: header is not valid JSON")
              | hdr_json ->
                (match Yojson.Safe.Util.member "alg" hdr_json with
                 | `String alg -> Ok alg
                 | _           -> Error (`Unauthorized "Malformed JWT: missing alg")))
         in
         (match alg_result with
          | Error e -> Error e
          | Ok alg ->
            (* ── 2. Signature verification ────────────────────────────── *)
            let sig_check =
              if config.allow_unverified_v1_unsafe then begin
                (* Deprecated path: skip verification but log a warning. *)
                Printf.eprintf
                  "[sun-svc WARN] JWT validation: allow_unverified_v1_unsafe=true — \
                   signature verification is DISABLED. This is deprecated and will be \
                   removed. Set a jwt_secret and use allow_unverified_v1_unsafe=false.\n%!";
                Ok ()
              end else
                match alg with
                | "HS256" ->
                  (match resolve_secret config with
                   | None ->
                     Error (`Server_error
                       "JWT secret not configured (set SUN_JWT_SECRET or pass secret in jwt_config)")
                   | Some key ->
                     let signing_input = hdr_b64 ^ "." ^ payload_b64 in
                     if verify_hs256 ~key ~signing_input ~signature:sig_b64 then
                       Ok ()
                     else
                       Error (`Unauthorized "JWT signature verification failed"))
                | other ->
                  Error (`Not_implemented
                    ("JWT algorithm not supported: " ^ other ^
                     " — only HS256 is supported"))
            in
            (match sig_check with
             | Error e -> Error e
             | Ok () ->
               (* ── 3. Decode and parse payload ────────────────────────── *)
               (match base64url_decode payload_b64 with
                | None -> Error (`Unauthorized "Malformed JWT: cannot decode payload")
                | Some payload_str ->
                  (match Yojson.Safe.from_string payload_str with
                   | exception _ -> Error (`Unauthorized "Malformed JWT: payload is not valid JSON")
                   | json ->
                     (* ── 4. Expiry check ──────────────────────────────── *)
                     let now = Unix.gettimeofday () in
                     let expired = match Yojson.Safe.Util.member "exp" json with
                       | `Int   n -> float_of_int n < now
                       | `Float f -> f < now
                       | _        -> false
                     in
                     if expired then
                       Error (`Unauthorized "JWT expired")
                     else
                       (* ── 5. Scope check ─────────────────────────────── *)
                       let scopes = token_scopes json in
                       let missing =
                         List.filter (fun s -> not (List.mem s scopes)) config.scopes
                       in
                       (match missing with
                        | [] ->
                          let sub = match Yojson.Safe.Util.member "sub" json with
                            | `String s -> s
                            | _         -> ""
                          in
                          Ok { principal = User { sub; scopes; claims = json } }
                        | s :: _ ->
                          Error (`Forbidden ("Missing required scope: " ^ s)))))))
       | _ -> Error (`Unauthorized "Malformed JWT: expected header.payload.signature"))

let validate level headers =
  match level with
  | `Public    -> Ok { principal = Public }
  | `Api_key   -> validate_api_key headers
  | `Jwt cfg   -> validate_jwt cfg headers
