type warning =
  | Duplicate_topic    of string
  | Duplicate_subject  of string
  | Unreadable_dir     of { path : string; reason : string }
  | Malformed_metadata of { path : string; message : string }

type t = {
  services        : Sun_cli_manifest.service list;
  schedules       : (string * string) list;  (** [(service_name, cron)] for every -fn *)
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
val discover_services        : dir:string -> Sun_cli_manifest.service list * warning list
val discover_schedules       : Sun_cli_manifest.service list -> (string * string) list * warning list

val scan : dir:string -> t
