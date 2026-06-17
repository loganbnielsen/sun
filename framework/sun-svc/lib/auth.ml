type jwt_config =
  { scopes                     : string list
  ; allow_unverified_v1_unsafe : bool
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

let validate_jwt config headers =
  if not config.allow_unverified_v1_unsafe then
    Error (`Not_implemented
      "JWT signature verification not implemented; \
       set allow_unverified_v1_unsafe=true to opt in to v1 behaviour")
  else
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
         | [_hdr; payload_b64; _sig] ->
           (match base64url_decode payload_b64 with
            | None -> Error (`Unauthorized "Malformed JWT: cannot decode payload")
            | Some payload_str ->
              (match Yojson.Safe.from_string payload_str with
               | exception _ -> Error (`Unauthorized "Malformed JWT: payload is not valid JSON")
               | json ->
                 let now = Unix.gettimeofday () in
                 let expired = match Yojson.Safe.Util.member "exp" json with
                   | `Int   n -> float_of_int n < now
                   | `Float f -> f < now
                   | _        -> false
                 in
                 if expired then
                   Error (`Unauthorized "JWT expired")
                 else
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
                      Error (`Forbidden ("Missing required scope: " ^ s)))))
         | _ -> Error (`Unauthorized "Malformed JWT: expected header.payload.signature"))

let validate level headers =
  match level with
  | `Public    -> Ok { principal = Public }
  | `Api_key   -> validate_api_key headers
  | `Jwt cfg   -> validate_jwt cfg headers
