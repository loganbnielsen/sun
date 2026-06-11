type t =
  | Connection_failed of string
  | Query_error       of string
  | Not_found
  | Constraint_violation of string
  | Migration_error   of string

let to_string = function
  | Connection_failed msg    -> "connection failed: " ^ msg
  | Query_error msg          -> "query error: " ^ msg
  | Not_found                -> "not found"
  | Constraint_violation msg -> "constraint violation: " ^ msg
  | Migration_error msg      -> "migration error: " ^ msg
