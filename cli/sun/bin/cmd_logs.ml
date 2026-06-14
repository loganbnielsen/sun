open Cmdliner

let workspace_name () = Filename.basename (Sys.getcwd ())

(* Scan app/ to find which domain owns a bare service name.
   Returns a list of matching (domain, name) pairs. *)
let find_service_by_name name =
  let app_dir = "app" in
  if not (Sys.file_exists app_dir && Sys.is_directory app_dir) then []
  else begin
    let matches = ref [] in
    (try
      Array.iter (fun domain ->
        let domain_path = Filename.concat app_dir domain in
        if domain.[0] <> '.' && Sys.is_directory domain_path then begin
          (try
            Array.iter (fun svc ->
              if svc.[0] <> '.' then begin
                let svc_path = Filename.concat domain_path svc in
                if Sys.is_directory svc_path && svc = name then
                  matches := (domain, svc) :: !matches
              end
            ) (Sys.readdir domain_path)
          with _ -> ())
        end
      ) (Sys.readdir app_dir)
    with _ -> ());
    List.rev !matches
  end

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
    (* bare name — scan app/ *)
    match find_service_by_name arg with
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

let kubectl_exists kind ns k8s_name =
  Sys.command (Printf.sprintf "kubectl get %s %s -n %s >/dev/null 2>&1"
    kind (Filename.quote k8s_name) (Filename.quote ns)) = 0

(* Find the name of the most recently created pod for a CronJob.
   Sun CronJob pod templates carry app=<k8s_name>; sort by creation timestamp. *)
let find_latest_fn_pod ns k8s_name =
  let tmp = Filename.temp_file "sun-logs-fn-" ".tmp" in
  ignore (Sys.command (Printf.sprintf
    "kubectl get pods -n %s -l app=%s --sort-by=.metadata.creationTimestamp -o name 2>/dev/null > %s"
    (Filename.quote ns) (Filename.quote k8s_name) (Filename.quote tmp)));
  let ic = open_in tmp in
  let content = String.trim (In_channel.input_all ic) in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  if content = "" then None
  else begin
    let lines = List.filter (fun s -> s <> "") (String.split_on_char '\n' content) in
    Some (List.nth lines (List.length lines - 1))
  end

let stream_fn_logs ns k8s_name follow tail grafana_base_url =
  Printf.printf "Note: %s/%s is a scheduled function (CronJob).\n%!" ns k8s_name;
  match find_latest_fn_pod ns k8s_name with
  | None ->
    Printf.eprintf
      "No pods found for CronJob %s in namespace %s.\n\
       The function may not have run yet — trigger a test run:\n\
       \  kubectl create job -n %s --from=cronjob/%s test-run\n"
      k8s_name (Filename.quote ns)
      (Filename.quote ns) (Filename.quote k8s_name);
    exit 1
  | Some pod_name ->
    let url = Sun_cli_logs.grafana_explore_url ~base_url:grafana_base_url ~ns ~k8s_name in
    Printf.printf "Grafana logs: %s\n%!" url;
    let follow_flag = if follow then " --follow" else "" in
    let tail_flag   = Printf.sprintf " --tail=%d" tail in
    let cmd = Printf.sprintf "kubectl logs -n %s %s%s%s"
      (Filename.quote ns) (Filename.quote pod_name) follow_flag tail_flag in
    exit (Sys.command cmd)

let run (service_arg : string) (_follow : bool) (no_follow : bool) (tail : int) (grafana_base_url : string) : unit =
  let follow = not no_follow in
  let workspace = workspace_name () in
  let (domain, name) = match resolve_service service_arg with
    | Some p -> p
    | None -> exit 1
  in
  let ns       = Sun_cli_deployment_plan.namespace_of ~workspace ~domain in
  let k8s_name = String.map (fun c -> if c = '_' then '-' else c) name in

  if kubectl_exists "deployment" ns k8s_name then begin
    let url = Sun_cli_logs.grafana_explore_url ~base_url:grafana_base_url ~ns ~k8s_name in
    Printf.printf "Grafana logs: %s\n%!" url;
    let follow_flag = if follow then " --follow" else "" in
    let tail_flag   = Printf.sprintf " --tail=%d" tail in
    let cmd = Printf.sprintf "kubectl logs -n %s deployment/%s%s%s"
      (Filename.quote ns) (Filename.quote k8s_name) follow_flag tail_flag in
    exit (Sys.command cmd)
  end else if kubectl_exists "cronjob" ns k8s_name then
    stream_fn_logs ns k8s_name follow tail grafana_base_url
  else begin
    Printf.eprintf "Service %s not found in namespace %s.\n" name ns;
    Printf.eprintf "Run 'sun status' to see deployed services.\n";
    exit 1
  end

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
