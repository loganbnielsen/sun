type t =
  | Connection_failed of string
  | Query_error       of string
  | Not_found
  | Constraint_violation of string
  | Migration_error   of string

val to_string : t -> string
