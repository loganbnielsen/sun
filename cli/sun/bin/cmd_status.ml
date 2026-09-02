open Cmdliner

let workspace_name () = Filename.basename (Sys.getcwd ())

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

(* Kubernetes-derived rollout diagnosis: works even when the app never
   started and Loki has nothing, so it's used unconditionally, not as a
   fallback behind Loki health. One entry per checkable service in the
   domain ([None] = healthy, [Some diagnosis] = rollout failed); services
   whose name fails Sun's k8s-naming rules are skipped, same as before. *)

let service_diagnoses ~ns ~domain : string option list =
  Sun_cli_manifest.discover_services ~filter_path:None
  |> List.filter (fun (s : Sun_cli_manifest.service) -> s.domain = domain)
  |> List.filter_map (fun (s : Sun_cli_manifest.service) ->
       match Sun_cli_deployment_plan.k8s_name_result s.name with
       | Error _ -> None
       | Ok k8s_name -> Some (s.name, Sun_cli_deployment_plan.k8s_name_to_string k8s_name))
  |> List.map (fun (service_name, k8s_name) ->
       Sun_cli_rollout_diagnosis.diagnose_service_live ~ns ~service_name ~k8s_name)

let print_rollout_diagnosis ~ns ~domain =
  service_diagnoses ~ns ~domain
  |> List.iter (function
       | None -> ()
       | Some diagnosis -> Printf.printf "%s\n%!" diagnosis)

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

(* Workspace-level index (OBS-009): one line per domain's rolled-up health,
   the active observability backend's own reachability, and real
   'sun open ...' hints (OBS-010) instead of placeholder text. *)
let print_workspace_index ~workspace ~domains ~observability_backend
    ~loki_base_url ~prometheus_base_url =
  Printf.printf "\nDomains\n";
  List.iter (fun domain ->
    let ns = namespace_or_exit ~workspace ~domain in
    let exists = ns_exists ns in
    let diagnoses = if exists then service_diagnoses ~ns ~domain else [] in
    let status = Sun_cli_status.rollup_domain_status ~ns_exists:exists diagnoses in
    Printf.printf "  %-12s %s\n" domain (Sun_cli_status.domain_status_to_string status)
  ) domains;
  Printf.printf "\nObservability\n";
  Printf.printf "  backend  %s\n" (Sun_cli_observability_url.backend_to_string observability_backend);
  Printf.printf "  logs     %s\n" (if http_reachable (loki_base_url ^ "/ready") then "healthy" else "unreachable");
  Printf.printf "  metrics  %s\n%!"
    (if http_reachable (prometheus_base_url ^ "/-/healthy") then "healthy" else "unreachable");
  Printf.printf "\nOpen\n";
  Printf.printf "  logs       sun open logs\n";
  Printf.printf "  metrics    sun open metrics\n";
  Printf.printf "  dashboard  sun open dashboard\n%!"

let run filter_domain observability_backend loki_base_url prometheus_base_url =
  let workspace = workspace_name () in
  let all_domains = discover_domains () in
  if all_domains = [] then begin
    Printf.eprintf "No domains found in app/. Run from the workspace root.\n";
    exit 1
  end;
  match filter_domain with
  | None ->
    print_workspace_index ~workspace ~domains:all_domains ~observability_backend
      ~loki_base_url ~prometheus_base_url
  | Some d ->
  let domains =
    if List.mem d all_domains then [d]
    else begin
      Printf.eprintf "Domain '%s' not found in app/.\n" d;
      exit 1
    end
  in
  Printf.printf "\n%!";
  List.iter (fun domain ->
    let ns = namespace_or_exit ~workspace ~domain in
    Printf.printf "Namespace: %s\n%!" ns;
    let ns_up = ns_exists ns in
    if ns_up then begin
      (match Sun_cli_kubectl.get_raw ~args:["get"; "pods"; "-n"; ns] with
       | Ok r -> print_string r.Sun_cli_process.stdout; print_char '\n'
       | Error _ -> ());
      print_rollout_diagnosis ~ns ~domain;
      (* Print port-forward hint for ClusterIP HTTP services in this namespace.
         Filter out internal services: names ending in "-headless" or equal to "kubernetes". *)
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
  ) domains

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let domain_arg =
  Arg.(value & pos 0 (some string) None &
       info [] ~docv:"DOMAIN"
         ~doc:"Filter to a specific domain (default: all). Omitting this \
               shows the workspace-level index instead of per-domain detail.")

let prometheus_base_url_arg =
  Arg.(value & opt string "http://localhost:9090" &
       info ["prometheus-base-url"] ~docv:"URL"
         ~doc:"Base URL of the Prometheus instance, used only for the \
               workspace index's reachability check (default: \
               http://localhost:9090).")

let cmd =
  Cmd.v
    (Cmd.info "status"
       ~doc:"Show running pods and service endpoints for the current workspace")
    Term.(const (fun domain observability_backend loki_base_url prometheus_base_url ->
        let observability_backend =
          match Sun_cli_observability_url.backend_of_string observability_backend with
          | Some b -> b
          | None ->
            Printf.eprintf
              "error: unknown --observability-backend %S (expected: local, \
               self_hosted_durable, external)\n" observability_backend;
            exit 1
        in
        run domain observability_backend loki_base_url prometheus_base_url)
      $ domain_arg $ Cmd_logs.observability_backend_arg $ Cmd_logs.loki_base_url_arg
      $ prometheus_base_url_arg)
