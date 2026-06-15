(** Minimal YAML scalar emitter shared across all manifest generators.

    [emit_scalar s] returns [s] unchanged when it is safe to emit bare in
    YAML, or wraps it in double-quotes (escaping special characters) when the
    value contains [':'], ['#'], ['"'], ["'"], newlines, backslashes, or when
    the value would be misinterpreted as a YAML boolean ([true]/[false]/[yes]/
    [no]/[on]/[off]/[null]) or as a numeric literal. *)
val emit_scalar : string -> string
