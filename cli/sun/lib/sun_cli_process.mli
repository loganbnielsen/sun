(** Centralised external-process helpers for the Sun CLI.

    All external commands invoked by the CLI should go through this module.
    Use [run_shell] only where shell features (redirection, background execution)
    are genuinely required; prefer [run], [exec], or [capture] otherwise. *)

type output = {
  exit_code : int;
  stdout    : string;
  stderr    : string;
  command   : string;  (** quoted argv string, for error messages *)
}

val run_shell : ?echo:bool -> string -> int
(** Run [cmd] through [/bin/sh -c].  Prints ["  $ cmd"] when [echo = true]
    (default).  Returns the shell exit code.

    Shell escape hatch — document call sites with [(* shell: <reason> *)].
    Use only where shell features are required: [2>/dev/null], [&], pipes. *)

val run : ?echo:bool -> string -> string list -> output
(** Run [prog args] without a shell.  Captures stdout and stderr via pipes;
    deadlock-safe for any output volume.  Prints the quoted argv when
    [echo = true] (default). *)

val exec : ?echo:bool -> string -> string list -> int
(** Run [prog args] without a shell, inheriting stdout/stderr (output goes to
    the terminal).  Returns exit code.  Use for interactive / streaming output. *)

val capture : string -> string list -> (string, string) result
(** [capture prog args] — like [run ~echo:false], but returns
    [Ok (trimmed stdout)] on success or [Error (trimmed stderr)] on failure. *)

val check_tool : string -> install_url:string -> unit
(** Assert [name] is in PATH.  Prints an install hint and calls [exit 1] if
    not found. *)
