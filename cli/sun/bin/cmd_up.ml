open Cmdliner
open Sun_cli_manifest


(* ── Port-forward helpers (mirrors cmd_dev.ml) ───────────────────────────── *)

let state_dir =
  (* Use an absolute path so sun up/down work regardless of cwd — mirrors cmd_dev.ml. *)
  match Sys.getenv_opt "XDG_DATA_HOME" with
  | Some d -> Filename.concat d "sun"
  | None ->
    match Sys.getenv_opt "HOME" with
    | Some h -> Filename.concat h ".local/share/sun"
    | None   -> Filename.concat (Sys.getcwd ()) ".sun"

let ensure_state_dir () =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote state_dir)))

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
  Sun_cli_shell.with_temp_file "sun-ps-" ".tmp" (fun tmp ->
    ignore (Sys.command (Printf.sprintf "ps -p %d -o args= > %s 2>/dev/null" pid (Filename.quote tmp)));
    let ic = open_in tmp in
    let s = String.trim (In_channel.input_all ic) in
    close_in ic;
    s)

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
  ignore (Sun_cli_shell.run_cmd ~echo:false
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

(** Extract the first occurrence of [prefix] followed by decimal digits in
    [s], returning the digits as a string.  Returns [""] if not found. *)
let extract_after_prefix s prefix =
  let pl = String.length prefix and sl = String.length s in
  let rec go i =
    if i + pl > sl then ""
    else if String.sub s i pl = prefix then begin
      (* Collect digits after the prefix *)
      let j = ref (i + pl) in
      while !j < sl && s.[!j] >= '0' && s.[!j] <= '9' do incr j done;
      if !j > i + pl then String.sub s (i + pl) (!j - (i + pl))
      else go (i + 1)
    end
    else go (i + 1)
  in
  go 0

(** Find the PID that owns [local_port] using [ss].  Returns [Some pid] or
    [None] if the port is free / the lookup fails. *)
let pid_owning_port local_port =
  (* ss -tlnp prints lines like:
       LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:* users:(("kubectl",pid=12345,...))
     We grab the users field and extract the pid. *)
  Sun_cli_shell.with_temp_file "sun-ss-" ".tmp" (fun tmp ->
    ignore (Sys.command
      (Printf.sprintf "ss -tlnp 'sport = :%d' > %s 2>/dev/null" local_port (Filename.quote tmp)));
    let ic = open_in tmp in
    let content = In_channel.input_all ic in
    close_in ic;
    (* Extract pid=<N> from the users:((...)) field — no Str dependency needed *)
    let digits = extract_after_prefix content "pid=" in
    if digits = "" then None
    else (try Some (int_of_string digits) with _ -> None))

(** Parse a null-delimited /proc/<pid>/cmdline into a string list. *)
let read_proc_cmdline pid =
  let path = Printf.sprintf "/proc/%d/cmdline" pid in
  try
    let ic = open_in path in
    let raw = In_channel.input_all ic in
    close_in ic;
    (* cmdline args are NUL-separated; split on NUL and filter empties *)
    List.filter (fun s -> s <> "") (String.split_on_char '\x00' raw)
  with _ ->
    (* Fall back to ps if /proc is unavailable *)
    Sun_cli_shell.with_temp_file "sun-ps-" ".tmp" (fun tmp ->
      ignore (Sys.command
        (Printf.sprintf "ps -p %d -o args= > %s 2>/dev/null" pid (Filename.quote tmp)));
      let ic = open_in tmp in
      let s = String.trim (In_channel.input_all ic) in
      close_in ic;
      String.split_on_char ' ' s)

(** Parse the arg list from a [kubectl port-forward -n <ns> svc/<svc> ...]
    invocation.  Returns [(namespace, service)] or raises [Not_found]. *)
let parse_kubectl_pf_args args =
  (* Find -n flag value *)
  let rec find_ns = function
    | "-n" :: ns :: _ -> ns
    | _ :: rest -> find_ns rest
    | [] -> raise Not_found
  in
  let ns = find_ns args in
  (* Find the resource argument, which matches svc/<name> or deployment/<name> *)
  let svc =
    List.find_map (fun a ->
      if String.length a > 4 && String.sub a 0 4 = "svc/" then
        Some (String.sub a 4 (String.length a - 4))
      else None
    ) args
  in
  match svc with
  | Some s -> (ns, s)
  | None -> raise Not_found

(** Check whether [local_port] is bound by a stale Sun-managed kubectl
    port-forward pointing at a different namespace or service than the one we
    are about to start.  Returns [Some (pid, old_namespace, old_service)] when
    a stale forward is detected, [None] otherwise. *)
let detect_stale_port_forward local_port target_namespace target_service =
  match pid_owning_port local_port with
  | None -> None
  | Some pid ->
    let args = read_proc_cmdline pid in
    (* Must be a kubectl invocation *)
    let is_kubectl =
      match args with
      | prog :: _ ->
        let base = Filename.basename prog in
        base = "kubectl" || base = "kubectl.exe"
      | [] -> false
    in
    if not is_kubectl then None
    else begin
      (* Must be a port-forward subcommand *)
      let has_pf = List.exists (fun a -> a = "port-forward") args in
      if not has_pf then None
      else begin
        match (try Some (parse_kubectl_pf_args args) with Not_found -> None) with
        | None -> None
        | Some (old_ns, old_svc) ->
          if old_ns <> target_namespace || old_svc <> target_service then
            Some (pid, old_ns, old_svc)
          else
            None
      end
    end

let wait_for_rollout ~namespace ~name =
  let cmd = Printf.sprintf
    "kubectl rollout status deployment/%s -n %s --timeout=60s"
    (Filename.quote name) (Filename.quote namespace)
  in
  Sun_cli_shell.run_cmd ~echo:false cmd

(* ── Workspace / git helpers ─────────────────────────────────────────────── *)

let workspace_name () = Filename.basename (Sys.getcwd ())

let git_sha () =
  let s = Sun_cli_shell.run_cmd_to_string "git rev-parse --short HEAD" in
  if s = "" then "dev" else s

let current_kube_context () =
  Sun_cli_shell.run_cmd_to_string "kubectl config current-context"

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
  Sun_cli_shell.with_temp_file "sun-groups-" ".txt" (fun path ->
    let cmd = Printf.sprintf
      "kubectl get configmap %s -n default \
       -o jsonpath='{.data.consumer_groups}' 2>/dev/null > %s"
      (Filename.quote name) (Filename.quote path)
    in
    if Sys.command cmd <> 0 then []
    else begin
      let ic = open_in path in
      let content = In_channel.input_all ic in
      close_in ic;
      String.split_on_char '\n' content
      |> List.map String.trim
      |> List.filter (fun s -> s <> "")
    end)

(* Persist the current consumer groups to the sun-deploy-state ConfigMap. *)
let save_deployed_groups workspace groups =
  let name = deploy_state_configmap_name workspace in
  let value = String.concat "\n" groups in
  let apply_json = Printf.sprintf
    {|{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"%s","namespace":"default"},"data":{"consumer_groups":"%s"}}|}
    (String.escaped name) (String.escaped value)
  in
  Sun_cli_shell.with_temp_file "sun-state-" ".json" (fun path ->
    let oc = open_out path in
    output_string oc apply_json;
    close_out oc;
    ignore (Sun_process.run_argv ~echo:false ["kubectl"; "apply"; "-f"; path]))

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
        if (Sun_process.run_argv ~echo:false
              ["docker"; "build"; "-t"; push_image; "-f"; dockerfile; ctx_dir]).exit_code <> 0 then
          raise (Deploy_failed (Printf.sprintf "docker build failed: %s" spec.source_dir));
        Printf.printf "  pushing...\n%!";
        if (Sun_process.run_argv ~echo:false ["docker"; "push"; push_image]).exit_code <> 0 then
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
           if not (port_forward_running ~service:spec.k8s_name spec.k8s_name) then begin
             (* Before binding the port, check whether a stale Sun-managed
                port-forward from a different workspace/namespace already owns
                it.  If so, kill it and print a notice.  We only kill kubectl
                processes — never unrelated processes. *)
             (match detect_stale_port_forward local_port spec.namespace spec.k8s_name with
              | Some (stale_pid, old_ns, old_svc) ->
                Printf.printf
                  "  [sun up] replacing stale port-forward for %s/%s on port %d\n%!"
                  old_ns old_svc local_port;
                (try Unix.kill stale_pid Sys.sigterm
                 with Unix.Unix_error _ -> ());
                (* Give the old process ~400 ms to release the port before we
                   start the new wrapper script. *)
                Unix.sleepf 0.4
              | None -> ());
             start_port_forward ~name:spec.k8s_name ~namespace:spec.namespace
               ~service:spec.k8s_name ~local_port ~remote_port:80
           end;
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
