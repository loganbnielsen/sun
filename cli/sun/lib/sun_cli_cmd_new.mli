(** Returns [true] if [dir] looks like a Sun home (source checkout or release bundle).
    Checks for the two sentinel files that must exist in any valid Sun root:
      - [framework/sun-svc/lib/dune]
      - [integrations/kafka/kafka-eio-service/lib/dune] *)
val is_sun_home : string -> bool

(** [find_ancestor pred dir] walks up the directory tree from [dir], returning
    [Some d] for the first ancestor directory (including [dir] itself) where
    [pred d] is true, or [None] if the filesystem root is reached without a match. *)
val find_ancestor : (string -> bool) -> string -> string option

(** Infers the Sun home directory.
    1. Checks [$SUN_HOME] if set — returns [Some dir] if it passes [is_sun_home].
    2. Otherwise walks up from the directory containing the running binary. *)
val infer_sun_home : unit -> string option

val parse_domain_name : string -> ((string * string), string) result

val new_workspace : string -> unit
val new_svc       : string -> unit
val new_worker    : string -> unit
val new_fn        : string -> unit
val new_event     : string -> unit
val cmd           : unit Cmdliner.Cmd.t
