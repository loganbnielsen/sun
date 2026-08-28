open Cmdliner
open Sun_cli_manifest
open Sun_cli_helm

let check_tool name install_url =
  match Sun_cli_process.run (Sun_cli_process.cmd ["which"; name]) with
  | Ok r when r.Sun_cli_process.exit_code = 0 -> ()
  | _ ->
    Printf.eprintf "error: %S not found in PATH.\n" name;
    Printf.eprintf "  Install: %s\n" install_url;
    exit 1

let require_tools () =
  check_tool "k3d"     "https://k3d.io/";
  check_tool "helm"    "https://helm.sh/";
  check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/"

(* ── State file ─────────────────────────────────────────────────────────── *)

let cluster_name = "sun-local"
let registry_port = 5000

(* ── Helm helpers ────────────────────────────────────────────────────────── *)

let helm_install release chart ~namespace ?(values = []) () =
  match upgrade_install ~release ~chart ~namespace ~values () with
  | Ok r -> r.Sun_cli_process.exit_code
  | Error _ -> 1

(* ── dev up ──────────────────────────────────────────────────────────────── *)

let dev_up () =
  require_tools ();
  Sun_cli_state.ensure ();
  (* Kill stale port-forwards from previous sessions, else re-running after a
     crash silently fails to bind ports while reporting success. *)
  Sun_cli_port_forward.stop_all ();

  (* 1. Cluster *)
  Printf.printf "\n[1/4] Provisioning cluster...\n%!";
  let cluster_exists =
    match Sun_cli_process.run
        (Sun_cli_process.cmd ["k3d"; "cluster"; "get"; cluster_name]) with
    | Ok r -> r.Sun_cli_process.exit_code = 0
    | Error _ -> false
  in
  if cluster_exists then
    Printf.printf "  cluster %s already exists, skipping\n%!" cluster_name
  else begin
    let rc =
      match Sun_cli_process.run ~echo:true
          (Sun_cli_process.cmd
             ["k3d"; "cluster"; "create"; cluster_name;
              "--registry-create"; Printf.sprintf "sun-registry:%d" registry_port]) with
      | Ok r -> r.Sun_cli_process.exit_code
      | Error _ -> 1
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
    ignore (Sun_cli_helm.repo_add ~name:"redpanda"             ~url:"https://charts.redpanda.com");
    ignore (Sun_cli_helm.repo_add ~name:"grafana"              ~url:"https://grafana.github.io/helm-charts");
    ignore (Sun_cli_helm.repo_add ~name:"bitnami"              ~url:"https://charts.bitnami.com/bitnami");
    ignore (Sun_cli_helm.repo_add ~name:"prometheus-community" ~url:"https://prometheus-community.github.io/helm-charts");
    ignore (Sun_cli_helm.repo_update ());
  end;

  if req.kafka then begin
    Printf.printf "\n  Installing Redpanda...\n%!";
    let rc = helm_install "redpanda" "redpanda/redpanda" ~namespace:"redpanda"
      ~values:[
        ("statefulset.replicas",          Float 1.);
        ("resources.cpu.cores",           Str "1.5");  (* chart rejects int64 *)
        ("storage.persistentVolume.size", Str "1Gi");
        ("tls.enabled",                   Bool false);
        (* Advertise localhost:9092 so librdkafka reconnects to the port-forward
           after bootstrap instead of the unresolvable internal cluster DNS. *)
        ("external.enabled",                                    Bool true);
        ("external.service.enabled",                            Bool false);
        ("external.addresses[0]",                               Str "localhost");
        ("listeners.kafka.external.default.advertisedPorts[0]", Float 9092.);
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
    let rc = helm_install "loki" "grafana/loki-stack" ~namespace:"monitoring"
      ~values:[("grafana.enabled", Bool need_grafana)] ()
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
        ("server.persistentVolume.enabled",  Bool false);
        ("prometheus-node-exporter.enabled", Bool false);
      ] ()
    in
    if rc <> 0 then (Printf.eprintf "error: Prometheus install failed\n"; exit 1)
  end;

  (* 4. Port-forwards *)
  Printf.printf "\n[4/4] Starting port-forwards...\n%!";
  ignore (Sys.command "sleep 2");  (* brief pause for service endpoints to settle *)

  let pf pf_spec =
    Printf.printf "  port-forward  %-14s localhost:%d → %s/%s:%d\n%!"
      pf_spec.Sun_cli_port_forward.name pf_spec.local_port
      pf_spec.namespace pf_spec.target pf_spec.remote_port;
    Sun_cli_port_forward.start pf_spec
  in
  if req.kafka then begin
    (* Target the pod, not svc: the headless service only exposes the internal
       port 9093, and the external listener on 9094 is pod-only. *)
    pf { name = "kafka"; namespace = "redpanda";
         target = "pod/redpanda-0"; local_port = 9092; remote_port = 9094 };
    pf { name = "schema-registry"; namespace = "redpanda";
         target = "svc/redpanda"; local_port = 8081; remote_port = 8081 };
  end;
  if req.postgres then
    pf { name = "postgres"; namespace = "postgresql";
         target = "svc/postgresql"; local_port = 5432; remote_port = 5432 };
  if req.loki then
    pf { name = "loki"; namespace = "monitoring";
         target = "svc/loki"; local_port = 3100; remote_port = 3100 };
  if need_grafana then
    pf { name = "grafana"; namespace = "monitoring";
         target = "svc/loki-grafana"; local_port = 3000; remote_port = 80 };
  if req.prometheus then
    pf { name = "pushgateway"; namespace = "monitoring";
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
  Sun_cli_port_forward.stop_all ();
  if delete_cluster then begin
    check_tool "k3d" "https://k3d.io/";
    Printf.printf "Deleting cluster %s...\n%!" cluster_name;
    ignore (Sun_cli_process.run (Sun_cli_process.cmd ["k3d"; "cluster"; "delete"; cluster_name]))
  end else
    Printf.printf "Port-forwards stopped. Cluster %s is still running.\n" cluster_name

(* ── dev status ──────────────────────────────────────────────────────────── *)

let dev_status () =
  check_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/";
  let cluster_running =
    match Sun_cli_process.run
        (Sun_cli_process.cmd ["k3d"; "cluster"; "get"; cluster_name]) with
    | Ok r -> r.Sun_cli_process.exit_code = 0
    | Error _ -> false
  in
  Printf.printf "\nCluster:  %s  %s\n" cluster_name
    (if cluster_running then "✓ running" else "✗ not found");
  if cluster_running then begin
    Printf.printf "\nPods:\n%!";
    (match Sun_cli_process.run (Sun_cli_process.cmd ["kubectl"; "get"; "pods"; "-A"]) with
     | Ok r -> print_string r.Sun_cli_process.stdout; print_char '\n'
     | Error _ -> ());
    Printf.printf "\nPort-forwards:\n%!";
    if Sys.file_exists Sun_cli_state.dir then begin
      let entries = try Sys.readdir Sun_cli_state.dir with _ -> [||] in
      let pids = Array.to_list entries
        |> List.filter (fun f -> Filename.check_suffix f ".pid")
      in
      if pids = [] then
        Printf.printf "  none\n"
      else
        List.iter (fun f ->
          let name = Filename.chop_suffix f ".pid" in
          let path = Printf.sprintf "%s/%s" Sun_cli_state.dir f in
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

(** Dev-local addresses matching the port-forwards from [sun dev up], mirroring
    the cluster-internal addresses [sun up] injects but rewritten to localhost. *)
let dev_env_vars = [
  "KAFKA_BROKERS",       "localhost:9092";
  "SCHEMA_REGISTRY_URL", "http://localhost:8081";
  "REDPANDA_ADMIN_URL",  "http://localhost:9644";
  "POSTGRES_URL",        "postgresql://postgres:dev@localhost:5432/dev";
  "LOKI_URL",            "http://localhost:3100";
  "PUSHGATEWAY_URL",     "http://localhost:9091";
  "KAFKA_SECURITY_PROTOCOL", "Plaintext";
]

(** [dev_env_vars] merged on top of the current environment, overriding any
    matching keys so every service reaches the local broker/database. *)
let build_env () =
  let current = Unix.environment () in
  let dev_keys = List.map fst dev_env_vars in
  let filtered = Array.to_list current
    |> List.filter (fun entry ->
      let key = match String.index_opt entry '=' with
        | Some i -> String.sub entry 0 i
        | None   -> entry
      in
      not (List.mem key dev_keys))
  in
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
  let build_rc = Sys.command build_cmd in
  if build_rc <> 0 then begin
    Printf.eprintf "error: dune build failed (exit %d)\n" build_rc;
    exit 1
  end;
  Printf.printf "  Build done.\n\n%!";

  let env = build_env () in

  (* Run the pre-built executable directly, avoiding dune exec lock contention. *)
  let children = List.filter_map (fun (svc : Sun_cli_manifest.service) ->
    let label = svc.domain ^ "/" ^ svc.name in
    let exe_path = "_build/default/" ^ svc.dir ^ "/bin/main.exe" in
    let cmd_str = Filename.quote exe_path in
    let (pipe_read, pipe_write) = Unix.pipe () in
    (try
      let pid = Unix.create_process_env
        "sh" [| "sh"; "-c"; cmd_str |] env
        Unix.stdin pipe_write pipe_write
      in
      Unix.close pipe_write;
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

let run_subcmd =
  Cmd.v
    (Cmd.info "run"
       ~doc:"Start all workspace services locally using dune exec with dev env vars")
    Term.(const dev_run $ run_workspace_arg $ run_path_arg)

let cmd =
  Cmd.group
    (Cmd.info "dev" ~doc:"Manage the local k3d development cluster")
    [ up_cmd; down_cmd; status_cmd; run_subcmd ]
