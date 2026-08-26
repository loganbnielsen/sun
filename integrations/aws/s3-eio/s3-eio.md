# s3-eio

Layer 2 of the AWS integration plan in `aws-audit.md`. An S3 client built on `aws-eio`'s
credentials and SigV4/HTTP transport — not an AWS SDK, just the four REST-with-headers
S3 operations that need no XML.

## Overview

`aws-eio` deliberately has no per-service API bindings. `s3-eio` is the first backend
built on it, proving the transport layer end-to-end against a real bucket. Every public
operation returns `(_, S3_error.t) result`; nothing raises.

## Package Structure

```
s3-eio/
  lib/
    s3_error.ml/.mli    -- error type extending Aws_error.t
    s3_client.ml/.mli   -- config + put/get/delete/head_object
    dune
  test/
    test_s3_error.ml         -- XML error-body parsing
    test_s3_client.ml        -- host/path construction + response interpretation (pure)
    test_s3_live.ml          -- gated by S3_EIO_LIVE=1, real bucket required
    dune
  s3-eio.md
```

**Test strategy note:** `aws-eio`'s `signed_request` always negotiates real TLS — there is
no plain-HTTP mode to point at a lightweight local mock server, and TLS/SNI construction
rejects bare IP literals like `127.0.0.1` as syntactically invalid hostnames (confirmed
by hand: a first attempt at a loopback mock server for `test_s3_client.ml` failed with
`Invalid_argument "invalid host name"` from the `domain-name` library). Building a real
self-signed-TLS mock server (matching `aws-eio`'s own `test_aws_tls.ml`) would work but is
heavy infrastructure for what's actually thin glue code. Instead, `S3_client`'s
`(status, headers, body) -> result` mapping per operation is factored out as pure
`interpret_put`/`interpret_get`/`interpret_delete`/`interpret_head` functions, unit-tested
directly with synthetic responses — no network or TLS involved. The wire/TLS path itself
is already proven by `aws-eio`'s own test suite (conformance-suite-validated signing, a
real local TLS handshake test, and now a live AWS call) and by this package's own live
test.

## v1 Scope

`put_object`, `get_object`, `delete_object`, `head_object` — all four sign with a
literal SHA256 payload hash (or none, for GET/DELETE/HEAD, which have no body) and need
no XML for their *request* shape. **Not in v1:** `list_objects_v2` (XML response body),
multipart upload (session state across several signed requests), and true streaming
(`Eio.Flow.source`/`sink` instead of whole-buffer `string`) — see "Out of Scope" below.

## Host addressing

Two modes, chosen by whether `config.endpoint` is set:

- **Real AWS (`endpoint = None`, the default):** virtual-hosted-style —
  `host = "<bucket>.s3.<region>.amazonaws.com"`, `path = "/<key>"`. This is AWS's
  current recommended addressing (path-style is deprecated for new buckets).
- **Test/S3-compatible server (`endpoint = Some "host:port"`, IPv6 as `"[host]:port"`):**
  path-style — `host = "<host:port>"`, `path = "/<bucket>/<key>"`. Virtual-hosted-style
  requires a real subdomain to resolve (`bucket.s3.amazonaws.com`), which a loopback test
  server can't provide.

  **Caveat, found the hard way while building this package's own tests:**
  `aws-eio`'s `signed_request` always negotiates real TLS and builds the TLS/SNI
  hostname via the `domain-name` library, which rejects bare IP literals (`127.0.0.1`,
  `::1`) as syntactically invalid hostnames — `Invalid_argument "invalid host name"`,
  not an HTTP-level error. So `endpoint` must be a real, DNS-resolvable hostname (e.g.
  `"localhost:9000"`, assuming `/etc/hosts` or DNS resolves it), **not** a bare IP, and
  the target server must actually terminate TLS — a plain-HTTP local S3-compatible
  server (e.g. a MinIO instance without TLS configured) will not work through this
  path at all. **This path is not exercised by any test in this package** — the unit
  tests below cover `host_and_path`'s string construction in isolation, not a real call
  through it; treat it as unverified until someone actually points it at a
  TLS-terminating test server.

`key` is passed to `Aws_sigv4`/`Aws_http` as a raw, unencoded string — percent-encoding
happens once, internally, in `Aws_sigv4.canonical_uri` (the same single-encoder path
`aws-eio`'s own `signed_request` already uses for every service). Nothing in this
package encodes the key itself; doing so would risk the same signed-vs-sent encoding
mismatch `aws-eio`'s own `wire_resource` was built to prevent.

## Public API

```ocaml
type config = {
  bucket : string;
  region : string;
  credentials : Aws_credentials.t;
  endpoint : string option;  (** [None] = real AWS virtual-hosted-style; [Some host_port]
                                 = path-style against that host, for test/S3-compatible
                                 servers. *)
}

type head_info = {
  content_length : int option;
  etag : string option;
  last_modified : string option;
  content_type : string option;
}

val put_object :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:string -> body:string ->
  (unit, S3_error.t) result

val get_object :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:string ->
  (string, S3_error.t) result

val delete_object :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:string ->
  (unit, S3_error.t) result

val head_object :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:string ->
  (head_info, S3_error.t) result
```

`S3_error.t`:

```ocaml
type t =
  | Aws of Aws_error.t                                          (** transport/signature/credential failure *)
  | Not_found                                                    (** 404 — NoSuchKey/NoSuchBucket *)
  | Service_error of { code : string; message : string; status : int }
      (** other non-2xx with a parseable <Error><Code>/<Message> body *)
  | Unparseable_error_response of { status : int; body : string }
      (** non-2xx whose body didn't parse as an S3 error document (or, for
          HEAD, has no body to parse at all — HEAD responses never carry a
          body per HTTP semantics, so a HEAD 404 always lands here, not in
          [Service_error]) *)
  | Invalid_config of string
      (** [bucket]/[region]/[endpoint] failed a fail-closed CR/LF check
          before being used to build the Host header/connection target —
          see "Host addressing" above. *)

val to_string : t -> string
```

## Credential resolution

Each call resolves fresh credentials via `Aws_credentials.resolve` — no caching, matching
`Aws_credentials`'s own documented contract ("this function does not cache or refresh on
your behalf"). For `Static` credentials this is free; for `Web_identity`/`Container`/
`Imdsv2` it means a network round-trip on every S3 call. Caching until
`resolved.expiration` approaches is real, deferred work — see "Out of Scope."

## Example Usage

```ocaml
let config =
  { S3_client.bucket = "my-bucket"; region = "us-east-1";
    credentials = Aws_credentials.of_env ~region:"us-east-1" ();
    endpoint = None }
in
match S3_client.put_object ~net ~clock config ~key:"path/to/object" ~body:"hello" with
| Ok () -> ()
| Error e -> Printf.eprintf "%s\n" (S3_error.to_string e)
```

## Out of Scope (v1)

- `list_objects_v2` — XML response body, needs `xmlm`/`ezxmlm`, not currently a
  dependency anywhere in this switch. Real, separate scope, not silently expanded into
  v1.
- Multipart upload — session state across several signed requests.
- **True streaming.** `aws-eio`'s `signed_request` takes a whole `?body:string` and
  returns a whole `string`; there is no `Eio.Flow.source`/`sink` variant. Building one
  means extending `aws-eio`'s HTTP transport itself (chunked/streaming request bodies,
  a streaming response reader), not something `s3-eio` can add on its own without
  duplicating `aws_http.ml`'s wire/retry/TLS logic. v1 buffers whole objects in memory —
  fine for small-to-medium objects, a real limitation for large ones. Flagged here so it
  isn't quietly forgotten, not built now.
- Credential caching across calls (see above).
- `UNSIGNED-PAYLOAD` streaming-upload mode (`aws_http.mli` already supports overriding
  the payload hash for this, but it's moot without streaming request bodies to pair it
  with).
