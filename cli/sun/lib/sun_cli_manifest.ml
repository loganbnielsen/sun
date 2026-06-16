(* YAML manifest rendering and apply logic shared by sun up and sun deploy. *)

(* Re-export all YAML generators and service model types. *)
include Sun_cli_manifest_yaml

(* ── Secret backend type ─────────────────────────────────────────────────── *)

type secret_backend =
  | Kubernetes_live         (** Emit a Kubernetes Secret with real values (live deploy / sun up). *)
  | Kubernetes_placeholder  (** Emit a redacted Kubernetes Secret with empty stringData (GitOps). *)
  | External_secrets of {
      store_ref        : string;
      store_kind       : string;
      key_prefix       : string;
      refresh_interval : string;
    }

(* ── Service discovery ───────────────────────────────────────────────────── *)

let prim_of_suffix name =
  let n = String.length name in
  if   n > 4 && String.sub name (n-4) 4 = "_svc"    then Some Svc
  else if n > 7 && String.sub name (n-7) 7 = "_worker" then Some Worker
  else if n > 3 && String.sub name (n-3) 3 = "_fn"     then Some Fn
  else None

let discover_services ~filter_path =
  let app_dir = "app" in
  if not (Sys.file_exists app_dir && Sys.is_directory app_dir) then begin
    Printf.eprintf "error: 'app/' not found — run from the workspace root.\n";
    exit 1
  end;
  let services = ref [] in
  (try
    Array.iter (fun domain ->
      let dp = Filename.concat app_dir domain in
      if domain.[0] <> '.' && Sys.is_directory dp then
        (try
          Array.iter (fun svc_dir ->
            let sp = Filename.concat dp svc_dir in
            if svc_dir.[0] <> '.' && Sys.is_directory sp then
              match prim_of_suffix svc_dir with
              | None -> ()
              | Some prim ->
                if Sys.file_exists (Filename.concat sp "Dockerfile") then begin
                  let svc = { domain; name = svc_dir; prim; dir = sp } in
                  let included = match filter_path with
                    | None   -> true
                    | Some p -> sp = p || Filename.basename sp = p
                  in
                  if included then services := svc :: !services
                end
          ) (Sys.readdir dp)
        with _ -> ())
    ) (Sys.readdir app_dir)
  with _ -> ());
  List.rev !services

(* ── Apply / emit helpers ────────────────────────────────────────────────── *)

exception Deploy_failed of string

let apply_live yaml =
  Sun_process.with_tmp_file "sun-manifest-" yaml (fun tmp ->
    let rc = Sun_process.run_rc ~echo:false (Printf.sprintf "kubectl apply -f %s" (Filename.quote tmp)) in
    if rc <> 0 then raise (Deploy_failed "kubectl apply failed"))

let apply (ns_yaml, workload_yaml) ~dry_run =
  if dry_run then
    Printf.printf "%s\n%s\n" ns_yaml workload_yaml
  else begin
    apply_live ns_yaml;
    Sun_process.with_tmp_file "sun-manifest-" workload_yaml (fun tmp ->
      let rc = Sun_process.run_rc ~echo:false (Printf.sprintf "kubectl apply -f %s --dry-run=server 2>&1" (Filename.quote tmp)) in
      if rc <> 0 then
        raise (Deploy_failed "kubectl server-side dry-run failed (invalid manifest)");
      let rc = Sun_process.run_rc ~echo:false (Printf.sprintf "kubectl apply -f %s" (Filename.quote tmp)) in
      if rc <> 0 then raise (Deploy_failed "kubectl apply failed"))
  end

(* Write YAML for one service to <dir>/<ns>-<name>.yaml.
   Used by sun deploy --emit-to for GitOps workflows. *)
let emit_to_dir dir (ns_yaml, workload_yaml) ~ns ~name =
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir (Printf.sprintf "%s-%s.yaml" ns name) in
  let oc = open_out path in
  output_string oc ns_yaml;
  output_string oc "\n";
  output_string oc workload_yaml;
  output_string oc "\n";
  close_out oc;
  path
