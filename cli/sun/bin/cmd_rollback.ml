(* sun rollback — roll back the last deployment for one or all services *)

open Cmdliner
open Sun_cli_manifest

let workspace_name () = Filename.basename (Sys.getcwd ())

let run_cmd cmd =
  Sys.command cmd

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
    let ns       = Sun_cli_deployment_plan.namespace_of ~workspace ~domain:svc.domain in
    let k8s_name = String.map (fun c -> if c = '_' then '-' else c) svc.name in

    Printf.printf "[%s] %s/%s\n%!" (prim_label svc.prim) svc.domain svc.name;

    let undo_cmd = Printf.sprintf
      "kubectl rollout undo deployment/%s -n %s" (Filename.quote k8s_name) (Filename.quote ns) in
    let rc = run_cmd undo_cmd in
    if rc <> 0 then begin
      Printf.eprintf "  error: kubectl rollout undo failed for %s/%s (exit %d)\n%!"
        svc.domain svc.name rc;
      incr errors
    end else begin
      Printf.printf "  ✓  rolled back %s/%s\n%!" svc.domain svc.name;

      (* Wait for the rolled-back revision to become healthy *)
      let status_cmd = Printf.sprintf
        "kubectl rollout status deployment/%s -n %s" (Filename.quote k8s_name) (Filename.quote ns) in
      let src = run_cmd status_cmd in
      if src <> 0 then begin
        Printf.eprintf "  warning: rollout status check failed for %s/%s (exit %d)\n%!"
          svc.domain svc.name src;
        incr errors
      end
    end;
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
