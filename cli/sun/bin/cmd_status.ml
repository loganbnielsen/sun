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

let run filter_domain =
  let workspace = workspace_name () in
  let all_domains = discover_domains () in
  let domains = match filter_domain with
    | None   -> all_domains
    | Some d ->
      if List.mem d all_domains then [d]
      else begin
        Printf.eprintf "Domain '%s' not found in app/.\n" d;
        exit 1
      end
  in
  if domains = [] then begin
    Printf.eprintf "No domains found in app/. Run from the workspace root.\n";
    exit 1
  end;
  Printf.printf "\n%!";
  List.iter (fun domain ->
    let ns = namespace_or_exit ~workspace ~domain in
    Printf.printf "Namespace: %s\n%!" ns;
    let ns_exists =
      match Sun_cli_process.run
          (Sun_cli_process.cmd ["kubectl"; "get"; "ns"; ns]) with
      | Ok r -> r.Sun_cli_process.exit_code = 0
      | Error _ -> false
    in
    if ns_exists then begin
      (match Sun_cli_process.run
           (Sun_cli_process.cmd ["kubectl"; "get"; "pods"; "-n"; ns]) with
       | Ok r -> print_string r.Sun_cli_process.stdout; print_char '\n'
       | Error _ -> ());
      (* Print port-forward hint for ClusterIP HTTP services in this namespace.
         Filter out internal services: names ending in "-headless" or equal to "kubernetes". *)
      let jsonpath = "{.items[?(@.spec.type==\"ClusterIP\")].metadata.name}" in
      let svc_names_raw =
        match Sun_cli_process.run
            (Sun_cli_process.cmd
               ["kubectl"; "get"; "svc"; "-n"; ns; "-o"; "jsonpath=" ^ jsonpath]) with
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
          (match Sun_cli_process.run
               (Sun_cli_process.cmd
                  ["kubectl"; "get"; "svc"; name; "-n"; ns;
                   "-o"; "jsonpath=" ^ port80_jsonpath]) with
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
         ~doc:"Filter to a specific domain (default: all)")

let cmd =
  Cmd.v
    (Cmd.info "status"
       ~doc:"Show running pods and service endpoints for the current workspace")
    Term.(const run $ domain_arg)
