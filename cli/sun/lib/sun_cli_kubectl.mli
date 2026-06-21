val apply        : file:string -> (unit, Sun_cli_process.error) result
val apply_dry_run : file:string -> (unit, Sun_cli_process.error) result
val get          : resource:string -> name:string -> namespace:string
                   -> output:string -> (Sun_cli_process.result, Sun_cli_process.error) result
val get_raw      : args:string list -> (Sun_cli_process.result, Sun_cli_process.error) result
val logs         : pod:string -> namespace:string -> container:string option
                   -> (Sun_cli_process.result, Sun_cli_process.error) result
val rollout_status : kind_name:string -> namespace:string
                     -> (Sun_cli_process.result, Sun_cli_process.error) result
val rollout_undo   : kind_name:string -> namespace:string
                     -> (Sun_cli_process.result, Sun_cli_process.error) result
val rollout_restart : kind:string -> namespace:string
                      -> (Sun_cli_process.result, Sun_cli_process.error) result
val patch        : resource:string -> name:string -> namespace:string
                   -> patch_type:string -> patch:string
                   -> (Sun_cli_process.result, Sun_cli_process.error) result
val config_current_context : unit -> (Sun_cli_process.result, Sun_cli_process.error) result
val argo_rollout_undo   : namespace:string -> name:string
                         -> (Sun_cli_process.result, Sun_cli_process.error) result
val argo_rollout_status : namespace:string -> name:string
                         -> (Sun_cli_process.result, Sun_cli_process.error) result
val probe        : args:string list -> bool
