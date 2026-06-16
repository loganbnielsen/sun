type result = {
  exit_code : int;
  stdout    : string;
  stderr    : string;
}

val run      : ?echo:bool -> string -> result
val run_argv : ?echo:bool -> string list -> result
val lines    : ?echo:bool -> string -> string list
val output   : ?echo:bool -> string -> string
val run_rc   : ?echo:bool -> string -> int
val run_ok   : ?echo:bool -> string -> unit

(** [with_tmp_file prefix content f] writes [content] to a temp file whose
    name starts with [prefix], calls [f] with the path, then deletes the file
    whether [f] returns or raises. *)
val with_tmp_file : string -> string -> (string -> 'a) -> 'a

(** [capture_cmd cmd] runs [cmd] via the shell and returns [(exit_code, stdout)].
    Stderr is discarded. *)
val capture_cmd : string -> int * string
