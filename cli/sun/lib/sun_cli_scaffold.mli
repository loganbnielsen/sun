val subst : (string * string) list -> string -> string
(** [subst vars s] replaces every [{{key}}] in [s] with the corresponding
    value from [vars]. Applied left-to-right; earlier bindings win on overlap. *)

val write_file : path:string -> content:string -> unit

val link_dir : path:string -> target:string -> unit
(** Create all intermediate directories then write [content] to [path].
    Prints "  created  <path>" to stdout. *)

val normalize : string -> string
(** Lowercase and replace hyphens with underscores — safe for OCaml identifiers
    and dune library names. *)

val capitalize_name : string -> string
(** [normalize] then uppercase the first character — produces a valid OCaml
    module name, e.g. "notify_worker" → "Notify_worker". *)

val tpl_sun_toml   : string
val tpl_dockerfile : string
(** Shared service scaffold templates — used by [Sun_cli_scaffold_svc],
    [Sun_cli_scaffold_worker], [Sun_cli_scaffold_fn], and
    [Sun_cli_scaffold_workspace]. *)

val ws_of_cwd      : unit -> string
(** Infers the workspace name from the current directory's basename. *)

val parse_domain_name : string -> string * string
(** Splits a [domain/name] argument into a [(domain, name)] pair.
    Both components are normalised.  Calls [exit 1] on malformed input. *)
