type warning =
  | Duplicate_topic    of string
  | Duplicate_subject  of string
  | Unreadable_dir     of { path : string; reason : string }
  | Malformed_metadata of { path : string; message : string }

type t = {
  topics          : string list;
  schema_subjects : string list;
  migrations      : string list;
  infra           : Sun_cli_workspace.infra_requirements;
  warnings        : warning list;
}

val warning_to_string : warning -> string

val discover_topics          : dir:string -> string list * warning list
val discover_schema_subjects : dir:string -> string list * warning list
val discover_migrations      : dir:string -> string list * warning list

val scan : dir:string -> t
