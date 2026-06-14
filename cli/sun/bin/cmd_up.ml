open Cmdliner
open Sun_cli_manifest

(* ── Shell helpers ───────────────────────────────────────────────────────── *)

let run_cmd ?(echo = true) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  Sys.command cmd

(* ── Port-forward state dir ──────────────────────────────────────────────── *)

let state_dir = ".sun"

let wait_for_rollout ~namespace ~name =
  let cmd = Printf.sprintf
    "kubectl rollout status deployment/%s -n %s --timeout=60s"
    (Filename.quote name) (Filename.quote namespace)
  in
  run_cmd ~echo:false cmd

let run_cmd_to_string cmd =
  let tmp = Filename.temp_file "sun-" ".tmp" in
  ignore (Sys.command (Printf.sprintf "%s > %s 2>/dev/null" cmd tmp));
  let ic = open_in tmp in
  let s = String.trim (In_channel.input_all ic) in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  s

(* ── Workspace / git helpers ─────────────────────────────────────────────── *)

let workspace_name () = Filename.basename (Sys.getcwd ())

let git_sha () =
  let s = run_cmd_to_string "git rev-parse --short HEAD" in
  if s = "" then "dev" else s

let current_kube_context () =
  run_cmd_to_string "kubectl config current-context"

let is_known_local_dev_context () =
  current_kube_context () = "k3d-sun-local"

let find_repo_root () =
  let rec go dir =
    if Sys.file_exists (Filename.concat dir "dune-workspace") then dir
    else if Sys.file_exists (Filename.concat dir "dune-project") then dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then dir
      else go parent
  in
  go (Sys.getcwd ())

(* ── Consumer group change detection ─────────────────────────────────────── *)

let deploy_state_configmap_name workspace =
  Printf.sprintf "sun-deploy-state-%s" workspace

(* Load the last-deployed consumer groups from a ConfigMap in the default
   namespace.  Returns [] if the ConfigMap does not exist or kubectl fails — the
   guard is advisory; missing state never blocks a first deploy. *)
let load_deployed_groups workspace =
  let name = deploy_state_configmap_name workspace in
  let path = Filename.temp_file "sun-groups-" ".txt" in
  let cmd = Printf.sprintf
    "kubectl get configmap %s -n default \
     -o jsonpath='{.data.consumer_groups}' 2>/dev/null > %s"
    (Filename.quote name) (Filename.quote path)
  in
  let groups =
    if Sys.command cmd <> 0 then []
    else begin
      let ic = open_in path in
      let content = In_channel.input_all ic in
      close_in ic;
      String.split_on_char '\n' content
      |> List.map String.trim
      |> List.filter (fun s -> s <> "")
    end
  in
  (try Sys.remove path with _ -> ());
  groups

(* Persist the current consumer groups to the sun-deploy-state ConfigMap. *)
let save_deployed_groups workspace groups =
  let name = deploy_state_configmap_name workspace in
  let value = String.concat "\n" groups in
  let apply_json = Printf.sprintf
    {|{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"%s","namespace":"default"},"data":{"consumer_groups":"%s"}}|}
    (String.escaped name) (String.escaped value)
  in
  let path = Filename.temp_file "sun-state-" ".json" in
  let oc = open_out path in
  output_string oc apply_json;
  close_out oc;
  ignore (Sys.command (Printf.sprintf "kubectl apply -f %s >/dev/null 2>&1"
    (Filename.quote path)));
  (try Sys.remove path with _ -> ())

(* Check for consumer group renames/removals between the last deployed state
   and the current plan.  Returns a list of group IDs that were present before
   but are absent now.  An empty list means no breaking change. *)
let removed_consumer_groups ~prev ~next =
  List.filter (fun g -> not (List.mem g next)) prev

(* ── Pipeline ────────────────────────────────────────────────────────────── *)

let run filter_path dry_run tag confirm_group_change =
  let workspace = workspace_name () in
  let sha       = match tag with Some t -> t | None -> git_sha () in
  let services  = discover_services ~filter_path in
  let repo_root = find_repo_root () in
  let pf_failed = ref false in

  if services = [] then begin
    Printf.eprintf "No services found in app/ with a Dockerfile.\n";
    exit 1
  end;

  (* Pre-flight: POSTGRES_URL must be set before applying to non-local
     clusters.  For local k3d, populate it with the in-cluster dev Postgres
     URL so generated Secrets carry a usable value instead of "".
     Dry-run is exempt because it only prints YAML. *)
  if not dry_run then begin
    if is_known_local_dev_context () then begin
      (* Inject the dev Postgres URL when running against the local k3d cluster
         and the operator has not already overridden it. *)
      (match Sys.getenv_opt "POSTGRES_URL" with
       | None | Some "" ->
         Unix.putenv "POSTGRES_URL"
           "postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev"
       | Some _ -> ())
    end else begin
      match Sys.getenv_opt "POSTGRES_URL" with
      | None | Some "" ->
        Printf.eprintf
          "error: POSTGRES_URL is not set.\n\
           Set it in your environment before running 'sun up':\n\
           \  export POSTGRES_URL=postgresql://user:pass@host:5432/dbname\n";
        exit 1
      | Some _ -> ()
    end
  end;

  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  if dry_run then Printf.printf "(dry-run)\n";
  Printf.printf "\n%!";

  (* k3d's registries.yaml maps sun-registry:5000 → the registry container.
     The env target owns the cluster-internal registry address (sun-registry:5000).
     Push uses localhost:5000 (host-accessible); that address is build-step-only
     and is computed locally — not embedded in the plan. *)
  let env_target    = Sun_cli_env_target.local_defaults ~image_tag:sha in
  let push_registry = "localhost:5000" in

  let env  = Sun_cli_env_target.to_env_config ~name:workspace env_target in
  let plan = Sun_cli_deployment_plan.of_services ~workspace ~env services in

  (* Consumer group rename/removal guard.  Skipped in dry-run — no state is
     loaded or written, and no blocking question is asked. *)
  if not dry_run then begin
    let prev_groups = load_deployed_groups workspace in
    let next_groups = plan.Sun_cli_deployment_plan.consumer_groups in
    let removed = removed_consumer_groups ~prev:prev_groups ~next:next_groups in
    if removed <> [] && not confirm_group_change then begin
      Printf.eprintf
        "\nwarning: the following consumer group(s) are no longer present in \
         this deploy plan:\n";
      List.iter (fun g -> Printf.eprintf "  - %s\n" g) removed;
      Printf.eprintf
        "\nMessages produced while the old group is absent will be consumed\n\
         from the latest offset when the group is re-added, silently skipping\n\
         any backlog.  Pass --confirm-group-change to acknowledge and proceed.\n\n";
      exit 1
    end
  end;

  (* The multi-stage Dockerfile compiles from source inside ubuntu-24.04, so
     vendor/ symlinks (which point outside the workspace) must be resolved into
     real files before docker build runs.  We create a temporary self-contained
     copy with rsync --copy-links (follow symlinks, exclude _build and .git to
     avoid stale dune internal symlinks that cp -rL cannot resolve) and remove
     the copy when done. *)
  let ctx_dir = repo_root ^ ".docker-ctx" in
  if not dry_run then begin
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
    Printf.printf "Preparing build context...\n%!";
    let rsync_cmd = Printf.sprintf
      "rsync -a --copy-links --exclude='_build' --exclude='.git' %s/ %s"
      (Filename.quote repo_root) (Filename.quote ctx_dir) in
    if Sys.command rsync_cmd <> 0 then begin
      Printf.eprintf "error: failed to copy workspace for docker build context\n";
      exit 1
    end
  end;

  (try
    List.iter (fun (spec : Sun_cli_deployment_plan.service_spec) ->
      (* push_image is the host-accessible URL used for docker build/push and
         shown in dry-run output — it matches what actually gets written into the
         registry.  spec.image is the in-cluster URL baked into the manifest. *)
      let push_image = Sun_cli_deployment_plan.image_ref
        ~registry:push_registry ~workspace
        ~k8s_name:spec.k8s_name ~tag:sha in
      let repo_dir   = spec.source_dir in
      (* In dry-run the ctx_dir is not created; fall back to repo_root for the
         Dockerfile path so the plan output shows a real path. *)
      let build_ctx  = if dry_run then repo_root else ctx_dir in
      let dockerfile = Printf.sprintf "%s/%s/Dockerfile" build_ctx repo_dir in

      Printf.printf "[%s] %s/%s\n%!" (prim_label
        (match spec.primitive with
         | Sun_cli_deployment_plan.Svc    -> Svc
         | Sun_cli_deployment_plan.Worker -> Worker
         | Sun_cli_deployment_plan.Fn     -> Fn))
        spec.domain spec.source_name;

      if not dry_run then begin
        Printf.printf "  packaging %s...\n%!" push_image;
        let docker_cmd = Printf.sprintf "docker build -t %s -f %s %s"
          (Filename.quote push_image) (Filename.quote dockerfile) (Filename.quote ctx_dir) in
        if run_cmd ~echo:false docker_cmd <> 0 then
          raise (Deploy_failed (Printf.sprintf "docker build failed: %s" spec.source_dir));
        Printf.printf "  pushing...\n%!";
        if run_cmd ~echo:false (Printf.sprintf "docker push %s" (Filename.quote push_image)) <> 0 then
          raise (Deploy_failed (Printf.sprintf "docker push failed: %s" push_image))
      end;

      (* dry-run shows push_image (what actually gets pushed);
         live apply uses spec.image (the cluster-resolved reference).
         We pass the spec with the appropriate image to the local executor. *)
      let exec_spec =
        if dry_run then { spec with Sun_cli_deployment_plan.image = push_image }
        else spec
      in
      ignore (Sun_cli_executor.local ~dry_run exec_spec);

      if not dry_run then begin
        (match spec.primitive with
         | Sun_cli_deployment_plan.Svc
         | Sun_cli_deployment_plan.Worker ->
           Printf.printf "  waiting for rollout...\n%!";
           if wait_for_rollout ~namespace:spec.namespace ~name:spec.k8s_name <> 0 then
             raise (Deploy_failed (Printf.sprintf "rollout failed: %s/%s" spec.namespace spec.k8s_name))
         | Sun_cli_deployment_plan.Fn -> ());
        (match spec.primitive with
         | Sun_cli_deployment_plan.Svc ->
           let local_port = 8080 in
           let pf : Sun_cli_port_forward.spec = {
             name       = spec.k8s_name;
             namespace  = spec.namespace;
             target     = "svc/" ^ spec.k8s_name;
             local_port;
             remote_port = 80;
           } in
           if not (Sun_cli_port_forward.is_alive ~state_dir pf) then begin
             (* Before binding the port, check whether a stale Sun-managed
                port-forward from a different workspace/namespace already owns
                it.  If so, kill it and print a notice.  We only kill kubectl
                processes — never unrelated processes. *)
             (match Sun_cli_port_forward.detect_stale ~state_dir pf with
              | Some (stale_pid, old_ns, old_target) ->
                Printf.printf
                  "  [sun up] replacing stale port-forward for %s/%s on port %d\n%!"
                  old_ns old_target local_port;
                (try Unix.kill stale_pid Sys.sigterm
                 with Unix.Unix_error _ -> ());
                (* Give the old process ~400 ms to release the port before we
                   start the new wrapper script. *)
                Unix.sleepf 0.4
              | None -> ());
             Sun_cli_port_forward.start ~state_dir pf
           end;
           let pf_alive = Sun_cli_port_forward.liveness_check ~state_dir pf in
           Printf.printf "  ✓  namespace %s  image %s\n%!" spec.namespace spec.image;
           if pf_alive then
             Printf.printf "  →  http://localhost:%d  (port-forward running in background)\n\n%!" local_port
           else begin
             pf_failed := true;
             Printf.printf "\n%!"
           end
         | _ ->
           Printf.printf "  ✓  namespace %s  image %s\n%!" spec.namespace spec.image;
           Printf.printf "\n%!")
      end

    ) plan.Sun_cli_deployment_plan.services
  with Deploy_failed msg ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
    Printf.eprintf "\nerror: %s\n" msg;
    exit 1);

  if not dry_run then begin
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
    Printf.printf "Done. %d service(s) deployed.\n" (List.length services);
    Printf.printf "Run 'sun status' to check pod health.\n";
    (* Warn if unapplied migration files exist *)
    let n = Sun_cli_workspace.pending_migration_count ~dir:(Sys.getcwd ()) in
    if n > 0 then
      Printf.printf
        "\nNote: %d migration file(s) found in db/migrations/ — run 'sun migrate' to apply.\n"
        n;
    (* Persist deployed consumer groups for future change detection. *)
    save_deployed_groups workspace plan.Sun_cli_deployment_plan.consumer_groups;
    if !pf_failed then exit 1
  end

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let path_arg =
  Arg.(value & pos 0 (some string) None &
       info [] ~docv:"PATH"
         ~doc:"Service path to build and deploy (default: all services in workspace)")

let dry_run_flag =
  Arg.(value & flag &
       info ["dry-run"]
         ~doc:"Print synthesized YAML to stdout without applying to the cluster")

let tag_arg =
  Arg.(value & opt (some string) None &
       info ["tag"] ~docv:"TAG"
         ~doc:"Docker image tag (default: short git SHA)")

let confirm_group_change_flag =
  Arg.(value & flag &
       info ["confirm-group-change"]
         ~doc:"Acknowledge that consumer group IDs have changed and proceed with deploy")

let cmd =
  Cmd.v
    (Cmd.info "up"
       ~doc:"Build images, synthesize k8s manifests, and deploy to the cluster")
    Term.(const run $ path_arg $ dry_run_flag $ tag_arg $ confirm_group_change_flag)
