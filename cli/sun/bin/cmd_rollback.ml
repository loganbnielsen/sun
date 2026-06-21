(* sun rollback — roll back the last deployment for one or all services *)

open Cmdliner
open Sun_cli_manifest

let workspace_name () = Filename.basename (Sys.getcwd ())

let run filter_path =
  let workspace = workspace_name () in
  let services  = discover_services ~filter_path in

  if services = [] then begin
    Printf.eprintf "No services found in app/ with a Dockerfile.\n";
    exit 1
  end;

  Printf.printf "\nWorkspace: %s\n\n%!" workspace;

  let errors = ref 0 in

  List.iter (fun svc ->
    Printf.printf "[%s] %s/%s\n%!" (prim_label svc.prim) svc.domain svc.name;

    let k8s_name_val = match Sun_cli_deployment_plan.k8s_name_result svc.name with
      | Ok v -> v
      | Error err ->
        Printf.eprintf "error: %s\n" (Sun_cli_deployment_plan.plan_error_to_string err);
        exit 1
    in
    let namespace_val = match Sun_cli_deployment_plan.namespace_result ~workspace ~domain:svc.domain with
      | Ok v -> v
      | Error err ->
        Printf.eprintf "error: %s\n" (Sun_cli_deployment_plan.plan_error_to_string err);
        exit 1
    in

    let toml = Sun_cli_toml.load (Filename.concat svc.dir "sun.toml") in

    let primitive = match svc.prim with
      | Svc    -> Sun_cli_deployment_plan.Svc
      | Worker -> Sun_cli_deployment_plan.Worker
      | Fn     -> Sun_cli_deployment_plan.Fn
    in
    let default_cpu =
      match Sun_cli_toml.cpu_quantity_of_string "100m" with
      | Ok v -> v | Error msg -> invalid_arg msg
    in
    let default_memory =
      match Sun_cli_toml.memory_quantity_of_string "128Mi" with
      | Ok v -> v | Error msg -> invalid_arg msg
    in
    let spec : Sun_cli_deployment_plan.service_spec =
      { domain               = svc.domain
      ; source_name          = svc.name
      ; k8s_name             = k8s_name_val
      ; namespace            = namespace_val
      ; primitive
      ; source_dir           = svc.dir
      ; image                = ""
      ; config               = []
      ; secrets              = []
      ; schedule             = None
      ; replicas             = 1
      ; cpu                  = default_cpu
      ; memory               = default_memory
      ; rollout_strategy     = toml.Sun_cli_toml.rollout_strategy
      ; ingress_host         = None
      ; ingress_path         = None
      ; extra_labels         = []
      ; progressive_delivery = toml.Sun_cli_toml.progressive_delivery
      }
    in

    let target = Sun_cli_rollback.rollback_target_of_service spec in
    (match Sun_cli_rollback.execute_rollback target with
     | Ok () ->
       (match target with
        | Sun_cli_rollback.No_op reason ->
          Printf.printf "  skipped %s/%s (%s)\n%!" svc.domain svc.name reason
        | Sun_cli_rollback.Argo_rollout _ ->
          Printf.printf "  rolled back %s/%s (Argo Rollout)\n%!" svc.domain svc.name
        | Sun_cli_rollback.Standard_deployment _ ->
          Printf.printf "  rolled back %s/%s\n%!" svc.domain svc.name)
     | Error err ->
       Printf.eprintf "  error: %s\n%!" (Sun_cli_rollback.error_to_string err);
       incr errors);

    Printf.printf "\n%!"
  ) services;

  if !errors = 0 then
    Printf.printf "Done. %d service(s) processed.\n" (List.length services)
  else begin
    Printf.eprintf "%d rollback(s) failed — see errors above.\n" !errors;
    exit 1
  end

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let path_arg =
  Arg.(value & pos 0 (some string) None &
       info [] ~docv:"SERVICE"
         ~doc:"Service path to roll back, e.g. payments/charge_svc \
               (default: all services in workspace)")

let cmd =
  Cmd.v
    (Cmd.info "rollback"
       ~doc:"Roll back the last deployment for one or all services. \
             Runs 'kubectl rollout undo' for each matching service and \
             waits for the previous revision to become healthy.")
    Term.(const run $ path_arg)
