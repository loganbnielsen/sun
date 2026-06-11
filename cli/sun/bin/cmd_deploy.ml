(* sun deploy — CI/CD integration.
   Like sun up but skips the build step: images are already in a registry.
   Designed to run in CI after the build pipeline has pushed images. *)

open Cmdliner
open Sun_cli_manifest

let workspace_name () = Filename.basename (Sys.getcwd ())

let git_sha () =
  let tmp = Filename.temp_file "sun-" ".tmp" in
  ignore (Sys.command (Printf.sprintf "git rev-parse --short HEAD > %s 2>/dev/null" tmp));
  let ic = open_in tmp in
  let s = String.trim (In_channel.input_all ic) in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  if s = "" then "dev" else s

let run filter_path dry_run emit_to emit_plan_to image_tag registry =
  let workspace = workspace_name () in
  let sha       = match image_tag with Some t -> t | None -> git_sha () in
  let services  = discover_services ~filter_path in

  if services = [] then begin
    Printf.eprintf "No services found in app/ with a Dockerfile.\n";
    exit 1
  end;

  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  (match emit_to with
   | Some dir -> Printf.printf "emit-to: %s\n" dir
   | None when dry_run -> Printf.printf "(dry-run)\n"
   | None -> ());
  Printf.printf "\n%!";

  (* In CI the registry is the production one (ECR, GCR, Docker Hub).
     Without --registry, fall back to the k3d local registry so sun deploy
     works against a local cluster without a --registry flag. *)
  let reg = match registry with
    | Some r -> r
    | None   -> "sun-registry:5000"
  in
  let env_target = Sun_cli_env_target.customer_cloud_defaults
    ~registry:reg
    ~image_tag:sha
    ~emit_to
    ()
  in
  (match Sun_cli_env_target.validate env_target with
   | Ok ()    -> ()
   | Error msg ->
     Printf.eprintf "error: %s\n" msg;
     exit 1);
  let env  = Sun_cli_env_target.to_env_config ~name:workspace env_target in
  let plan = Sun_cli_deployment_plan.of_services ~workspace ~env services in

  (* Emit plan JSON if requested *)
  (match emit_plan_to with
   | None -> ()
   | Some path ->
     let json_str = Yojson.Safe.pretty_to_string (Sun_cli_deployment_plan.to_json plan) in
     if path = "-" then begin
       print_string json_str;
       print_char '\n'
     end else begin
       let oc = open_out path in
       output_string oc json_str;
       output_char oc '\n';
       close_out oc;
       Printf.printf "Plan written to %s\n%!" path
     end);

  (try
    List.iter (fun (spec : Sun_cli_deployment_plan.service_spec) ->
      Printf.printf "[%s] %s/%s\n%!" (prim_label
        (match spec.primitive with
         | Sun_cli_deployment_plan.Svc    -> Svc
         | Sun_cli_deployment_plan.Worker -> Worker
         | Sun_cli_deployment_plan.Fn     -> Fn))
        spec.domain spec.source_name;

      (match emit_to with
       | Some dir ->
         let r = Sun_cli_executor.gitops ~dir spec in
         let path = Filename.concat dir
           (Printf.sprintf "%s-%s.yaml" r.Sun_cli_executor.namespace r.Sun_cli_executor.name) in
         Printf.printf "  ✓  %s\n%!" path
       | None ->
         let r = Sun_cli_executor.direct ~dry_run spec in
         if not dry_run then
           Printf.printf "  ✓  namespace %s  image %s\n\n%!" r.Sun_cli_executor.namespace r.Sun_cli_executor.image)

    ) plan.Sun_cli_deployment_plan.services
  with Deploy_failed msg ->
    Printf.eprintf "\nerror: %s\n" msg;
    exit 1);

  (match emit_to with
   | Some dir ->
     Printf.printf "\nManifests written to %s/\n" dir;
     Printf.printf "Commit and push to your GitOps repo, then Argo CD will apply them.\n"
   | None when not dry_run ->
     Printf.printf "\nDone. %d service(s) deployed.\n" (List.length services);
     Printf.printf "Run 'sun status' to check pod health.\n"
   | None -> ())

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let path_arg =
  Arg.(value & pos 0 (some string) None &
       info [] ~docv:"PATH"
         ~doc:"Service path to deploy (default: all services in workspace)")

let dry_run_flag =
  Arg.(value & flag &
       info ["dry-run"]
         ~doc:"Print synthesized YAML to stdout without applying")

let emit_to_arg =
  Arg.(value & opt (some string) None &
       info ["emit-to"] ~docv:"DIR"
         ~doc:"Write YAML files to DIR instead of applying (GitOps mode). \
               One file per service: <namespace>-<name>.yaml")

let emit_plan_to_arg =
  Arg.(value & opt (some string) None &
       info ["emit-plan-to"] ~docv:"FILE"
         ~doc:"Write the deployment plan as JSON to FILE before executing. \
               Use '-' to print to stdout. Plan format is experimental.")

let image_tag_arg =
  Arg.(value & opt (some string) None &
       info ["image-tag"] ~docv:"TAG"
         ~doc:"Image tag to deploy (default: short git SHA). \
               In CI, pass the exact SHA built by the preceding job.")

let registry_arg =
  Arg.(value & opt (some string) None &
       info ["registry"] ~docv:"URL"
         ~doc:"Container registry prefix, e.g. \
               123456789.dkr.ecr.us-east-1.amazonaws.com. \
               Omit for local k3d cluster (uses sun-registry:5000).")

let cmd =
  Cmd.v
    (Cmd.info "deploy"
       ~doc:"Deploy pre-built images to a cluster (CI/CD integration). \
             Like 'sun up' but skips the build step — images must already \
             be in the registry.")
    Term.(const run $ path_arg $ dry_run_flag $ emit_to_arg
          $ emit_plan_to_arg $ image_tag_arg $ registry_arg)
