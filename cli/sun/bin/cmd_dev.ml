open Cmdliner
open Sun_cli_manifest

(* ── Shell helpers ───────────────────────────────────────────────────────── *)

let run_cmd ?(echo = true) cmd = Sun_cli_process.run_shell ~echo cmd

let cmd_ok cmd = run_cmd ~echo:false cmd = 0

let check_tool name install_url =
  Sun_cli_process.check_tool name ~install_url

let require_tools () =
  check_tool "k3d"     "https://k3d.io/";
  check_tool "helm"    "https://helm.sh/";
  check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/"

(* ── State file ─────────────────────────────────────────────────────────── *)

let state_dir =
  (* Use an absolute path so all sun dev up/down calls share state regardless
     of cwd.  Relative ".sun" meant cross-session port-forwards couldn't be
     cleaned up if the user ran from a different directory. *)
  match Sys.getenv_opt "XDG_DATA_HOME" with
  | Some d -> Filename.concat d "sun"
  | None ->
    match Sys.getenv_opt "HOME" with
    | Some h -> Filename.concat h ".local/share/sun"
    | None   -> Filename.concat (Sys.getcwd ()) ".sun"

let cluster_name = "sun-local"
let registry_port = 5000

let ensure_state_dir () =
  ignore (Sun_cli_process.exec ~echo:false "mkdir" ["-p"; state_dir])

let pid_file name = Printf.sprintf "%s/pf-%s.pid" state_dir name

let write_pid name pid =
  let oc = open_out (pid_file name) in
  Printf.fprintf oc "%d\n" pid;
  close_out oc

(* ── Port-forward management ─────────────────────────────────────────────── *)

type pf_spec = {
  name        : string;
  namespace   : string;
  (* Full kubectl resource target, e.g. "svc/redpanda" or "pod/redpanda-0". *)
  target      : string;
  local_port  : int;
  remote_port : int;
}

let start_port_forward pf =
  Printf.printf "  port-forward  %-12s localhost:%d → %s/%s:%d\n%!"
    pf.name pf.local_port pf.namespace pf.target pf.remote_port;
  let log_file = Printf.sprintf "/tmp/sun-pf-%s.log" pf.name in
  let script_file = Printf.sprintf "/tmp/sun-pf-%s.sh" pf.name in
  let content = Printf.sprintf
    "#!/bin/sh\necho $$ > %s\nwhile true; do\n  kubectl port-forward -n %s %s %d:%d </dev/null >> %s 2>&1\n  sleep 1\ndone\n"
    (Filename.quote (pid_file pf.name))
    (Filename.quote pf.namespace) (Filename.quote pf.target)
    pf.local_port pf.remote_port
    (Filename.quote log_file)
  in
  let oc = open_out script_file in
  output_string oc content;
  close_out oc;
  ignore (Sun_cli_process.run_shell ~echo:false (Printf.sprintf "chmod +x %s" (Filename.quote script_file))); (* shell: simple chmod via run_shell *)
  ignore (run_cmd ~echo:false
    (Printf.sprintf "setsid %s </dev/null >/dev/null 2>&1 &" (Filename.quote script_file)))

let stop_port_forwards () =
  if Sys.file_exists state_dir then begin
    let entries = try Sys.readdir state_dir with _ -> [||] in
    Array.iter (fun f ->
      if Filename.check_suffix f ".pid" then begin
        let path = Printf.sprintf "%s/%s" state_dir f in
        (try
          let ic = open_in path in
          let pid_s = String.trim (In_channel.input_all ic) in
          close_in ic;
          (match int_of_string_opt pid_s with
           | Some pid -> ignore (run_cmd ~echo:false (Printf.sprintf "kill %d 2>/dev/null" pid)) (* shell: stderr redirection *)
           | None -> ());
          Sys.remove path
        with _ -> ())
      end
    ) entries
  end

(* ── Helm helpers ────────────────────────────────────────────────────────── *)

type set_val =
  | Val of string  (** --set key=val  (YAML-parsed; use for booleans and floats) *)
  | Str of string  (** --set-string key=val  (always treated as string, avoids int/float coercion) *)

let helm_install release chart ~namespace ?(values = []) () =
  let flag (k, v) = match v with
    | Val s -> Printf.sprintf "--set %s=%s" k s
    | Str s -> Printf.sprintf "--set-string %s=%s" k s
  in
  let cmd = String.concat " " (
    [ "helm upgrade --install"; release; chart ]
    @ [ "--namespace"; namespace; "--create-namespace" ]
    @ List.map flag values
    @ [ "--wait --timeout 3m" ]
  ) in
  run_cmd cmd

(* ── dev up ──────────────────────────────────────────────────────────────── *)

let dev_up () =
  require_tools ();
  ensure_state_dir ();
  (* Kill any stale port-forwards from previous sessions before starting fresh
     ones.  Without this, re-running dev up after a crash or cross-directory
     down would silently fail to bind ports while reporting success. *)
  stop_port_forwards ();

  (* 1. Cluster *)
  Printf.printf "\n[1/4] Provisioning cluster...\n%!";
  let cluster_exists =
    cmd_ok (Printf.sprintf "k3d cluster get %s >/dev/null 2>&1" cluster_name)
  in
  if cluster_exists then
    Printf.printf "  cluster %s already exists, skipping\n%!" cluster_name
  else begin
    let rc = run_cmd (Printf.sprintf
      "k3d cluster create %s --registry-create sun-registry:%d"
      cluster_name registry_port)
    in
    if rc <> 0 then (Printf.eprintf "error: cluster creation failed\n"; exit 1)
  end;

  (* 2. Scan *)
  Printf.printf "\n[2/4] Scanning workspace...\n%!";
  let req = Sun_cli_workspace.scan ~dir:"." in
  Printf.printf "  kafka=%-5b  postgres=%-5b  loki=%-5b  prometheus=%b\n%!"
    req.kafka req.postgres req.loki req.prometheus;

  (* 3. Infra *)
  Printf.printf "\n[3/4] Deploying infra...\n%!";
  let need_any = req.kafka || req.postgres || req.loki || req.prometheus in
  if need_any then begin
    ignore (run_cmd "helm repo add redpanda              https://charts.redpanda.com 2>/dev/null");
    ignore (run_cmd "helm repo add grafana               https://grafana.github.io/helm-charts 2>/dev/null");
    ignore (run_cmd "helm repo add bitnami               https://charts.bitnami.com/bitnami 2>/dev/null");
    ignore (run_cmd "helm repo add prometheus-community  https://prometheus-community.github.io/helm-charts 2>/dev/null");
    ignore (run_cmd "helm repo update");
  end;

  if req.kafka then begin
    Printf.printf "\n  Installing Redpanda...\n%!";
    let rc = helm_install "redpanda" "redpanda/redpanda" ~namespace:"redpanda"
      ~values:[
        ("statefulset.replicas",          Val "1");
        ("resources.cpu.cores",           Str "1.5");  (* chart rejects int64 *)
        ("storage.persistentVolume.size", Val "1Gi");
        ("tls.enabled",                   Val "false");
        (* Configure an external Kafka listener that advertises localhost:9092.
           librdkafka bootstraps via the port-forward (localhost:9092→9094), gets
           metadata back saying "reach me at localhost:9092", and reconnects
           successfully — avoiding the internal cluster DNS that is unresolvable
           from outside k3d. *)
        ("external.enabled",                                    Val "true");
        ("external.service.enabled",                            Val "false");
        ("external.addresses[0]",                               Str "localhost");
        ("listeners.kafka.external.default.advertisedPorts[0]", Val "9092");
      ] ()
    in
    if rc <> 0 then (Printf.eprintf "error: Redpanda install failed\n"; exit 1)
  end;

  if req.postgres then begin
    Printf.printf "\n  Installing PostgreSQL...\n%!";
    let rc = helm_install "postgresql" "bitnami/postgresql" ~namespace:"postgresql"
      ~values:[
        ("auth.postgresPassword", Str "dev");
        ("auth.database",         Str "dev");
      ] ()
    in
    if rc <> 0 then (Printf.eprintf "error: PostgreSQL install failed\n"; exit 1)
  end;

  let need_grafana = req.loki || req.prometheus in
  if req.loki then begin
    Printf.printf "\n  Installing Loki...\n%!";
    let grafana_val = if need_grafana then "true" else "false" in
    let rc = helm_install "loki" "grafana/loki-stack" ~namespace:"monitoring"
      ~values:[("grafana.enabled", Val grafana_val)] ()
    in
    if rc <> 0 then (Printf.eprintf "error: Loki install failed\n"; exit 1)
  end;

  if req.prometheus then begin
    Printf.printf "\n  Installing Prometheus...\n%!";
    (* prometheus-community/prometheus (not kube-prometheus-stack) — lighter weight for dev;
       includes server, alertmanager, pushgateway, kube-state-metrics, node-exporter *)
    let rc = helm_install "prometheus" "prometheus-community/prometheus"
      ~namespace:"monitoring"
      ~values:[
        ("server.persistentVolume.enabled", Val "false");
        ("prometheus-node-exporter.enabled", Val "false");
      ] ()
    in
    if rc <> 0 then (Printf.eprintf "error: Prometheus install failed\n"; exit 1)
  end;

  (* 4. Port-forwards *)
  Printf.printf "\n[4/4] Starting port-forwards...\n%!";
  ignore (Sun_cli_process.run_shell ~echo:false "sleep 2");  (* shell: brief pause for service endpoints to settle *)

  if req.kafka then begin
    (* Port-forward to the pod (not svc) so we reach the external listener on
       9094.  The Redpanda headless service only exposes the internal port 9093;
       9094 is only reachable via the pod directly. *)
    start_port_forward { name = "kafka"; namespace = "redpanda";
                         target = "pod/redpanda-0"; local_port = 9092; remote_port = 9094 };
    start_port_forward { name = "schema-registry"; namespace = "redpanda";
                         target = "svc/redpanda"; local_port = 8081; remote_port = 8081 };
  end;
  if req.postgres then
    start_port_forward { name = "postgres"; namespace = "postgresql";
                         target = "svc/postgresql"; local_port = 5432; remote_port = 5432 };
  if req.loki then
    start_port_forward { name = "loki"; namespace = "monitoring";
                         target = "svc/loki"; local_port = 3100; remote_port = 3100 };
  if need_grafana then
    start_port_forward { name = "grafana"; namespace = "monitoring";
                         target = "svc/loki-grafana"; local_port = 3000; remote_port = 80 };
  if req.prometheus then
    start_port_forward { name = "pushgateway"; namespace = "monitoring";
                         target = "svc/prometheus-prometheus-pushgateway";
                         local_port = 9091; remote_port = 9091 };

  (* Summary *)
  Printf.printf "\n";
  Printf.printf "  cluster      ✓  %s\n" cluster_name;
  Printf.printf "  registry     ✓  localhost:%d\n" registry_port;
  if req.kafka    then Printf.printf "  kafka        ✓  localhost:9092  (port-forwarded)\n";
  if req.kafka    then Printf.printf "  schema-reg   ✓  http://localhost:8081\n";
  if req.postgres then Printf.printf "  postgres     ✓  postgresql://postgres:dev@localhost:5432/dev  (port-forwarded)\n";
  if req.loki     then Printf.printf "  loki         ✓  http://localhost:3100  (port-forwarded)\n";
  if need_grafana then Printf.printf "  grafana      ✓  http://localhost:3000  (port-forwarded)\n";
  if req.prometheus then Printf.printf "  pushgateway  ✓  http://localhost:9091  (port-forwarded)\n";
  Printf.printf "\n"

(* ── dev down ────────────────────────────────────────────────────────────── *)

let dev_down delete_cluster =
  check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/";
  Printf.printf "Stopping port-forwards...\n%!";
  stop_port_forwards ();
  if delete_cluster then begin
    check_tool "k3d" "https://k3d.io/";
    Printf.printf "Deleting cluster %s...\n%!" cluster_name;
    ignore (run_cmd (Printf.sprintf "k3d cluster delete %s" cluster_name))
  end else
    Printf.printf "Port-forwards stopped. Cluster %s is still running.\n" cluster_name

(* ── dev status ──────────────────────────────────────────────────────────── *)

let dev_status () =
  check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/";
  let cluster_running =
    cmd_ok (Printf.sprintf "k3d cluster get %s >/dev/null 2>&1" cluster_name)
  in
  Printf.printf "\nCluster:  %s  %s\n" cluster_name
    (if cluster_running then "✓ running" else "✗ not found");
  if cluster_running then begin
    Printf.printf "\nPods:\n%!";
    ignore (run_cmd ~echo:false "kubectl get pods -A 2>/dev/null");
    Printf.printf "\nPort-forwards:\n%!";
    if Sys.file_exists state_dir then begin
      let entries = try Sys.readdir state_dir with _ -> [||] in
      let pids = Array.to_list entries
        |> List.filter (fun f -> Filename.check_suffix f ".pid")
      in
      if pids = [] then
        Printf.printf "  none\n"
      else
        List.iter (fun f ->
          let name = Filename.chop_suffix f ".pid" in
          let path = Printf.sprintf "%s/%s" state_dir f in
          let pid_s = try
            let ic = open_in path in
            let s = String.trim (In_channel.input_all ic) in
            close_in ic; s
          with _ -> "?"
          in
          Printf.printf "  %-12s  pid %s\n" name pid_s
        ) pids
    end
  end;
  Printf.printf "\n"

(* ── dev run ─────────────────────────────────────────────────────────────── *)

(** Dev-local environment variables matching the port-forwards started by
    [sun dev up].  These mirror the cluster-internal addresses that [sun up]
    injects, but rewritten to localhost so [dune exec] processes on the host
    can reach the forwarded ports. *)
let dev_env_vars = [
  "KAFKA_BROKERS",       "localhost:9092";
  "SCHEMA_REGISTRY_URL", "http://localhost:8081";
  "REDPANDA_ADMIN_URL",  "http://localhost:9644";
  "POSTGRES_URL",        "postgresql://postgres:dev@localhost:5432/dev";
  "LOKI_URL",            "http://localhost:3100";
  "PUSHGATEWAY_URL",     "http://localhost:9091";
  "KAFKA_SECURITY_PROTOCOL", "Plaintext";
]

(** Build the env array for [Unix.create_process_env] by merging [dev_env_vars]
    on top of the current process environment.  Variables already set in the
    environment are overridden by the dev defaults so that every service always
    reaches the local broker/database regardless of whatever the shell has. *)
let build_env () =
  (* Start with current environment *)
  let current = Unix.environment () in
  (* Build a table of dev keys for quick membership test *)
  let dev_keys = List.map fst dev_env_vars in
  (* Filter out current env entries that we will override *)
  let filtered = Array.to_list current
    |> List.filter (fun entry ->
      let key = match String.index_opt entry '=' with
        | Some i -> String.sub entry 0 i
        | None   -> entry
      in
      not (List.mem key dev_keys))
  in
  (* Append dev vars *)
  let extras = List.map (fun (k, v) -> k ^ "=" ^ v) dev_env_vars in
  Array.of_list (filtered @ extras)

(** Read lines from [fd] and write them to stdout, prefixed with [label].
    Returns when EOF is reached (the child process closed the pipe end). *)
let prefix_lines_thread fd label =
  let ic = Unix.in_channel_of_descr fd in
  (try
    while true do
      let line = input_line ic in
      Printf.printf "[%s] %s\n%!" label line
    done
  with End_of_file | Sys_error _ -> ());
  (try Unix.close fd with _ -> ())

type child = {
  pid    : int;
  label  : string;
}

let dev_run workspace_dir filter_path =
  let dir = match workspace_dir with Some d -> d | None -> "." in
  (* Change to workspace dir if given explicitly so discover_services works *)
  (match workspace_dir with
   | Some d -> Unix.chdir d
   | None   -> ());
  let services = discover_services ~filter_path in
  if services = [] then begin
    Printf.eprintf "error: no Sun services found. ";
    Printf.eprintf "Expected app/<domain>/<name>_{svc,worker,fn}/ directories with a Dockerfile.\n";
    exit 1
  end;

  Printf.printf "\n  Starting %d service(s) from %s\n" (List.length services) dir;
  List.iter (fun svc ->
    Printf.printf "    [%s] %s/%s → %s/bin/main.exe\n"
      (prim_label svc.prim) svc.domain svc.name svc.dir
  ) services;
  Printf.printf "\n%!";

  (* Build all services first with a single dune invocation so that parallel
     dune exec calls below don't fight over the _build/.lock file. *)
  Printf.printf "  Building...\n%!";
  let build_targets = List.map (fun (svc : Sun_cli_manifest.service) ->
    svc.dir ^ "/bin/main.exe"
  ) services in
  let opam_eval = "eval $(opam env 2>/dev/null) 2>/dev/null; " in
  let build_cmd = Printf.sprintf "%sdune build %s"
    opam_eval
    (String.concat " " (List.map Filename.quote build_targets))
  in
  let build_rc = Sun_cli_process.run_shell ~echo:false build_cmd in (* shell: opam env eval + dune build in one command *)
  if build_rc <> 0 then begin
    Printf.eprintf "error: dune build failed (exit %d)\n" build_rc;
    exit 1
  end;
  Printf.printf "  Build done.\n\n%!";

  let env = build_env () in

  (* Spawn each service by running the pre-built executable from _build/default/.
     This avoids concurrent dune exec calls fighting over the build lock. *)
  let children = List.filter_map (fun (svc : Sun_cli_manifest.service) ->
    let label = svc.domain ^ "/" ^ svc.name in
    let exe_path = "_build/default/" ^ svc.dir ^ "/bin/main.exe" in
    let cmd_str = Filename.quote exe_path in
    (* Create a pipe: child writes to pipe_write, we read from pipe_read *)
    let (pipe_read, pipe_write) = Unix.pipe () in
    (try
      let pid = Unix.create_process_env
        "sh" [| "sh"; "-c"; cmd_str |] env
        Unix.stdin pipe_write pipe_write
      in
      Unix.close pipe_write;
      (* Spawn a thread to forward prefixed output *)
      let _t = Thread.create (fun () -> prefix_lines_thread pipe_read label) () in
      Some { pid; label }
    with Unix.Unix_error (e, fn, _) ->
      Unix.close pipe_read;
      Unix.close pipe_write;
      Printf.eprintf "error: failed to spawn [%s]: %s in %s\n" label (Unix.error_message e) fn;
      None)
  ) services in

  if children = [] then begin
    Printf.eprintf "error: no services could be started\n";
    exit 1
  end;

  Printf.printf "  Services running — press Ctrl-C to stop all.\n\n%!";

  (* On SIGINT (Ctrl-C), kill every child before exiting *)
  let kill_all () =
    Printf.printf "\n  Stopping services...\n%!";
    List.iter (fun c ->
      (try Unix.kill c.pid Sys.sigterm with _ -> ())
    ) children;
    (* Brief grace period, then SIGKILL *)
    Unix.sleepf 0.5;
    List.iter (fun c ->
      (try Unix.kill c.pid Sys.sigkill with _ -> ())
    ) children
  in
  Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ ->
    kill_all ();
    exit 130));

  (* Wait for children in any-exit order so an early crash is reported immediately *)
  let by_pid = Hashtbl.create 8 in
  List.iter (fun c -> Hashtbl.replace by_pid c.pid c) children;
  let remaining = ref (Hashtbl.length by_pid) in
  while !remaining > 0 do
    (try
      let (pid, status) = Unix.wait () in
      decr remaining;
      (match Hashtbl.find_opt by_pid pid with
       | None -> ()
       | Some c ->
         (match status with
          | Unix.WEXITED 0   -> ()
          | Unix.WEXITED n   -> Printf.eprintf "[%s] exited with code %d\n%!" c.label n
          | Unix.WSIGNALED _ -> ()
          | Unix.WSTOPPED  _ -> ()))
    with Unix.Unix_error _ -> remaining := 0)
  done

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let up_cmd =
  Cmd.v
    (Cmd.info "up"
       ~doc:"Provision local k3d cluster and deploy all required infra via Helm")
    Term.(const dev_up $ const ())

let down_cmd =
  let cluster_flag =
    Arg.(value & flag & info ["cluster"] ~doc:"Also delete the k3d cluster")
  in
  Cmd.v
    (Cmd.info "down"
       ~doc:"Stop port-forwards (and optionally delete the cluster)")
    Term.(const dev_down $ cluster_flag)

let status_cmd =
  Cmd.v
    (Cmd.info "status"
       ~doc:"Show infra pod health and registered port-forwards")
    Term.(const dev_status $ const ())

let run_workspace_arg =
  Arg.(value & opt (some string) None &
       info ["workspace"; "C"]
         ~docv:"DIR"
         ~doc:"Workspace root directory (default: current directory)")

let run_path_arg =
  Arg.(value & pos 0 (some string) None &
       info []
         ~docv:"PATH"
         ~doc:"Restrict to a single service path (default: all services)")

let run_cmd =
  Cmd.v
    (Cmd.info "run"
       ~doc:"Start all workspace services locally using dune exec with dev env vars")
    Term.(const dev_run $ run_workspace_arg $ run_path_arg)

let cmd =
  Cmd.group
    (Cmd.info "dev" ~doc:"Manage the local k3d development cluster")
    [ up_cmd; down_cmd; status_cmd; run_cmd ]
