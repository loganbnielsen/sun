type config = {
  bucket : string;
  region : string;
  credentials : Aws_credentials.t;
  endpoint : string option;
}

type head_info = {
  content_length : int option;
  etag : string option;
  last_modified : string option;
  content_type : string option;
}

(* Bracket-aware: "[::1]:9000" (an IPv6-literal endpoint) is not just "split
   on the last colon" — that would cut into the address itself, since IPv6
   literals contain colons. RFC 3986's "[host]:port" bracket convention
   disambiguates exactly this case. *)
let split_host_port endpoint =
  if String.length endpoint > 0 && endpoint.[0] = '[' then
    match String.index_opt endpoint ']' with
    | None -> (endpoint, None)
    | Some close ->
      let host = String.sub endpoint 1 (close - 1) in
      let rest = String.sub endpoint (close + 1) (String.length endpoint - close - 1) in
      let port =
        if String.length rest > 1 && rest.[0] = ':' then int_of_string_opt (String.sub rest 1 (String.length rest - 1))
        else None
      in
      (host, port)
  else
    match String.rindex_opt endpoint ':' with
    | Some i -> (String.sub endpoint 0 i, int_of_string_opt (String.sub endpoint (i + 1) (String.length endpoint - i - 1)))
    | None -> (endpoint, None)

let has_crlf s = String.exists (fun c -> c = '\r' || c = '\n') s

(* config.bucket/region become an unencoded Host header and TCP connection
   target (Aws_http.write_request does not sanitize header values) —
   unlike key, which always goes through Aws_sigv4.canonical_uri's
   percent-encoding before it becomes wire bytes, nothing encodes these, so
   a caller building config from less-trusted input (e.g. a per-tenant
   bucket name) could otherwise inject extra header lines. Fail closed
   rather than silently building a malformed/exploitable request. *)
let validate_config config =
  if has_crlf config.bucket then Error (S3_error.Invalid_config "bucket contains a CR or LF character")
  else if has_crlf config.region then Error (S3_error.Invalid_config "region contains a CR or LF character")
  else
    match config.endpoint with
    | Some endpoint when has_crlf endpoint -> Error (S3_error.Invalid_config "endpoint contains a CR or LF character")
    | _ -> Ok ()

let host_port_and_path config ~key =
  match config.endpoint with
  | None -> (Printf.sprintf "%s.s3.%s.amazonaws.com" config.bucket config.region, None, "/" ^ key)
  | Some endpoint ->
    let host, port = split_host_port endpoint in
    (host, port, "/" ^ config.bucket ^ "/" ^ key)

let host_and_path config ~key =
  let host, _port, path = host_port_and_path config ~key in
  (host, path)

let ( let* ) = Result.bind

let resolve_credentials ~net ~clock config =
  match Aws_credentials.resolve ~net ~clock config.credentials with
  | Error e -> Error (S3_error.Aws e)
  | Ok creds -> Ok creds

(* Every operation resolves credentials fresh — Aws_credentials.resolve
   documents that it does not cache or refresh on the caller's behalf.
   Correct but not free for Web_identity/Container/Imdsv2 (an extra network
   round trip per S3 call); caching until resolved.expiration approaches is
   real, deferred work — see s3-eio.md's "Out of Scope". *)
(* aws-eio's signed_request already converts every non-2xx status into
   Error (Http_error (status, body)) before returning — found by an
   adversarial review round: interpret_put/get/delete/head's own non-2xx
   branches (the whole point of S3_error's typed classification) were
   unreachable dead code through the real call path, only ever exercised by
   this package's own unit tests calling interpret_* directly with a
   synthetic non-2xx status. Fixed by re-threading Http_error's already-
   carried (status, body) back into the same Ok shape interpret_*
   expects — the interpreters themselves needed no change, since their
   non-2xx handling was always correct, just unreachable. Headers are lost
   on this path ([]), matching Aws_http.signed_request's own documented
   choice to only return headers on success. Factored out as its own pure
   function (rather than left inline in call) specifically so this fix is
   unit-testable without a real network call — this package's tests can't
   spin up a local mock server at all (see the test-strategy note above),
   so this is the only way to actually exercise the fix pre-live-test. *)
let reclassify_transport_result :
    (int * (string * string) list * string, Aws_error.t) result -> (int * (string * string) list * string, S3_error.t) result
    = function
  | Error (Aws_error.Http_error (status, body)) -> Ok (status, [], body)
  | Error e -> Error (S3_error.Aws e)
  | Ok (status, headers, body) -> Ok (status, headers, body)

let call ~net ~clock config ~meth ~key ?query ?body () =
  let* () = validate_config config in
  let* creds = resolve_credentials ~net ~clock config in
  let host, port, path = host_port_and_path config ~key in
  reclassify_transport_result
    (Aws_http.signed_request ~net ~clock
       ~access_key_id:creds.access_key_id
       ~secret_access_key:creds.secret_access_key
       ?session_token:creds.session_token
       ~region:config.region ~service:"s3" ~normalize_path:false
       ~meth ~host ?port ~path ?query ?body ())

let header_ci name headers =
  List.find_map (fun (k, v) -> if String.lowercase_ascii k = name then Some v else None) headers

(* Response interpretation is pure and deliberately separated from call
   above: aws-eio's signed_request always negotiates real TLS (there is no
   plain-HTTP mode to point at a lightweight local mock server, and
   TLS/SNI construction rejects bare IP literals like 127.0.0.1 as
   syntactically invalid hostnames) — see s3-eio.md's test strategy note.
   Keeping "what result does this (status, headers, body) map to" as pure
   functions means that mapping is fully unit-testable without a network
   call at all; the wire/TLS path itself is exercised by aws-eio's own test
   suite and by this package's live test (S3_EIO_LIVE=1). *)
let interpret_put (status, _headers, resp_body) =
  if status >= 200 && status < 300 then Ok () else Error (S3_error.of_response ~status ~body:resp_body)

let interpret_get (status, _headers, body) =
  if status >= 200 && status < 300 then Ok body else Error (S3_error.of_response ~status ~body)

(* S3's DeleteObject returns 204 on success, including when the key never
   existed — deleting a nonexistent key is not an error. *)
let interpret_delete (status, _headers, body) =
  if status >= 200 && status < 300 then Ok () else Error (S3_error.of_response ~status ~body)

(* HEAD responses never carry a body per HTTP semantics (aws_http.ml
   enforces this at the transport layer), so there is nothing for
   S3_error.of_response to parse into a Service_error on a HEAD error — a
   HEAD 404 is always Not_found, anything else lands in
   Unparseable_error_response with an empty body, which is expected and
   correct, not a parsing bug. *)
let interpret_head (status, headers, body) =
  if status >= 200 && status < 300 then
    Ok
      { content_length = header_ci "content-length" headers |> Option.map int_of_string_opt |> Option.join;
        etag = header_ci "etag" headers;
        last_modified = header_ci "last-modified" headers;
        content_type = header_ci "content-type" headers;
      }
  else Error (S3_error.of_response ~status ~body)

let put_object ~net ~clock config ~key ~body =
  match call ~net ~clock config ~meth:`PUT ~key ~body () with
  | Error _ as e -> e
  | Ok r -> interpret_put r

let get_object ~net ~clock config ~key =
  match call ~net ~clock config ~meth:`GET ~key () with
  | Error _ as e -> e
  | Ok r -> interpret_get r

let delete_object ~net ~clock config ~key =
  match call ~net ~clock config ~meth:`DELETE ~key () with
  | Error _ as e -> e
  | Ok r -> interpret_delete r

let head_object ~net ~clock config ~key =
  match call ~net ~clock config ~meth:`HEAD ~key () with
  | Error _ as e -> e
  | Ok r -> interpret_head r
