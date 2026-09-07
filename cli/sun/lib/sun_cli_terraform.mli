val which_check : unit -> bool
val init        : chdir:string -> (Sun_cli_process.result, Sun_cli_process.error) result

val kv_args : (string * string) list -> string list
(** ["key=value"] Terraform CLI syntax for a list of neutral key/value
    pairs — e.g. {!Sun_cli_config.terraform_vars}'s result, before it's
    combined with any raw ["key=value"] strings a caller already has
    (such as [sun cloud]'s own [--var] CLI flag) and passed as [~vars]
    below. *)

val plan        : chdir:string -> var_files:string list -> vars:string list
                  -> (Sun_cli_process.result, Sun_cli_process.error) result
val plan_destroy : chdir:string -> var_files:string list -> vars:string list
                   -> (Sun_cli_process.result, Sun_cli_process.error) result
val apply       : chdir:string -> var_files:string list -> vars:string list
                  -> (Sun_cli_process.result, Sun_cli_process.error) result
val destroy     : chdir:string -> var_files:string list -> vars:string list
                  -> (Sun_cli_process.result, Sun_cli_process.error) result
val output_json : chdir:string -> (Sun_cli_process.result, Sun_cli_process.error) result
