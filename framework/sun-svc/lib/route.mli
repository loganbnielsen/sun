type handler = Request.t -> Response.t

type t =
  { method_  : Request.method_
  ; pattern  : string
  ; auth     : Auth.level
  ; handler  : handler
  }

(** Internal — called by [Service.Make]. Not intended for direct use. *)
val match_path         : string -> string -> (string * string) list option
val method_of_http     : Http.Method.t -> Request.method_ option

(** Validate and split a request path.
    Returns [None] for malformed paths (consecutive slashes).
    Returns [Some (segments, has_trailing_slash)] for valid paths. *)
val parse_request_path : string -> (string list * bool) option

(** Percent-decode a path segment value.  Applied to route parameters;
    literal pattern segments are matched without decoding.
    ['+'] is NOT decoded as a space (this is path decoding, not form-data). *)
val percent_decode     : string -> string

val get    : string -> auth:Auth.level -> handler -> t
val post   : string -> auth:Auth.level -> handler -> t
val put    : string -> auth:Auth.level -> handler -> t
val patch  : string -> auth:Auth.level -> handler -> t
val delete : string -> auth:Auth.level -> handler -> t
