open Cmdliner

let workspace_name () =
  (match Sun_cli_workspace.find_root ~dir:(Sys.getcwd ()) with
   | Some root -> Sys.chdir root
   | None -> ());
  Filename.basename (Sys.getcwd ())

let discover_domains () =
  let app_dir = "app" in
  if not (Sys.file_exists app_dir && Sys.is_directory app_dir) then []
  else begin
    let domains = ref [] in
    (try
      Array.iter (fun entry ->
        let path = Filename.concat app_dir entry in
        if entry.[0] <> '.' && Sys.is_directory path then
          domains := entry :: !domains
      ) (Sys.readdir app_dir)
    with _ -> ());
    List.rev !domains
  end

let namespace_or_exit ~workspace ~domain =
  match Sun_cli_deployment_plan.namespace_result ~workspace ~domain with
  | Ok namespace -> Sun_cli_deployment_plan.namespace_to_string namespace
  | Error err ->
    Printf.eprintf "error: %s\n" (Sun_cli_deployment_plan.plan_error_to_string err);
    exit 1

let declared_services ~domain : (string * string * Sun_cli_manifest.primitive) list =
  Sun_cli_manifest.discover_services ~filter_path:None
  |> List.filter (fun (s : Sun_cli_manifest.service) -> s.domain = domain)
  |> List.filter_map (fun (s : Sun_cli_manifest.service) ->
       match Sun_cli_deployment_plan.k8s_name_result s.name with
       | Error _ -> None
       | Ok k8s_name ->
         Some (s.name, Sun_cli_deployment_plan.k8s_name_to_string k8s_name, s.primitive))

let service_diagnoses_named ~ns ~domain : (string * string option) list =
  declared_services ~domain
  |> List.map (fun (service_name, k8s_name, primitive) ->
       let pod_expectation = Sun_cli_status.pod_expectation_of_primitive primitive in
       (k8s_name,
        Sun_cli_rollout_diagnosis.diagnose_service_live
          ~pod_expectation ~ns ~service_name ~k8s_name ()))

let service_diagnoses ~ns ~domain : string option list =
  service_diagnoses_named ~ns ~domain |> List.map snd

let ns_exists ns =
  match Sun_cli_kubectl.get_raw ~args:["get"; "ns"; ns] with
  | Ok r -> r.Sun_cli_process.exit_code = 0
  | Error _ -> false

let http_reachable url =
  match Sun_cli_process.run
          (Sun_cli_process.cmd ~timeout_s:3.0
             ["curl"; "-s"; "-o"; "/dev/null"; "-w"; "%{http_code}"; "--max-time"; "2"; url]) with
  | Ok r ->
    (match int_of_string_opt (String.trim r.Sun_cli_process.stdout) with
     | Some code -> code > 0 && code < 500
     | None -> false)
  | Error _ -> false

(* ── Observability reachability ─────────────────────────────────────────── *)

let probe ~backend ~explicit_url ~default_local_url ~probe_path =
  Sun_cli_status.reachability_of_probe
    ~probe_url:(Sun_cli_status.probe_url ~backend ~explicit_url ~default_local_url ~probe_path)
    ~is_reachable:http_reachable

let dashboard_reachability ~backend ~base_domain =
  match Sun_cli_observability_url.resolve ~backend ?base_domain () with
  | Sun_cli_observability_url.Url url ->
    Sun_cli_status.reachability_of_probe ~probe_url:(Some url) ~is_reachable:http_reachable
  | Sun_cli_observability_url.No_url _ -> Sun_cli_status.Not_checked

let print_observability_lines ~backend ~explicit_loki_url ~explicit_prometheus_url =
  let logs = probe ~backend ~explicit_url:explicit_loki_url
      ~default_local_url:"http://localhost:3100" ~probe_path:"/ready" in
  let metrics = probe ~backend ~explicit_url:explicit_prometheus_url
      ~default_local_url:"http://localhost:9090" ~probe_path:"/-/healthy" in
  Printf.printf "  logs     %s\n" (Sun_cli_status.reachability_to_string logs);
  Printf.printf "  metrics  %s\n%!" (Sun_cli_status.reachability_to_string metrics)

let print_observability_block ~backend ~base_domain
    ~explicit_loki_url ~explicit_prometheus_url =
  Printf.printf "\nObservability\n";
  print_observability_lines ~backend ~explicit_loki_url ~explicit_prometheus_url;
  Printf.printf "  dashboard  %s\n%!"
    (Sun_cli_status.reachability_to_string (dashboard_reachability ~backend ~base_domain))

let print_open_block ~scope =
  let suffix = match scope with "" -> "" | s -> " " ^ s in
  Printf.printf "\nOpen\n";
  Printf.printf "  logs       sun open logs%s\n" suffix;
  Printf.printf "  metrics    sun open metrics%s\n" suffix;
  Printf.printf "  dashboard  sun open dashboard%s\n%!" suffix

(* ── Raw Kubernetes Diagnostics ─────────────────────────────────────────── *)

let print_raw_diagnostics ~ns ~domain ~only_k8s_name =
  Printf.printf "\nNamespace: %s\n%!" ns;
  if ns_exists ns then begin
    let pod_args = match only_k8s_name with
      | None -> ["get"; "pods"; "-n"; ns]
      | Some k8s_name -> ["get"; "pods"; "-n"; ns; "-l"; "app=" ^ k8s_name]
    in
    (match Sun_cli_kubectl.get_raw ~args:pod_args with
     | Ok r -> print_string r.Sun_cli_process.stdout; print_char '\n'
     | Error _ -> ());
    service_diagnoses_named ~ns ~domain
    |> List.iter (fun (k8s_name, diagnosis) ->
         match only_k8s_name with
         | Some only when only <> k8s_name -> ()
         | _ ->
           match diagnosis with
           | None -> ()
           | Some d -> Printf.printf "%s\n%!" d);
    (* Port-forward hint for ClusterIP HTTP services in this namespace.
       Filter out internal services: names ending in "-headless" or equal
       to "kubernetes". *)
    let jsonpath = "{.items[?(@.spec.type==\"ClusterIP\")].metadata.name}" in
    let svc_names_raw =
      match Sun_cli_kubectl.get_raw
          ~args:["get"; "svc"; "-n"; ns; "-o"; "jsonpath=" ^ jsonpath] with
      | Ok r when r.Sun_cli_process.exit_code = 0 -> r.Sun_cli_process.stdout
      | _ -> ""
    in
    if svc_names_raw <> "" then begin
      let names = String.split_on_char ' ' svc_names_raw in
      let is_internal name =
        name = "kubernetes" ||
        (let n = String.length name in
         n >= 9 && String.sub name (n - 9) 9 = "-headless")
      in
      let port80_jsonpath = "{.spec.ports[?(@.port==80)].port}" in
      let http_svcs = List.filter (fun name ->
        (not (is_internal name)) &&
        (match only_k8s_name with Some only -> name = only | None -> true) &&
        (match Sun_cli_kubectl.get ~resource:"svc" ~name ~namespace:ns
                   ~output:("jsonpath=" ^ port80_jsonpath) with
         | Ok r when r.Sun_cli_process.exit_code = 0 -> r.Sun_cli_process.stdout <> ""
         | _ -> false)
      ) names in
      List.iter (fun name ->
        Printf.printf "  →  http://localhost:8080  (%s)\n%!" name
      ) http_svcs
    end
  end else
    Printf.printf "  (not deployed — run 'sun up')\n%!";
  Printf.printf "\n%!"

(* ── Workspace Scope ────────────────────────────────────────────────────── *)

let print_workspace_index ~workspace ~domains ~backend
    ~explicit_loki_url ~explicit_prometheus_url =
  Printf.printf "\nDomains\n";
  List.iter (fun domain ->
    let ns = namespace_or_exit ~workspace ~domain in
    let exists = ns_exists ns in
    let diagnoses = if exists then service_diagnoses ~ns ~domain else [] in
    let status = Sun_cli_status.rollup_domain_status ~ns_exists:exists diagnoses in
    Printf.printf "  %-12s %s\n" domain (Sun_cli_status.domain_status_to_string status)
  ) domains;
  Printf.printf "\nObservability\n";
  Printf.printf "  backend  %s\n" (Sun_cli_observability_url.backend_to_string backend);
  print_observability_lines ~backend ~explicit_loki_url ~explicit_prometheus_url;
  print_open_block ~scope:""

(* ── Domain Scope ───────────────────────────────────────────────────────── *)

let print_domain_status ~workspace ~domain ~backend ~base_domain
    ~explicit_loki_url ~explicit_prometheus_url =
  let ns = namespace_or_exit ~workspace ~domain in
  let exists = ns_exists ns in
  let named = if exists then service_diagnoses_named ~ns ~domain else [] in
  let status = Sun_cli_status.rollup_domain_status ~ns_exists:exists (List.map snd named) in
  Printf.printf "\n%s  %s  %s\n" domain
    (Sun_cli_observability_url.backend_to_string backend)
    (Sun_cli_status.domain_status_to_string status);
  Printf.printf "\nServices\n";
  if named = [] then Printf.printf "  (none)\n"
  else
    List.iter (fun (k8s_name, diagnosis) ->
      let service_status = Sun_cli_status.rollup_domain_status ~ns_exists:true [diagnosis] in
      Printf.printf "  %-12s %s\n" k8s_name (Sun_cli_status.domain_status_to_string service_status)
    ) named;
  print_observability_block ~backend ~base_domain
    ~explicit_loki_url ~explicit_prometheus_url;
  print_open_block ~scope:domain;
  print_raw_diagnostics ~ns ~domain ~only_k8s_name:None

(* ── Service Scope ──────────────────────────────────────────────────────── *)

let print_service_status ~workspace ~domain ~service_name ~backend ~base_domain
    ~explicit_loki_url ~explicit_prometheus_url =
  let ns = namespace_or_exit ~workspace ~domain in
  let k8s_name =
    match Sun_cli_deployment_plan.k8s_name_result service_name with
    | Ok k -> Sun_cli_deployment_plan.k8s_name_to_string k
    | Error err ->
      Printf.eprintf "error: %s\n" (Sun_cli_deployment_plan.plan_error_to_string err);
      exit 1
  in
  let declared = declared_services ~domain in
  let declared_k8s_names = List.map (fun (_, k, _) -> k) declared in
  if not (Sun_cli_status.service_is_declared ~k8s_name declared_k8s_names) then begin
    Printf.eprintf "Service '%s' not found in domain '%s'.\n" service_name domain;
    exit 1
  end;
  let (_, _, primitive) = List.find (fun (_, k, _) -> k = k8s_name) declared in
  let pod_expectation = Sun_cli_status.pod_expectation_of_primitive primitive in
  let exists = ns_exists ns in
  let diagnosis =
    if exists then
      Sun_cli_rollout_diagnosis.diagnose_service_live
        ~pod_expectation ~ns ~service_name:k8s_name ~k8s_name ()
    else None
  in
  let status = Sun_cli_status.rollup_domain_status ~ns_exists:exists [diagnosis] in
  Printf.printf "\n%s/%s  %s\n" domain k8s_name (Sun_cli_status.domain_status_to_string status);
  print_observability_block ~backend ~base_domain
    ~explicit_loki_url ~explicit_prometheus_url;
  print_open_block ~scope:(domain ^ "/" ^ k8s_name);
  print_raw_diagnostics ~ns ~domain ~only_k8s_name:(Some k8s_name)

let run scope_str explicit_backend explicit_base_domain target
    explicit_loki_url explicit_prometheus_url =
  let workspace = workspace_name () in
  let all_domains = discover_domains () in
  if all_domains = [] then begin
    Printf.eprintf "No domains found in app/. Run from the workspace root.\n";
    exit 1
  end;
  let scope = match Sun_cli_open.parse_scope scope_str with
    | Ok s -> s
    | Error msg -> Printf.eprintf "error: %s\n" msg; exit 1
  in
  match scope with
  | Sun_cli_open.Workspace ->
    let backend =
      match Sun_cli_observability_url.effective_backend_and_base_domain
              ~explicit_backend ~explicit_base_domain ~target () with
      | Error msg -> Printf.eprintf "error: %s\n" msg; exit 1
      | Ok (backend, _base_domain) -> backend
    in
    print_workspace_index ~workspace ~domains:all_domains ~backend
      ~explicit_loki_url ~explicit_prometheus_url
  | Sun_cli_open.Domain domain | Sun_cli_open.Service (domain, _) ->
    if not (List.mem domain all_domains) then begin
      Printf.eprintf "Domain '%s' not found in app/.\n" domain;
      exit 1
    end;
    let (backend, base_domain) =
      match Sun_cli_observability_url.effective_backend_and_base_domain
              ~explicit_backend ~explicit_base_domain ~target () with
      | Error msg -> Printf.eprintf "error: %s\n" msg; exit 1
      | Ok pair -> pair
    in
    (match scope with
     | Sun_cli_open.Service (_, service_name) ->
       print_service_status ~workspace ~domain ~service_name ~backend ~base_domain
         ~explicit_loki_url ~explicit_prometheus_url
     | _ ->
       print_domain_status ~workspace ~domain ~backend ~base_domain
         ~explicit_loki_url ~explicit_prometheus_url)

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let domain_arg =
  Arg.(value & pos 0 (some string) None &
       info [] ~docv:"SCOPE"
         ~doc:"Scope to show: omit for the workspace index, 'domain' for \
               one domain's services, or 'domain/service' for a single \
               service.")

let loki_base_url_arg =
  Arg.(value & opt (some string) None &
       info ["loki-base-url"] ~docv:"URL"
         ~doc:"Base URL of the Loki instance to check for the \
               Observability block's reachability line. When omitted: \
               checked at http://localhost:3100 for the local backend, \
               otherwise printed as \"not checked\" rather than guessed.")

let prometheus_base_url_arg =
  Arg.(value & opt (some string) None &
       info ["prometheus-base-url"] ~docv:"URL"
         ~doc:"Base URL of the Prometheus instance to check for the \
               Observability block's reachability line. When omitted: \
               checked at http://localhost:9090 for the local backend, \
               otherwise printed as \"not checked\" rather than guessed.")

let backend_of_arg = function
  | None -> None
  | Some s ->
    match Sun_cli_observability_url.backend_of_string s with
    | Some b -> Some b
    | None ->
      Printf.eprintf
        "error: unknown --observability-backend %S (expected: local, \
         self_hosted_durable, external)\n" s;
      exit 1

let cmd =
  Cmd.v
    (Cmd.info "status"
       ~doc:"Show workspace/domain/service health and observability status.")
    Term.(const (fun scope observability_backend base_domain target
                     loki_base_url prometheus_base_url ->
        run scope (backend_of_arg observability_backend) base_domain target
          loki_base_url prometheus_base_url)
      $ domain_arg $ Cmd_logs.observability_backend_arg $ Cmd_logs.base_domain_arg
      $ Cmd_logs.target_arg $ loki_base_url_arg $ prometheus_base_url_arg)
