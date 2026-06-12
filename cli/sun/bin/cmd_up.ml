open Cmdliner
open Sun_cli_manifest

(* ── Shell helpers ───────────────────────────────────────────────────────── *)

let run_cmd ?(echo = true) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  Sys.command cmd

(* ── Port-forward helpers (mirrors cmd_dev.ml) ───────────────────────────── *)

let state_dir = ".sun"

let ensure_state_dir () =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" state_dir))

let pid_file name = Printf.sprintf "%s/pf-%s.pid" state_dir name

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec go i =
      i <= hl - nl
      && (String.sub haystack i nl = needle || go (i + 1))
    in
    go 0

let read_cmdline pid =
  let tmp = Filename.temp_file "sun-ps-" ".tmp" in
  ignore (Sys.command (Printf.sprintf "ps -p %d -o args= > %s 2>/dev/null" pid (Filename.quote tmp)));
  let ic = open_in tmp in
  let s = String.trim (In_channel.input_all ic) in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  s

let log_file name = Printf.sprintf "/tmp/sun-pf-%s.log" name
let script_file name = Printf.sprintf "/tmp/sun-pf-%s.sh" name

(* The PID file now holds the wrapper shell's PID, not kubectl's.
   Identify our wrapper by the script file name in the process's cmdline. *)
let port_forward_running ~service:_ name =
  let pf = pid_file name in
  if Sys.file_exists pf then begin
    let ic = open_in pf in
    let pid_s = String.trim (In_channel.input_all ic) in
    close_in ic;
    try
      let pid = int_of_string pid_s in
      let alive = Sys.command (Printf.sprintf "kill -0 %d 2>/dev/null" pid) = 0 in
      let args = if alive then read_cmdline pid else "" in
      let ok = alive && contains args (Printf.sprintf "sun-pf-%s.sh" name) in
      if not ok then (try Sys.remove pf with _ -> ());
      ok
    with _ ->
      (try Sys.remove pf with _ -> ());
      false
  end else false

(** Write a self-restarting wrapper script and background it in a new session.
    On pod rollout, kubectl exits; the loop restarts it within ~1 s so the
    port-forward stays live across deploys without manual intervention. *)
let start_port_forward ~name ~namespace ~service ~local_port ~remote_port =
  ensure_state_dir ();
  let sf = script_file name in
  let lf = log_file name in
  let pf = pid_file name in
  let content = Printf.sprintf
    "#!/bin/sh\necho $$ > %s\nwhile true; do\n  kubectl port-forward -n %s svc/%s %d:%d </dev/null >> %s 2>&1\n  sleep 1\ndone\n"
    (Filename.quote pf)
    (Filename.quote namespace) (Filename.quote service)
    local_port remote_port
    (Filename.quote lf)
  in
  let oc = open_out sf in
  output_string oc content;
  close_out oc;
  ignore (Sys.command (Printf.sprintf "chmod +x %s" (Filename.quote sf)));
  (* setsid puts the loop in its own session so it outlives this process;
     the trailing & returns immediately to the OCaml caller. *)
  ignore (run_cmd ~echo:false
    (Printf.sprintf "setsid %s </dev/null >/dev/null 2>&1 &" (Filename.quote sf)))

(** Read the last [n] lines of a file, or [""] if the file is missing/empty. *)
let read_last_lines path n =
  try
    let ic = open_in path in
    let content = In_channel.input_all ic in
    close_in ic;
    let lines = String.split_on_char '\n' (String.trim content) in
    let total = List.length lines in
    let tail = if total <= n then lines
               else
                 let rec drop k lst = if k = 0 then lst else drop (k-1) (List.tl lst) in
                 drop (total - n) lines
    in
    String.concat "\n" tail
  with _ -> ""

(** Sleep 200 ms, then check whether the port-forward process for [name] is
    still alive.  Returns [true] if alive, [false] if dead.  When dead, prints
    a warning with the log path and a suggested remediation command. *)
let check_port_forward_liveness ~name ~local_port =
  Unix.sleepf 0.2;
  let pf = pid_file name in
  let alive =
    if Sys.file_exists pf then begin
      try
        let ic = open_in pf in
        let pid_s = String.trim (In_channel.input_all ic) in
        close_in ic;
        let pid = int_of_string pid_s in
        (try Unix.kill pid 0; true
         with Unix.Unix_error (Unix.ESRCH, _, _) -> false
            | Unix.Unix_error _ -> true)  (* EPERM means process exists *)
      with _ -> false
    end else false
  in
  if not alive then begin
    let lf = log_file name in
    let tail = read_last_lines lf 5 in
    Printf.printf
      "  warning: port-forward for %s failed (port %d may be in use by another workspace).\n"
      name local_port;
    Printf.printf "           See %s for details.\n" lf;
    if tail <> "" then
      Printf.printf "           Last log lines:\n             %s\n"
        (String.concat "\n             " (String.split_on_char '\n' tail));
    Printf.printf "           Run: kill $(lsof -ti:%d) && sun up\n%!" local_port
  end;
  alive

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

  (try
    List.iter (fun (spec : Sun_cli_deployment_plan.service_spec) ->
      (* push_image is the host-accessible URL used for docker build/push and
         shown in dry-run output — it matches what actually gets written into the
         registry.  spec.image is the in-cluster URL baked into the manifest. *)
      let push_image = Sun_cli_deployment_plan.image_ref
        ~registry:push_registry ~workspace
        ~k8s_name:spec.k8s_name ~tag:sha in
      let repo_dir   = spec.source_dir in
      let dockerfile = Printf.sprintf "%s/%s/Dockerfile" repo_root repo_dir in

      Printf.printf "[%s] %s/%s\n%!" (prim_label
        (match spec.primitive with
         | Sun_cli_deployment_plan.Svc    -> Svc
         | Sun_cli_deployment_plan.Worker -> Worker
         | Sun_cli_deployment_plan.Fn     -> Fn))
        spec.domain spec.source_name;

      if not dry_run then begin
        Printf.printf "  compiling...\n%!";
        let build_cmd = Printf.sprintf
          "(cd %s && eval $(opam env) && dune build %s/bin/main.exe)"
          repo_root repo_dir in
        if run_cmd ~echo:false build_cmd <> 0 then
          raise (Deploy_failed (Printf.sprintf "dune build failed: %s" repo_dir));
        Printf.printf "  packaging %s...\n%!" push_image;
        let docker_cmd = Printf.sprintf "docker build -t %s -f %s %s"
          (Filename.quote push_image) (Filename.quote dockerfile) (Filename.quote repo_root) in
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
           if not (port_forward_running ~service:spec.k8s_name spec.k8s_name) then
             start_port_forward ~name:spec.k8s_name ~namespace:spec.namespace
               ~service:spec.k8s_name ~local_port ~remote_port:80;
           let pf_alive = check_port_forward_liveness ~name:spec.k8s_name ~local_port in
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
    Printf.eprintf "\nerror: %s\n" msg;
    exit 1);

  if not dry_run then begin
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
