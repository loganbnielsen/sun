type set_val =
  | Bool  of bool
  | Float of float
  | Str   of string

val repo_add    : name:string -> url:string -> (Sun_cli_process.result, Sun_cli_process.error) result
val repo_update : unit -> (Sun_cli_process.result, Sun_cli_process.error) result
val upgrade_install : release:string -> chart:string -> namespace:string
                      -> ?values:(string * set_val) list -> unit
                      -> (Sun_cli_process.result, Sun_cli_process.error) result
