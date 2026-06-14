(** Re-exported for backward compatibility with [test_scaffold.ml]. *)

val is_sun_home    : string -> bool
val find_ancestor  : (string -> bool) -> string -> string option
val infer_sun_home : unit -> string option
val new_workspace  : string -> unit
val new_worker     : string -> unit
val cmd            : unit Cmdliner.Cmd.t
