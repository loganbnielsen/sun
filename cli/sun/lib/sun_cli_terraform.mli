val which_check : unit -> bool
val init        : chdir:string -> (Sun_cli_process.result, Sun_cli_process.error) result
val plan        : chdir:string -> var_files:string list -> vars:string list
                  -> (Sun_cli_process.result, Sun_cli_process.error) result
val plan_destroy : chdir:string -> var_files:string list -> vars:string list
                   -> (Sun_cli_process.result, Sun_cli_process.error) result
val apply       : chdir:string -> var_files:string list -> vars:string list
                  -> (Sun_cli_process.result, Sun_cli_process.error) result
val destroy     : chdir:string -> var_files:string list -> vars:string list
                  -> (Sun_cli_process.result, Sun_cli_process.error) result
val output_json : chdir:string -> (Sun_cli_process.result, Sun_cli_process.error) result
