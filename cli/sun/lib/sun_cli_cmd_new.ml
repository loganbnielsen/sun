open Cmdliner

(* Re-exports for test_scaffold.ml backward compatibility *)
let is_sun_home    = Sun_cli_scaffold_workspace.is_sun_home
let find_ancestor  = Sun_cli_scaffold_workspace.find_ancestor
let infer_sun_home = Sun_cli_scaffold_workspace.infer_sun_home
let new_workspace  = Sun_cli_scaffold_workspace.new_workspace
let new_worker     = Sun_cli_scaffold_worker.new_worker

let name_arg docv doc =
  Arg.(required & pos 0 (some string) None & info [] ~docv ~doc)

let workspace_cmd =
  Cmd.v
    (Cmd.info "workspace" ~doc:"Scaffold a new Sun workspace with a working two-service example")
    Term.(const new_workspace $ name_arg "NAME" "Workspace name, e.g. acme")

let svc_cmd =
  Cmd.v
    (Cmd.info "svc" ~doc:"Add an HTTP service to the current workspace")
    Term.(const Sun_cli_scaffold_svc.new_svc $ name_arg "DOMAIN/NAME" "e.g. payments/charge")

let worker_cmd =
  Cmd.v
    (Cmd.info "worker" ~doc:"Add a Kafka consumer worker to the current workspace")
    Term.(const new_worker $ name_arg "DOMAIN/NAME" "e.g. comms/notify")

let fn_cmd =
  Cmd.v
    (Cmd.info "fn" ~doc:"Add a scheduled function to the current workspace")
    Term.(const Sun_cli_scaffold_fn.new_fn $ name_arg "DOMAIN/NAME" "e.g. billing/monthly_report")

let event_cmd =
  Cmd.v
    (Cmd.info "event" ~doc:"Add a typed Kafka event contract to the current workspace")
    Term.(const Sun_cli_scaffold_event.new_event $ name_arg "TEAM/NAME" "e.g. payments/charged")

let cmd =
  Cmd.group
    (Cmd.info "new" ~doc:"Scaffold workspace components")
    [ workspace_cmd; svc_cmd; worker_cmd; fn_cmd; event_cmd ]
