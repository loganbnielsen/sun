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

let port_forward_running ~service name =
  let pf = pid_file name in
  if Sys.file_exists pf then begin
    let ic = open_in pf in
    let pid_s = String.trim (In_channel.input_all ic) in
    close_in ic;
    try
      let pid = int_of_string pid_s in
      let alive = Sys.command (Printf.sprintf "kill -0 %d 2>/dev/null" pid) = 0 in
      let args = if alive then read_cmdline pid else "" in
      let ok = alive
        && contains args "kubectl port-forward"
        && contains args ("svc/" ^ service)
      in
      if not ok then (try Sys.remove pf with _ -> ());
      ok
    with _ ->
      (try Sys.remove pf with _ -> ());
      false
  end else false

let log_file name = Printf.sprintf "/tmp/sun-pf-%s.log" name

let start_port_forward ~name ~namespace ~service ~local_port ~remote_port =
  ensure_state_dir ();
  let script = Printf.sprintf
    "kubectl port-forward -n %s svc/%s %d:%d </dev/null > %s 2>&1 & echo $! > %s"
    (Filename.quote namespace)
    (Filename.quote service)
    local_port remote_port
    (Filename.quote (log_file name))
    (Filename.quote (pid_file name))
  in
  let cmd = Printf.sprintf
    "setsid sh -c %s"
    (Filename.quote script)
  in
  ignore (run_cmd ~echo:false cmd)

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

(* ── Pipeline ────────────────────────────────────────────────────────────── *)

let run filter_path dry_run tag =
  let workspace = workspace_name () in
  let sha       = match tag with Some t -> t | None -> git_sha () in
  let services  = discover_services ~filter_path in
  let repo_root = find_repo_root () in
  let pf_failed = ref false in

  if services = [] then begin
    Printf.eprintf "No services found in app/ with a Dockerfile.\n";
    exit 1
  end;

  (* Pre-flight: POSTGRES_URL must be set in live mode so we never apply an
     empty credential to the cluster.  Dry-run is exempt — it only prints YAML. *)
  if not dry_run then begin
    match Sys.getenv_opt "POSTGRES_URL" with
    | None | Some "" ->
      Printf.eprintf
        "error: POSTGRES_URL is not set.\n\
         Set it in your environment before running 'sun up':\n\
         \  export POSTGRES_URL=postgresql://user:pass@host:5432/dbname\n";
      exit 1
    | Some _ -> ()
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

let cmd =
  Cmd.v
    (Cmd.info "up"
       ~doc:"Build images, synthesize k8s manifests, and deploy to the cluster")
    Term.(const run $ path_arg $ dry_run_flag $ tag_arg)
