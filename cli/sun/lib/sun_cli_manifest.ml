(* YAML manifest rendering and apply logic shared by sun up and sun deploy. *)

(* Re-export all YAML generators and service model types. *)
include Sun_cli_manifest_yaml

(* ── Helm chart value model ──────────────────────────────────────────────── *)

type helm_val =
  | Bool  of bool
  | Float of float
  | Str   of string

let render_helm_flag (k, v) = match v with
  | Bool  b -> Printf.sprintf "--set %s=%s" k (string_of_bool b)
  | Float f -> Printf.sprintf "--set %s=%g" k f
  | Str   s -> Printf.sprintf "--set-string %s=%s" k s

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

let secret_backend_to_string = function
  | Kubernetes_live        -> "kubernetes-live"
  | Kubernetes_placeholder -> "kubernetes-placeholder"
  | External_secrets _     -> "external-secrets"

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

let write_tmp content =
  let tmp = Filename.temp_file "sun-manifest-" ".yaml" in
  let oc = open_out tmp in
  output_string oc content;
  close_out oc;
  tmp

let kubectl_apply tmp =
  match Sun_cli_process.run_ok (Sun_cli_process.cmd ["kubectl"; "apply"; "-f"; tmp]) with
  | Ok () -> ()
  | Error e -> raise (Deploy_failed ("kubectl apply failed: " ^ Sun_cli_process.error_to_string e))

let apply_live yaml =
  let tmp = write_tmp yaml in
  (try kubectl_apply tmp with e -> (try Sys.remove tmp with _ -> ()); raise e);
  Sys.remove tmp

let apply (ns_yaml, workload_yaml) ~dry_run =
  if dry_run then
    Printf.printf "%s\n%s\n" ns_yaml workload_yaml
  else begin
    apply_live ns_yaml;
    let tmp = write_tmp workload_yaml in
    (try
      (match Sun_cli_process.run_ok
          (Sun_cli_process.cmd ["kubectl"; "apply"; "-f"; tmp; "--dry-run=server"]) with
       | Ok () -> ()
       | Error e ->
         raise (Deploy_failed ("kubectl server-side dry-run failed: " ^ Sun_cli_process.error_to_string e)));
      kubectl_apply tmp
    with e ->
      (try Sys.remove tmp with _ -> ());
      raise e);
    Sys.remove tmp
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
