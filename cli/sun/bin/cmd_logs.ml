open Cmdliner

let workspace_name () = Filename.basename (Sys.getcwd ())

(* Parse a service argument in one of these forms:
   - "domain/name_svc"  → (domain, name_svc)
   - "domain/name"      → (domain, name)
   - "name_svc"         → scan app/ for domain
   - "name"             → scan app/ for domain *)
let resolve_service arg =
  if String.contains arg '/' then begin
    match String.split_on_char '/' arg with
    | [domain; name] -> Some (domain, name)
    | _ ->
      Printf.eprintf "error: service path must be in 'domain/name' form, got '%s'.\n" arg;
      exit 1
  end else begin
    let matches = List.filter_map (fun (s : Sun_cli_manifest.service) ->
      if s.name = arg then Some (s.domain, s.name) else None
    ) (Sun_cli_manifest.discover_services ~filter_path:None) in
    match matches with
    | [] ->
      Printf.eprintf "error: service '%s' not found in app/.\n" arg;
      Printf.eprintf "  Use 'domain/name' form or run from the workspace root.\n";
      exit 1
    | [(domain, name)] -> Some (domain, name)
    | matches ->
      Printf.eprintf "error: '%s' is ambiguous — found in multiple domains:\n" arg;
      List.iter (fun (d, n) -> Printf.eprintf "  %s/%s\n" d n) matches;
      Printf.eprintf "  Specify the full path, e.g. 'sun logs %s/%s'.\n"
        (fst (List.hd matches)) arg;
      exit 1
  end

let deployment_exists ns k8s_name =
  Sys.command
    (Printf.sprintf "kubectl get deployment %s -n %s >/dev/null 2>&1" (Filename.quote k8s_name) (Filename.quote ns)) = 0

let run (service_arg : string) (_follow : bool) (no_follow : bool) (tail : int) (grafana_base_url : string) : unit =
  let follow = not no_follow in
  let workspace = workspace_name () in
  let (domain, name) = match resolve_service service_arg with
    | Some p -> p
    | None -> exit 1
  in
  let ns       = Sun_cli_deployment_plan.namespace_of ~workspace ~domain in
  let k8s_name = String.map (fun c -> if c = '_' then '-' else c) name in

  if not (deployment_exists ns k8s_name) then begin
    Printf.eprintf "Service %s not found in namespace %s.\n" name ns;
    Printf.eprintf "Run 'sun status' to see deployed services.\n";
    exit 1
  end;

  let url = Sun_cli_logs.grafana_explore_url ~base_url:grafana_base_url ~ns ~k8s_name in
  Printf.printf "Grafana logs: %s\n%!" url;

  let follow_flag = if follow then " --follow" else "" in
  let tail_flag   = Printf.sprintf " --tail=%d" tail in
  let cmd = Printf.sprintf "kubectl logs -n %s deployment/%s%s%s"
    (Filename.quote ns) (Filename.quote k8s_name) follow_flag tail_flag in
  exit (Sys.command cmd)

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let service_arg =
  Arg.(required & pos 0 (some string) None &
       info [] ~docv:"SERVICE"
         ~doc:"Service to stream logs from, in 'domain/name' or bare 'name' form \
               (e.g. payments/charge_svc or charge_svc). \
               Underscores are accepted; Sun maps them to hyphens in Kubernetes.")

let follow_flag =
  Arg.(value & flag &
       info ["follow"; "f"]
         ~doc:"Stream logs in real time. \
               This is the default; pass --no-follow for a snapshot.")

let no_follow_flag =
  Arg.(value & flag &
       info ["no-follow"]
         ~doc:"Print a log snapshot and exit without streaming.")

let tail_arg =
  Arg.(value & opt int 100 &
       info ["tail"] ~docv:"N"
         ~doc:"Number of recent lines to show before following (default: 100). \
               Pass 0 to skip history and stream only new lines.")

let grafana_base_url_arg =
  Arg.(value & opt string "http://localhost:3000" &
       info ["grafana-base-url"] ~docv:"URL"
         ~doc:"Base URL of the Grafana instance (default: http://localhost:3000). \
               Sun prints a copyable Grafana Explore URL with a LogQL query \
               before streaming kubectl logs.")

let cmd =
  Cmd.v
    (Cmd.info "logs"
       ~doc:"Stream logs from a deployed service. \
             Wraps 'kubectl logs' with Sun's namespace convention \
             (<workspace>-<domain>).")
    Term.(const run $ service_arg $ follow_flag $ no_follow_flag $ tail_arg $ grafana_base_url_arg)
