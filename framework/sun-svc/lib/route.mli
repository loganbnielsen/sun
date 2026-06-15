type handler = Request.t -> Response.t

type t =
  { method_  : Request.method_
  ; pattern  : string
  ; auth     : Auth.level
  ; handler  : handler
  }

(** Internal — called by [Service.Make]. Not intended for direct use. *)
val match_path     : string -> string -> (string * string) list option
val method_of_http : Http.Method.t -> Request.method_ option

val get    : string -> auth:Auth.level -> handler -> t
val post   : string -> auth:Auth.level -> handler -> t
val put    : string -> auth:Auth.level -> handler -> t
val patch  : string -> auth:Auth.level -> handler -> t
val delete : string -> auth:Auth.level -> handler -> t
