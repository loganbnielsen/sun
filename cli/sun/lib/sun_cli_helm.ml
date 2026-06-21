type set_val =
  | Bool  of bool
  | Float of float
  | Str   of string

let run = Sun_cli_process.run
let cmd = Sun_cli_process.cmd

let repo_add ~name ~url =
  run (cmd ["helm"; "repo"; "add"; name; url])

let repo_update () =
  run (cmd ["helm"; "repo"; "update"])

let upgrade_install ~release ~chart ~namespace ?(values = []) () =
  let set_flags = values |> List.concat_map (fun (k, v) -> match v with
    | Bool  b -> ["--set"; Printf.sprintf "%s=%s" k (string_of_bool b)]
    | Float f -> ["--set"; Printf.sprintf "%s=%g" k f]
    | Str   s -> ["--set-string"; Printf.sprintf "%s=%s" k s])
  in
  let argv =
    ["helm"; "upgrade"; "--install"; release; chart]
    @ ["--namespace"; namespace; "--create-namespace"]
    @ set_flags
    @ ["--wait"; "--timeout"; "3m"]
  in
  run ~echo:true (cmd argv)
