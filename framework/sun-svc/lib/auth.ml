type jwt_verification =
  | Verified_signature_required
  | Unverified_dev_only

type jwt_config =
  { scopes       : string list
  ; verification : jwt_verification
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

let load_from_path path mtime =
  try
    In_channel.with_open_text path (fun ic ->
      let key = String.trim (input_line ic) in
      Atomic.set key_cache (Some (mtime, key));
      Some key)
  with _ -> None

let read_api_key () =
  match Sys.getenv_opt "SUN_API_KEY_FILE" with
  | None -> Sys.getenv_opt "SUN_API_KEY"
  | Some path ->
    let mtime = try Some (Unix.stat path).Unix.st_mtime with _ -> None in
    Option.bind mtime (fun mtime ->
      match Atomic.get key_cache with
      | Some (cached_mtime, key) when cached_mtime = mtime -> Some key
      | _ ->
        Mutex.protect key_cache_mutex (fun () ->
          match Atomic.get key_cache with
          | Some (cached_mtime, key) when cached_mtime = mtime -> Some key
          | _ -> load_from_path path mtime))

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

let base64url_decode s =
  let s = String.map (function '-' -> '+' | '_' -> '/' | c -> c) s in
  let pad = match String.length s mod 4 with
    | 2 -> s ^ "=="
    | 3 -> s ^ "="
    | _ -> s
  in
  match Base64.decode pad with
  | Ok s   -> Some s
  | Error _ -> None

let token_scopes json =
  match Yojson.Safe.Util.member "scope" json with
  | `String s -> String.split_on_char ' ' s |> List.filter (fun s -> s <> "")
  | `List lst ->
    List.filter_map (function `String s -> Some s | _ -> None) lst
  | _ -> []

let ( let* ) = Result.bind

type jwt_parts =
  { header_b64    : string
  ; payload_b64   : string
  ; signature_b64 : string
  }

let bearer_token headers =
  let* auth =
    Http.Header.get headers "authorization"
    |> Option.to_result ~none:(`Unauthorized "Missing Authorization header")
  in
  let prefix = "Bearer " in
  let plen   = String.length prefix in
  if String.length auth < plen || String.sub auth 0 plen <> prefix then
    Error (`Unauthorized "Authorization header must be 'Bearer <token>'")
  else
    Ok (String.sub auth plen (String.length auth - plen))

let split_jwt token =
  match String.split_on_char '.' token with
  | [header_b64; payload_b64; signature_b64] ->
    Ok { header_b64; payload_b64; signature_b64 }
  | _ ->
    Error (`Unauthorized "Malformed JWT: expected header.payload.signature")

let decode_jwt_payload parts =
  base64url_decode parts.payload_b64
  |> Option.to_result ~none:(`Unauthorized "Malformed JWT: cannot decode payload")

let parse_jwt_payload payload_str =
  match Yojson.Safe.from_string payload_str with
  | exception _ ->
    Error (`Unauthorized "Malformed JWT: payload is not valid JSON")
  | json ->
    Ok json

let jwt_expired ~now json =
  match Yojson.Safe.Util.member "exp" json with
  | `Int   n -> float_of_int n < now
  | `Float f -> f < now
  | _        -> false

let check_jwt_expiry json =
  if jwt_expired ~now:(Unix.gettimeofday ()) json then
    Error (`Unauthorized "JWT expired")
  else
    Ok ()

let validate_required_scopes ~required ~actual =
  match List.filter (fun scope -> not (List.mem scope actual)) required with
  | [] -> Ok ()
  | scope :: _ -> Error (`Forbidden ("Missing required scope: " ^ scope))

let token_sub json =
  match Yojson.Safe.Util.member "sub" json with
  | `String s -> s
  | _         -> ""

let validate_unverified_jwt config headers =
  let* token       = bearer_token headers in
  let* parts       = split_jwt token in
  let* payload_str = decode_jwt_payload parts in
  let* json        = parse_jwt_payload payload_str in
  let* ()          = check_jwt_expiry json in
  let scopes       = token_scopes json in
  let* ()          = validate_required_scopes ~required:config.scopes ~actual:scopes in
  Ok { principal = User { sub = token_sub json; scopes; claims = json } }

let validate_jwt config headers =
  match config.verification with
  | Verified_signature_required ->
    Error (`Not_implemented
      "JWT signature verification not implemented; \
       use Unverified_dev_only only for local development")
  | Unverified_dev_only ->
    validate_unverified_jwt config headers

let validate level headers =
  match level with
  | `Public    -> Ok { principal = Public }
  | `Api_key   -> validate_api_key headers
  | `Jwt cfg   -> validate_jwt cfg headers
