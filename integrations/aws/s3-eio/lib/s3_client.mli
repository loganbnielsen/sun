(** S3 client on top of [aws-eio]. See [s3-eio.md] for scope, host-addressing
    rules, and what v1 deliberately leaves out (streaming, list/multipart,
    credential caching). *)

type config = {
  bucket : string;
  region : string;
  credentials : Aws_credentials.t;
  endpoint : string option;
      (** [None]: real AWS, virtual-hosted-style addressing
          ([bucket.s3.region.amazonaws.com]). [Some host_port]: path-style
          against that host ([host_port/bucket/key]) — for a local
          S3-compatible test server, which can't provide a real
          [bucket.<host>] subdomain to resolve. *)
}

type head_info = {
  content_length : int option;
  etag : string option;
  last_modified : string option;
  content_type : string option;
}

val put_object :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:string -> body:string -> (unit, S3_error.t) result

val get_object :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:string -> (string, S3_error.t) result

val delete_object :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:string -> (unit, S3_error.t) result

val head_object :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:string -> (head_info, S3_error.t) result

(** {2 Exposed for testing} *)

val host_and_path : config -> key:string -> string * string
(** The [(host, path)] pair every operation signs and sends, port stripped
    off (a [config.endpoint] of ["host:port"] passes [port] to
    {!Aws_http.signed_request} separately — [signed_request] takes host and
    port as distinct arguments, and a combined "host:port" string as [host]
    would fail to resolve as a literal hostname). See the host-addressing
    rules in [s3-eio.md]. *)

(** Pure (status, headers, body) -> result mappers, one per operation —
    unit-testable without a network call. See [s3_client.ml]'s top comment
    on why this package's operation tests exercise these directly instead of
    a local mock server: [signed_request] always negotiates real TLS, which
    a lightweight loopback mock can't satisfy (bare IP literals aren't valid
    TLS/SNI hostnames). *)

val validate_config : config -> (unit, S3_error.t) result
(** The CR/LF fail-closed check every operation runs before building a
    request — see the [Invalid_config] doc above. *)

val reclassify_transport_result :
  (int * (string * string) list * string, Aws_error.t) result -> (int * (string * string) list * string, S3_error.t) result
(** [Aws_http.signed_request] already converts every non-2xx status into
    [Error (Http_error (status, body))] — this re-threads that back into the
    [Ok] shape [interpret_*] expects, so their non-2xx classification
    branches are actually reachable. See [s3_client.ml]'s comment on why
    this had to be pulled out as its own testable function. *)

val interpret_put : int * (string * string) list * string -> (unit, S3_error.t) result
val interpret_get : int * (string * string) list * string -> (string, S3_error.t) result
val interpret_delete : int * (string * string) list * string -> (unit, S3_error.t) result
val interpret_head : int * (string * string) list * string -> (head_info, S3_error.t) result
