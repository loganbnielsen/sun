(* sun cloud init — provision cloud infrastructure via Terraform.
   Wraps `terraform init && terraform apply` for AWS or GCP.
   Requires: terraform binary in PATH, cloud credentials in environment. *)

open Cmdliner

(* ── Shell helpers ───────────────────────────────────────────────────────── *)

let run_cmd ?(echo = true) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  Sys.command cmd

let cmd_ok cmd = run_cmd ~echo:false cmd = 0

let check_tool name install_url =
  if not (cmd_ok (Printf.sprintf "which %s >/dev/null 2>&1" name)) then begin
    Printf.eprintf "error: %S not found in PATH.\n" name;
    Printf.eprintf "  Install: %s\n" install_url;
    exit 1
  end

(* ── Sun home resolution ─────────────────────────────────────────────────── *)

(* Resolve the Sun monorepo root so we can locate platform/infra/<provider>/. *)
let resolve_sun_home () =
  match Sun_cli_cmd_new.infer_sun_home () with
  | Some dir -> dir
  | None ->
    Printf.eprintf "error: cannot locate the Sun monorepo root.\n";
    Printf.eprintf "  Set SUN_HOME to your Sun checkout and re-run:\n";
    Printf.eprintf "    export SUN_HOME=/path/to/sun\n";
    exit 1

(* ── Terraform output parsing ───────────────────────────────────────────── *)

(* Read terraform output -json from a temp file, print key endpoints, and
   return the kubeconfig_command string if present (to auto-configure kubectl). *)
let print_outputs chdir_arg : string option =
  let tmp = Filename.temp_file "sun-tf-out-" ".json" in
  let rc = Sys.command (Printf.sprintf "terraform output -json %s > %s 2>/dev/null"
    chdir_arg (Filename.quote tmp))
  in
  if rc <> 0 then begin
    Printf.printf "  (could not retrieve terraform outputs)\n%!";
    (try Sys.remove tmp with _ -> ());
    None
  end else begin
    (try
      let ic = open_in tmp in
      let raw = In_channel.input_all ic in
      close_in ic;
      Sys.remove tmp;
      let json = Yojson.Safe.from_string raw in
      (match json with
       | `Assoc pairs ->
         let kubeconfig_cmd = ref None in
         List.iter (fun (key, obj) ->
           match obj with
           | `Assoc fields ->
             let sensitive =
               match List.assoc_opt "sensitive" fields with
               | Some (`Bool b) -> b
               | _ -> true
             in
             if not sensitive then begin
               match List.assoc_opt "value" fields with
               | Some (`String v) ->
                 if key = "kubeconfig_command" then kubeconfig_cmd := Some v;
                 Printf.printf "  %-28s  %s\n%!" key v
               | Some (`List vs) ->
                 let strs = List.filter_map (function
                   | `String s -> Some s | _ -> None) vs in
                 if strs <> [] then
                   Printf.printf "  %-28s  [%s]\n%!" key (String.concat ", " strs)
               | Some (`Null) ->
                 Printf.printf "  %-28s  (none)\n%!" key
               | _ -> ()
             end
           | _ -> ()
         ) pairs;
         !kubeconfig_cmd
       | _ -> None)
    with _ ->
      Printf.printf "  (error parsing terraform outputs)\n%!";
      None)
  end

(* ── cloud init ─────────────────────────────────────────────────────────── *)

type provider = Aws | Gcp

let provider_name = function Aws -> "aws" | Gcp -> "gcp"

let cloud_init use_aws use_gcp var_file dry_run =
  (* Resolve provider — exactly one of --aws / --gcp required *)
  let provider = match use_aws, use_gcp with
    | true, false -> Aws
    | false, true -> Gcp
    | true, true ->
      Printf.eprintf "error: --aws and --gcp are mutually exclusive.\n";
      exit 1
    | false, false ->
      Printf.eprintf "error: specify --aws or --gcp.\n";
      exit 1
  in
  let pname = provider_name provider in

  (* Check prerequisites *)
  check_tool "terraform" "https://developer.hashicorp.com/terraform/install";

  (* Locate terraform module directory *)
  let sun_home = resolve_sun_home () in
  let infra_dir = Filename.concat sun_home
    (Printf.sprintf "platform/infra/%s" pname) in
  if not (Sys.file_exists infra_dir) then begin
    Printf.eprintf "error: Terraform module not found: %s\n" infra_dir;
    exit 1
  end;

  let chdir_arg = Printf.sprintf "-chdir=%s" (Filename.quote infra_dir) in
  let varfile_args = match var_file with
    | None -> ""
    | Some path -> Printf.sprintf " -var-file=%s" (Filename.quote path)
  in

  Printf.printf "\nInitializing cloud infrastructure (%s)...\n%!" pname;

  (* Step 1: terraform init *)
  Printf.printf "\n[1/3] terraform init\n%!";
  let rc = run_cmd (Printf.sprintf "terraform init %s" chdir_arg) in
  if rc <> 0 then begin
    Printf.eprintf "error: terraform init failed (exit %d).\n" rc;
    exit 1
  end;

  (* Step 2: terraform plan or apply *)
  if dry_run then begin
    Printf.printf "\n[2/3] terraform plan  (--dry-run)\n%!";
    let rc = run_cmd (Printf.sprintf "terraform plan %s%s"
      chdir_arg varfile_args) in
    if rc <> 0 then begin
      Printf.eprintf "error: terraform plan failed (exit %d).\n" rc;
      exit 1
    end;
    Printf.printf "\n[3/3] (skipping apply in --dry-run mode)\n%!";
  end else begin
    Printf.printf "\n[2/3] terraform apply\n%!";
    let rc = run_cmd (Printf.sprintf "terraform apply -auto-approve %s%s"
      chdir_arg varfile_args) in
    if rc <> 0 then begin
      Printf.eprintf "error: terraform apply failed (exit %d).\n" rc;
      exit 1
    end;

    (* Step 3: print outputs, then auto-configure kubectl if the Terraform
       module emits a kubeconfig_command output (e.g. aws eks update-kubeconfig). *)
    Printf.printf "\n[3/3] Provisioned endpoints:\n%!";
    let kubeconfig_cmd = print_outputs chdir_arg in
    (match kubeconfig_cmd with
     | Some cmd ->
       Printf.printf "\nConfiguring kubectl…\n%!";
       let rc2 = run_cmd cmd in
       if rc2 <> 0 then
         Printf.eprintf
           "warning: kubeconfig setup failed (exit %d).\n\
            Run manually before using sun deploy / sun status:\n\
            \  %s\n" rc2 cmd
     | None -> ());
  end;

  Printf.printf "\nDone.\n%!"

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let aws_flag =
  Arg.(value & flag &
       info ["aws"]
         ~doc:"Provision AWS infrastructure (EKS, ECR, RDS, Route53)")

let gcp_flag =
  Arg.(value & flag &
       info ["gcp"]
         ~doc:"Provision GCP infrastructure (GKE, Artifact Registry, Cloud SQL)")

let var_file_arg =
  Arg.(value & opt (some string) None &
       info ["var-file"] ~docv:"PATH"
         ~doc:"Path to a Terraform .tfvars file. Passed as -var-file to \
               terraform plan/apply.")

let dry_run_flag =
  Arg.(value & flag &
       info ["dry-run"]
         ~doc:"Run terraform plan instead of terraform apply. \
               No infrastructure is created.")

let init_cmd =
  Cmd.v
    (Cmd.info "init"
       ~doc:"Provision cloud infrastructure via Terraform. \
             Requires the terraform binary in PATH and cloud credentials \
             in the environment (AWS_* or GOOGLE_* variables).")
    Term.(const cloud_init $ aws_flag $ gcp_flag $ var_file_arg $ dry_run_flag)

(* ── Postgres-backed registry ────────────────────────────────────────────── *)

module Pg_registry = struct
  open Caqti_request.Infix

  (* ── schema ────────────────────────────────────────────────────────────── *)

  let ddl = [
    {|CREATE TABLE IF NOT EXISTS hosted_projects (
      project_id TEXT PRIMARY KEY,
      workspace  TEXT NOT NULL UNIQUE
    )|};
    {|CREATE TABLE IF NOT EXISTS hosted_releases (
      release_id  TEXT PRIMARY KEY,
      project_id  TEXT NOT NULL REFERENCES hosted_projects(project_id),
      environment TEXT NOT NULL,
      image_tag   TEXT NOT NULL,
      status      TEXT NOT NULL DEFAULT 'live',
      created_at  TEXT NOT NULL
    )|};
    {|CREATE TABLE IF NOT EXISTS hosted_release_services (
      release_id     TEXT NOT NULL REFERENCES hosted_releases(release_id),
      service_name   TEXT NOT NULL,
      service_status TEXT NOT NULL DEFAULT 'live',
      PRIMARY KEY (release_id, service_name)
    )|};
    {|CREATE TABLE IF NOT EXISTS hosted_release_logs (
      id         SERIAL PRIMARY KEY,
      release_id TEXT NOT NULL REFERENCES hosted_releases(release_id),
      line       TEXT NOT NULL
    )|};
  ]

  (* ── queries ───────────────────────────────────────────────────────────── *)

  let find_project_q =
    (Caqti_type.string ->? Caqti_type.(t2 string string))
      "SELECT project_id, workspace FROM hosted_projects WHERE project_id = ?"

  let find_project_by_workspace_q =
    (Caqti_type.string ->? Caqti_type.(t2 string string))
      "SELECT project_id, workspace FROM hosted_projects WHERE workspace = ?"

  let upsert_project_q =
    (Caqti_type.(t2 string string) ->. Caqti_type.unit)
      "INSERT INTO hosted_projects (project_id, workspace) VALUES (?, ?) \
       ON CONFLICT (project_id) DO NOTHING"

  let insert_release_q =
    (Caqti_type.(t6 string string string string string string) ->. Caqti_type.unit)
      "INSERT INTO hosted_releases \
         (release_id, project_id, environment, image_tag, status, created_at) \
       VALUES (?, ?, ?, ?, ?, ?)"

  let list_releases_q =
    (Caqti_type.string ->* Caqti_type.(t7 string string string string string string (option string)))
      "SELECT release_id, project_id, environment, image_tag, status, created_at, digest \
       FROM hosted_releases WHERE project_id = ? ORDER BY created_at ASC"

  let update_digest_q =
    (Caqti_type.(t2 string string) ->. Caqti_type.unit)
      "UPDATE hosted_releases SET digest = ? WHERE release_id = ?"

  let append_log_q =
    (Caqti_type.(t2 string string) ->. Caqti_type.unit)
      "INSERT INTO hosted_release_logs (release_id, line) VALUES (?, ?)"

  let insert_service_q =
    (Caqti_type.(t3 string string string) ->. Caqti_type.unit)
      "INSERT INTO hosted_release_services (release_id, service_name, service_status) \
       VALUES (?, ?, ?) ON CONFLICT DO NOTHING"

  let list_services_q =
    (Caqti_type.string ->* Caqti_type.(t2 string string))
      "SELECT service_name, service_status \
       FROM hosted_release_services WHERE release_id = ?"

  let list_logs_q =
    (Caqti_type.string ->* Caqti_type.string)
      "SELECT line FROM hosted_release_logs \
       WHERE release_id = ? ORDER BY id ASC"

  (* ── helpers ───────────────────────────────────────────────────────────── *)

  let storage_err_to_string e = Storage_error.to_string e

  let ensure_schema pool =
    let all_ddl = ddl @ [
      "ALTER TABLE hosted_releases ADD COLUMN IF NOT EXISTS digest TEXT";
    ] in
    List.iter (fun sql ->
      let q = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) sql in
      match Db.exec pool q () with
      | Ok () -> ()
      | Error e ->
        Printf.eprintf "warning: schema DDL failed: %s\n%!" (storage_err_to_string e)
    ) all_ddl

  let row_to_project (project_id, workspace) : Sun_cli_registry.project =
    { project_id; workspace }

  let row_to_release services (release_id, project_id, environment, image_tag, status_s, created_at, digest)
      : Sun_cli_registry.release =
    let status = match status_s with
      | "queued"   -> Sun_cli_registry.Queued
      | "building" -> Sun_cli_registry.Building
      | "failed"   -> Sun_cli_registry.Failed
      | _          -> Sun_cli_registry.Live
    in
    { release_id; project_id; environment; image_tag; digest; status; created_at; services }

  let fetch_services pool release_id =
    match Db.collect pool list_services_q release_id with
    | Error e -> Error (storage_err_to_string e)
    | Ok rows ->
      let svcs = List.map (fun (service_name, svc_status_s) ->
        let service_status = match svc_status_s with
          | "failed" -> Sun_cli_registry.Service_failed
          | _        -> Sun_cli_registry.Service_live
        in
        { Sun_cli_registry.service_name; service_status }
      ) rows in
      Ok svcs

  (* ── operations ────────────────────────────────────────────────────────── *)

  let pg_get_project pool project_id =
    match Db.find pool find_project_q project_id with
    | Error e -> Error (storage_err_to_string e)
    | Ok None -> Error (Printf.sprintf "project %S not found" project_id)
    | Ok (Some row) -> Ok (row_to_project row)

  let pg_create_project pool ~workspace =
    let project_id = Sun_cli_registry.project_id_of_workspace workspace in
    (* Check if already exists by workspace *)
    match Db.find pool find_project_by_workspace_q workspace with
    | Error e -> Error (storage_err_to_string e)
    | Ok (Some row) -> Ok (row_to_project row)
    | Ok None ->
      match Db.exec pool upsert_project_q (project_id, workspace) with
      | Error e -> Error (storage_err_to_string e)
      | Ok () ->
        (* Re-fetch in case there was a conflict on project_id *)
        match Db.find pool find_project_q project_id with
        | Error e -> Error (storage_err_to_string e)
        | Ok None -> Error "project not found after insert"
        | Ok (Some row) -> Ok (row_to_project row)

  let pg_create_release pool ~project_id ~environment ~image_tag ~service_names =
    match pg_get_project pool project_id with
    | Error msg -> Error msg
    | Ok _ ->
      let release_id =
        Printf.sprintf "rel-%s-%s"
          project_id
          (string_of_int (int_of_float (Unix.gettimeofday () *. 1000.0)))
      in
      let created_at = string_of_float (Unix.gettimeofday ()) in
      let status = "live" in
      let result = Db.transaction pool (fun tx ->
        match Db.exec tx insert_release_q
                (release_id, project_id, environment, image_tag, status, created_at) with
        | Error e -> Error e
        | Ok () ->
          let service_err =
            List.fold_left (fun acc name ->
              match acc with
              | Error _ as e -> e
              | Ok () ->
                Db.exec tx insert_service_q (release_id, name, "live")
            ) (Ok ()) service_names
          in
          (match service_err with
           | Error _ as e -> e
           | Ok () ->
             let log_lines = [
               Printf.sprintf "[deploy] release %s started: env=%s tag=%s"
                 release_id environment image_tag;
             ] @ List.map (fun svc ->
               Printf.sprintf "[deploy] service %s deployed" svc
             ) service_names
             @ [ Printf.sprintf "[deploy] release %s complete: status=live" release_id ]
             in
             List.fold_left (fun acc line ->
               match acc with
               | Error _ as e -> e
               | Ok () -> Db.exec tx append_log_q (release_id, line)
             ) (Ok ()) log_lines)
      ) in
      (match result with
       | Error e -> Error (storage_err_to_string e)
       | Ok () ->
         let services =
           List.map (fun name ->
             { Sun_cli_registry.service_name = name;
               service_status = Sun_cli_registry.Service_live })
             service_names
         in
         Ok { Sun_cli_registry.
              release_id; project_id; environment; image_tag;
              digest = None;
              status = Sun_cli_registry.Live; created_at; services })

  let pg_list_releases pool ~project_id =
    match pg_get_project pool project_id with
    | Error msg -> Error msg
    | Ok _ ->
      match Db.collect pool list_releases_q project_id with
      | Error e -> Error (storage_err_to_string e)
      | Ok rows ->
        let results = List.map (fun row ->
          let (release_id, _, _, _, _, _, _) = row in
          match fetch_services pool release_id with
          | Error e -> Error e
          | Ok svcs -> Ok (row_to_release svcs row)
        ) rows in
        let err = List.find_opt (function Error _ -> true | Ok _ -> false) results in
        (match err with
         | Some (Error e) -> Error e
         | _ ->
           Ok (List.filter_map (function Ok r -> Some r | Error _ -> None) results))

  let pg_list_releases_page pool ~project_id ?(page = 1) ?(page_size = 20) () =
    match pg_list_releases pool ~project_id with
    | Error msg -> Error msg
    | Ok all ->
      let total = List.length all in
      let offset = (page - 1) * page_size in
      let page_items =
        if offset >= total then []
        else
          let tail = List.filteri (fun i _ -> i >= offset) all in
          List.filteri (fun i _ -> i < page_size) tail
      in
      Ok (page_items, total)

  let pg_get_release_logs pool _project_id release_id =
    match Db.collect pool list_logs_q release_id with
    | Error e -> Error (storage_err_to_string e)
    | Ok lines -> Ok lines

  let pg_append_log_line pool release_id line =
    (match Db.exec pool append_log_q (release_id, line) with
     | Ok () -> ()
     | Error e ->
       Printf.eprintf "warning: append_log_line failed: %s\n%!" (storage_err_to_string e))

  let pg_update_digest pool release_id digest_str =
    match Db.exec pool update_digest_q (digest_str, release_id) with
    | Ok () -> Ok ()
    | Error e -> Error (storage_err_to_string e)

  let update_status_q =
    (Caqti_type.(t2 string string) ->. Caqti_type.unit)
      "UPDATE hosted_releases SET status = ? WHERE release_id = ?"

  let pg_update_status pool release_id status_str =
    match Db.exec pool update_status_q (status_str, release_id) with
    | Ok () -> Ok ()
    | Error e -> Error (storage_err_to_string e)

  (* ── vtable builder ────────────────────────────────────────────────────── *)

  let pg_ops pool : Sun_cli_control_plane.registry_ops = {
    Sun_cli_control_plane.
    create_project        = pg_create_project pool;
    get_project           = pg_get_project pool;
    create_release        = pg_create_release pool;
    list_releases         = pg_list_releases pool;
    list_releases_page    = pg_list_releases_page pool;
    get_release_logs      = pg_get_release_logs pool;
    append_log_line       = pg_append_log_line pool;
    update_release_digest = pg_update_digest pool;
    update_release_status = pg_update_status pool;
  }
end

(* ── In-memory vtable ────────────────────────────────────────────────────── *)

let memory_ops () =
  let r = Sun_cli_registry.create () in
  { Sun_cli_control_plane.
    create_project        = Sun_cli_registry.create_project r;
    get_project           = Sun_cli_registry.get_project r;
    create_release        = Sun_cli_registry.create_release r;
    list_releases         = Sun_cli_registry.list_releases r;
    list_releases_page    = Sun_cli_registry.list_releases_page r;
    get_release_logs      = (fun _project_id release_id ->
                               Sun_cli_registry.get_release_logs r release_id);
    append_log_line       = Sun_cli_registry.append_log_line r;
    update_release_digest = Sun_cli_registry.update_release_digest r;
    update_release_status = (fun rid s -> Sun_cli_registry.update_release_status r rid s);
  }

(* ── Registry selector ───────────────────────────────────────────────────── *)

let with_registry f =
  match Sys.getenv_opt "CONTROL_PLANE_DATABASE_URL" with
  | None -> f (memory_ops ())
  | Some url ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        match Db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
        | Error e ->
          Printf.eprintf "error: cannot connect to control-plane database: %s\n"
            (Storage_error.to_string e);
          exit 1
        | Ok pool ->
          Pg_registry.ensure_schema pool;
          f (Pg_registry.pg_ops pool)
      )
    )

(* ── cloud deploy ────────────────────────────────────────────────────────── *)

let git_sha () =
  let tmp = Filename.temp_file "sun-" ".tmp" in
  ignore (Sys.command (Printf.sprintf "git rev-parse --short HEAD > %s 2>/dev/null" tmp));
  let ic = open_in tmp in
  let s = String.trim (In_channel.input_all ic) in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  if s = "" then "dev" else s

let get_ok_or_exit = function
  | Ok v -> v
  | Error msg ->
    Printf.eprintf "error: %s\n" msg;
    exit 1

(* ── Builder adapter ─────────────────────────────────────────────────────── *)

type builder_result = {
  image_tag : string;
  digest    : string;
}

type builder_adapter = {
  build_and_push :
    workspace_path:string ->
    service_dir:string ->
    image_ref:string ->
    log:(string -> unit) ->
    (builder_result, string) result;
}

let run_streaming cmd log =
  let ic = Unix.open_process_in cmd in
  (try
    while true do
      log (input_line ic)
    done
  with End_of_file -> ());
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> Ok ()
  | Unix.WEXITED n -> Error (Printf.sprintf "command exited %d: %s" n cmd)
  | _ -> Error (Printf.sprintf "command failed: %s" cmd)

let get_digest image_ref =
  let cmd = Printf.sprintf
    "docker inspect --format '{{index .RepoDigests 0}}' %s 2>/dev/null"
    (Filename.quote image_ref) in
  let ic = Unix.open_process_in cmd in
  let s = String.trim (In_channel.input_all ic) in
  (match Unix.close_process_in ic with _ -> ());
  if s = "" || s = "<no value>" then image_ref
  else s

let local_builder = {
  build_and_push = fun ~workspace_path ~service_dir ~image_ref ~log ->
    let ctx_dir = workspace_path ^ ".cloud-ctx" in
    (try ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir))) with _ -> ());
    let rc = Sys.command (Printf.sprintf "cp -rL %s %s 2>&1"
      (Filename.quote workspace_path) (Filename.quote ctx_dir)) in
    if rc <> 0 then Error "failed to copy workspace for docker build context"
    else begin
      ignore (Sys.command (Printf.sprintf "rm -rf %s/_build %s/.git 2>/dev/null; true"
        (Filename.quote ctx_dir) (Filename.quote ctx_dir)));
      let dockerfile = Printf.sprintf "%s/%s/Dockerfile" ctx_dir service_dir in
      if not (Sys.file_exists dockerfile) then begin
        (try ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir))) with _ -> ());
        Error (Printf.sprintf "Dockerfile not found: %s" dockerfile)
      end else begin
        log (Printf.sprintf "[build] building %s" image_ref);
        let build_cmd = Printf.sprintf "docker build -t %s -f %s %s 2>&1"
          (Filename.quote image_ref) (Filename.quote dockerfile) (Filename.quote ctx_dir) in
        match run_streaming build_cmd log with
        | Error msg ->
          (try ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir))) with _ -> ());
          Error msg
        | Ok () ->
          log (Printf.sprintf "[push] pushing %s" image_ref);
          let push_cmd = Printf.sprintf "docker push %s 2>&1"
            (Filename.quote image_ref) in
          (match run_streaming push_cmd log with
           | Error msg ->
             (try ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir))) with _ -> ());
             Error msg
           | Ok () ->
             (try ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir))) with _ -> ());
             let digest = get_digest image_ref in
             log (Printf.sprintf "[deploy] image digest: %s" digest);
             Ok { image_tag = image_ref; digest })
      end
    end
}

let fake_builder ?(digest = "sha256:deadbeef") () = {
  build_and_push = fun ~workspace_path:_ ~service_dir:_ ~image_ref ~log ->
    log (Printf.sprintf "[build] (fake) built %s" image_ref);
    log (Printf.sprintf "[push] (fake) pushed %s" image_ref);
    log (Printf.sprintf "[deploy] (fake) digest: %s" digest);
    Ok { image_tag = image_ref; digest }
}

let cloud_deploy ?(builder = local_builder) environment image_tag registry dry_run output_json =
  let workspace = Filename.basename (Sys.getcwd ()) in
  let sha = match image_tag with Some t -> t | None -> git_sha () in

  if dry_run then begin
    let project_id = Sun_cli_registry.project_id_of_workspace workspace in
    Printf.printf "Project:  %s\nEnv:      %s\nTag:      %s\n"
      project_id environment sha;
    Printf.printf "(dry-run: no build or release recorded)\n%!"
  end else begin
    let reg = match registry with
      | Some r -> r
      | None ->
        match Sys.getenv_opt "CLOUD_REGISTRY" with
        | Some r -> r
        | None ->
          Printf.eprintf "error: --registry or CLOUD_REGISTRY required for hosted deploy\n";
          exit 1
    in
    with_registry (fun ops ->
      let project = ops.Sun_cli_control_plane.create_project ~workspace
        |> get_ok_or_exit in
      let services = Sun_cli_manifest.discover_services ~filter_path:None in
      let service_names =
        List.map (fun (s : Sun_cli_manifest.service) ->
          Sun_cli_deployment_plan.k8s_name_of s.name)
          services
      in
      let release = ops.Sun_cli_control_plane.create_release
          ~project_id:project.Sun_cli_registry.project_id
          ~environment
          ~image_tag:sha
          ~service_names
        |> get_ok_or_exit
      in
      let release_id = release.Sun_cli_registry.release_id in
      ops.Sun_cli_control_plane.append_log_line release_id "[deploy] build phase starting";
      let workspace_path = Sys.getcwd () in
      let last_digest = ref sha in
      let all_ok = List.for_all (fun (svc : Sun_cli_manifest.service) ->
        let image_ref = Printf.sprintf "%s/%s/%s:%s"
          reg workspace (Sun_cli_deployment_plan.k8s_name_of svc.name) sha in
        let log line = ops.Sun_cli_control_plane.append_log_line release_id line in
        match builder.build_and_push
            ~workspace_path ~service_dir:svc.dir ~image_ref ~log with
        | Error msg ->
          ops.Sun_cli_control_plane.append_log_line release_id
            (Printf.sprintf "[deploy] build failed: %s" msg);
          false
        | Ok result ->
          last_digest := result.digest;
          true
      ) services in
      if all_ok then begin
        ignore (ops.Sun_cli_control_plane.update_release_digest release_id !last_digest);
        ops.Sun_cli_control_plane.append_log_line release_id
          "[deploy] release complete: status=live";
        let release_with_digest = { release with Sun_cli_registry.digest = Some !last_digest } in
        if output_json then
          print_string (Yojson.Safe.pretty_to_string
            (Sun_cli_registry.release_to_json release_with_digest))
        else begin
          Printf.printf "Release:  %s\n" release_id;
          Printf.printf "Digest:   %s\n" !last_digest;
          Printf.printf "Status:   live\n"
        end
      end else begin
        ignore (ops.Sun_cli_control_plane.update_release_status release_id "failed");
        ops.Sun_cli_control_plane.append_log_line release_id "[deploy] release failed";
        Printf.eprintf
          "error: build failed; check release logs with: sun cloud logs --release %s\n"
          release_id;
        exit 1
      end;
      print_char '\n'; flush stdout
    )
  end

let environment_arg =
  Arg.(value & opt string "production" &
       info ["environment"; "env"] ~docv:"NAME"
         ~doc:"Target environment name (default: production)")

let cloud_image_tag_arg =
  Arg.(value & opt (some string) None &
       info ["image-tag"] ~docv:"TAG"
         ~doc:"Image tag to record in the release (default: short git SHA)")

let cloud_dry_run_flag =
  Arg.(value & flag &
       info ["dry-run"]
         ~doc:"Print project/env/tag without building or recording a release")

let output_json_flag =
  Arg.(value & flag &
       info ["output-json"]
         ~doc:"Print the release record as JSON")

let registry_arg =
  Arg.(value & opt (some string) None &
       info ["registry"] ~docv:"URL"
         ~doc:"Container registry base URL \
               (e.g. registry.example.com/myapp). \
               Falls back to CLOUD_REGISTRY env var.")

let deploy_cmd =
  Cmd.v
    (Cmd.info "deploy"
       ~doc:"Build workspace images, push to a registry, and record a hosted \
             release. Creates the project if it does not exist. \
             Use --dry-run to preview without building or recording.")
    (* cloud_deploy has an optional ~builder arg for test injection; bind the
       default here so Cmdliner sees a regular curried function. *)
    Term.(const (cloud_deploy ~builder:local_builder) $ environment_arg $ cloud_image_tag_arg
          $ registry_arg $ cloud_dry_run_flag $ output_json_flag)

(* ── cloud releases ──────────────────────────────────────────────────────── *)

let cloud_releases project_id_opt page page_size =
  let workspace = Filename.basename (Sys.getcwd ()) in
  let project_id = match project_id_opt with
    | Some id -> id
    | None -> Sun_cli_registry.project_id_of_workspace workspace
  in
  with_registry (fun ops ->
    let resp = Sun_cli_control_plane.handle ops
      (Sun_cli_control_plane.get_releases ~project_id ~page ~page_size ()) in
    if resp.Sun_cli_control_plane.status <> 200 then begin
      let open Yojson.Safe.Util in
      let msg = resp.body |> member "error" |> to_string_option
        |> Option.value ~default:"unknown error" in
      Printf.eprintf "error: %s\n" msg;
      exit 1
    end else begin
      let open Yojson.Safe.Util in
      let releases = resp.body |> member "releases" |> to_list in
      let total    = resp.body |> member "total" |> to_int in
      if releases = [] then
        Printf.printf "No releases found for project %s.\n%!" project_id
      else begin
        Printf.printf "%-22s  %-10s  %-12s  %-10s  %s\n%!"
          "RELEASE ID" "STATUS" "IMAGE TAG" "ENV" "CREATED AT";
        Printf.printf "%s\n%!" (String.make 80 '-');
        List.iter (fun r ->
          let id         = r |> member "release_id"  |> to_string in
          let status     = r |> member "status"       |> to_string in
          let image_tag  = r |> member "image_tag"    |> to_string in
          let env        = r |> member "environment"  |> to_string in
          let created_at = r |> member "created_at"   |> to_string in
          Printf.printf "%-22s  %-10s  %-12s  %-10s  %s\n%!"
            id status image_tag env created_at
        ) releases;
        Printf.printf "\n%d total release(s), page %d (page_size %d)\n%!"
          total page page_size
      end
    end
  )

let releases_project_arg =
  Arg.(value & opt (some string) None &
       info ["project"] ~docv:"ID"
         ~doc:"Project ID to list releases for (default: derived from current workspace)")

let releases_page_arg =
  Arg.(value & opt int 1 &
       info ["page"] ~docv:"N"
         ~doc:"Page number (1-based, default: 1)")

let releases_page_size_arg =
  Arg.(value & opt int 20 &
       info ["page-size"] ~docv:"N"
         ~doc:"Results per page (default: 20)")

let releases_cmd =
  Cmd.v
    (Cmd.info "releases"
       ~doc:"List recent hosted releases for a project.")
    Term.(const cloud_releases $ releases_project_arg
          $ releases_page_arg $ releases_page_size_arg)

(* ── cloud logs ──────────────────────────────────────────────────────────── *)

let cloud_logs release_id =
  let workspace = Filename.basename (Sys.getcwd ()) in
  let project_id = Sun_cli_registry.project_id_of_workspace workspace in
  with_registry (fun ops ->
    let resp = Sun_cli_control_plane.handle ops
      (Sun_cli_control_plane.get_release_logs ~project_id ~release_id) in
    if resp.Sun_cli_control_plane.status <> 200 then begin
      let open Yojson.Safe.Util in
      let msg = resp.body |> member "error" |> to_string_option
        |> Option.value ~default:"unknown error" in
      Printf.eprintf "error: %s\n" msg;
      exit 1
    end else begin
      let open Yojson.Safe.Util in
      let lines = resp.body |> member "lines" |> to_list in
      List.iter (fun l -> print_endline (l |> to_string)) lines;
      flush stdout
    end
  )

let logs_release_arg =
  Arg.(required & opt (some string) None &
       info ["release"] ~docv:"ID"
         ~doc:"Release ID to retrieve logs for")

let logs_cmd =
  Cmd.v
    (Cmd.info "logs"
       ~doc:"Stream the deploy log for a specific release.")
    Term.(const cloud_logs $ logs_release_arg)

let cmd =
  Cmd.group
    (Cmd.info "cloud"
       ~doc:"Manage cloud infrastructure and hosted deployments")
    [ init_cmd; deploy_cmd; releases_cmd; logs_cmd ]
