(* sun rollback — roll back the last deployment for one or all services *)

open Cmdliner
open Sun_cli_manifest

let workspace_name () = Filename.basename (Sys.getcwd ())


(** Check whether the kubectl-argo-rollouts plugin is available.
    Tries both the hyphenated binary name (kubectl-argo-rollouts) and
    the sub-command form (kubectl argo rollouts version). *)
let argo_plugin_available () =
  (match Sun_cli_process.run (Sun_cli_process.cmd ["kubectl-argo-rollouts"; "version"]) with
   | Ok r -> r.Sun_cli_process.exit_code = 0
   | Error _ -> false)
  || Sun_cli_kubectl.probe ~args:["argo"; "rollouts"; "version"]

let namespace_or_exit ~workspace ~domain =
  match Sun_cli_deployment_plan.namespace_result ~workspace ~domain with
  | Ok namespace -> Sun_cli_deployment_plan.namespace_to_string namespace
  | Error err ->
    Printf.eprintf "error: %s\n" (Sun_cli_deployment_plan.plan_error_to_string err);
    exit 1

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
    let ns = namespace_or_exit ~workspace ~domain:svc.domain in
    let k8s_name =
      match Sun_cli_deployment_plan.k8s_name_result svc.name with
      | Ok k8s_name -> Sun_cli_deployment_plan.k8s_name_to_string k8s_name
      | Error err ->
        Printf.eprintf "error: %s\n" (Sun_cli_deployment_plan.plan_error_to_string err);
        exit 1
    in

    Printf.printf "[%s] %s/%s\n%!" (prim_label svc.prim) svc.domain svc.name;

    (* Load sun.toml from the service directory to detect progressive delivery. *)
    let toml = Sun_cli_toml.load (Filename.concat svc.dir "sun.toml") in

    let run_kubectl argv =
      match Sun_cli_process.run ~echo:true (Sun_cli_process.cmd argv) with
      | Ok r -> r.Sun_cli_process.exit_code
      | Error _ -> 1
    in
    (match toml.Sun_cli_toml.progressive_delivery with
    | Some _ ->
      (* Service uses Argo Rollouts — use the kubectl-argo-rollouts plugin. *)
      if argo_plugin_available () then begin
        let rc = run_kubectl ["kubectl"; "argo"; "rollouts"; "undo"; k8s_name; "-n"; ns] in
        if rc <> 0 then begin
          Printf.eprintf "  error: kubectl argo rollouts undo failed for %s/%s (exit %d)\n%!"
            svc.domain svc.name rc;
          incr errors
        end else
          Printf.printf "  ✓  rolled back %s/%s (Argo Rollout)\n%!" svc.domain svc.name
      end else begin
        Printf.eprintf
          "  error: service %s/%s uses Argo Rollouts — install the Argo Rollouts kubectl plugin to roll back.\n\
          \    Install: https://argoproj.github.io/argo-rollouts/installation/#kubectl-plugin\n\
          \    Manual:  kubectl argo rollouts undo %s -n %s\n%!"
          svc.domain svc.name k8s_name ns;
        incr errors
      end
    | None ->
      (* Standard Deployment — use kubectl rollout undo. *)
      let rc = (match Sun_cli_kubectl.rollout_undo
                    ~kind_name:("deployment/" ^ k8s_name) ~namespace:ns with
        | Ok r -> r.Sun_cli_process.exit_code
        | Error _ -> 1) in
      if rc <> 0 then begin
        Printf.eprintf "  error: kubectl rollout undo failed for %s/%s (exit %d)\n%!"
          svc.domain svc.name rc;
        incr errors
      end else begin
        Printf.printf "  ✓  rolled back %s/%s\n%!" svc.domain svc.name;

        (* Wait for the rolled-back revision to become healthy *)
        let src = (match Sun_cli_kubectl.rollout_status
                       ~kind_name:("deployment/" ^ k8s_name) ~namespace:ns with
          | Ok r -> r.Sun_cli_process.exit_code
          | Error _ -> 1) in
        if src <> 0 then begin
          Printf.eprintf "  warning: rollout status check failed for %s/%s (exit %d)\n%!"
            svc.domain svc.name src;
          incr errors
        end
      end);
    Printf.printf "\n%!"
  ) services;

  if !errors = 0 then
    Printf.printf "Done. %d service(s) rolled back.\n" (List.length services)
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
