open Cmdliner

let cmd_ok cmd =
  Sys.command (Printf.sprintf "%s >/dev/null 2>&1" cmd) = 0

let workspace_name () = Filename.basename (Sys.getcwd ())

let run filter_domain =
  let workspace = workspace_name () in
  let inv = Sun_cli_workspace_model.scan ~dir:"." in
  let all_domains =
    inv.Sun_cli_workspace_model.services
    |> List.map (fun (s : Sun_cli_manifest.service) -> s.domain)
    |> List.sort_uniq String.compare
  in
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
    let ns = Sun_cli_deployment_plan.namespace_of ~workspace ~domain in
    Printf.printf "Namespace: %s\n%!" ns;
    if cmd_ok (Printf.sprintf "kubectl get ns %s" (Filename.quote ns)) then begin
      ignore (Sys.command (Printf.sprintf "kubectl get pods -n %s 2>&1" (Filename.quote ns)));
      (* Print port-forward hint for ClusterIP HTTP services in this namespace.
         Filter out internal services: names ending in "-headless" or equal to "kubernetes". *)
      let tmp = Filename.temp_file "sun-svc-" ".tmp" in
      ignore (Sys.command (Printf.sprintf
        "kubectl get svc -n %s -o jsonpath='{.items[?(@.spec.type==\"ClusterIP\")].metadata.name}' > %s 2>/dev/null"
        (Filename.quote ns) (Filename.quote tmp)));
      let ic = open_in tmp in
      let svc_names_raw = String.trim (In_channel.input_all ic) in
      close_in ic;
      (try Sys.remove tmp with _ -> ());
      if svc_names_raw <> "" then begin
        let names = String.split_on_char ' ' svc_names_raw in
        let is_internal name =
          name = "kubernetes" ||
          (let n = String.length name in
           n >= 9 && String.sub name (n - 9) 9 = "-headless")
        in
        let http_svcs = List.filter (fun name ->
          (not (is_internal name)) &&
          (* Check that the service exposes port 80 *)
          (let tmp2 = Filename.temp_file "sun-svcport-" ".tmp" in
           ignore (Sys.command (Printf.sprintf
             "kubectl get svc %s -n %s -o jsonpath='{.spec.ports[?(@.port==80)].port}' > %s 2>/dev/null"
             (Filename.quote name) (Filename.quote ns) (Filename.quote tmp2)));
           let ic2 = open_in tmp2 in
           let port_s = String.trim (In_channel.input_all ic2) in
           close_in ic2;
           (try Sys.remove tmp2 with _ -> ());
           port_s <> "")
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
