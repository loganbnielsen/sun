(* sun cloud init — provision cloud infrastructure via Terraform.
   Wraps `terraform init && terraform apply` for AWS or GCP.
   Requires: terraform binary in PATH, cloud credentials in environment. *)

open Cmdliner

let cmd_ok cmd = Sun_cli_shell.run_cmd ~echo:false cmd = 0

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

(* Read terraform output -json from a temp file and print key endpoints.
   We only print non-sensitive string/list values. *)
let print_outputs chdir_arg =
  let tmp = Filename.temp_file "sun-tf-out-" ".json" in
  let rc = Sys.command (Printf.sprintf "terraform output -json %s > %s 2>/dev/null"
    chdir_arg (Filename.quote tmp))
  in
  if rc <> 0 then begin
    Printf.printf "  (could not retrieve terraform outputs)\n%!";
    (try Sys.remove tmp with _ -> ())
  end else begin
    (try
      let ic = open_in tmp in
      let raw = In_channel.input_all ic in
      close_in ic;
      Sys.remove tmp;
      (* Very lightweight JSON parse: find "key": { "sensitive": false,
         "value": "..." } entries and print them. We use Yojson. *)
      let json = Yojson.Safe.from_string raw in
      (match json with
       | `Assoc pairs ->
         List.iter (fun (key, obj) ->
           match obj with
           | `Assoc fields ->
             let sensitive =
               match List.assoc_opt "sensitive" fields with
               | Some (`Bool b) -> b
               | _ -> true  (* default to sensitive if unknown *)
             in
             if not sensitive then begin
               match List.assoc_opt "value" fields with
               | Some (`String v) ->
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
         ) pairs
       | _ -> ())
    with _ ->
      Printf.printf "  (error parsing terraform outputs)\n%!")
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
  let rc = Sun_cli_shell.run_cmd (Printf.sprintf "terraform init %s" chdir_arg) in
  if rc <> 0 then begin
    Printf.eprintf "error: terraform init failed (exit %d).\n" rc;
    exit 1
  end;

  (* Step 2: terraform plan or apply *)
  if dry_run then begin
    Printf.printf "\n[2/3] terraform plan  (--dry-run)\n%!";
    let rc = Sun_cli_shell.run_cmd (Printf.sprintf "terraform plan %s%s"
      chdir_arg varfile_args) in
    if rc <> 0 then begin
      Printf.eprintf "error: terraform plan failed (exit %d).\n" rc;
      exit 1
    end;
    Printf.printf "\n[3/3] (skipping apply in --dry-run mode)\n%!";
  end else begin
    Printf.printf "\n[2/3] terraform apply\n%!";
    let rc = Sun_cli_shell.run_cmd (Printf.sprintf "terraform apply -auto-approve %s%s"
      chdir_arg varfile_args) in
    if rc <> 0 then begin
      Printf.eprintf "error: terraform apply failed (exit %d).\n" rc;
      exit 1
    end;

    (* Step 3: print outputs *)
    Printf.printf "\n[3/3] Provisioned endpoints:\n%!";
    print_outputs chdir_arg;
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

(* ── Postgres-backed registry (implementation in lib/sun_cli_pg_registry.ml) ── *)

module Pg_registry = Sun_cli_pg_registry


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
    update_service_digest = (fun rid svc img dig ->
                               Sun_cli_registry.update_service_digest r rid
                                 ~service_name:svc ~image_ref:img ~digest_str:dig);
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
      let built = ref [] in
      let all_ok = List.for_all (fun (svc : Sun_cli_manifest.service) ->
        let svc_name = Sun_cli_deployment_plan.k8s_name_of svc.name in
        let image_ref = Printf.sprintf "%s/%s/%s:%s" reg workspace svc_name sha in
        let log line = ops.Sun_cli_control_plane.append_log_line release_id line in
        match builder.build_and_push
            ~workspace_path ~service_dir:svc.dir ~image_ref ~log with
        | Error msg ->
          ops.Sun_cli_control_plane.append_log_line release_id
            (Printf.sprintf "[deploy] build failed: %s" msg);
          false
        | Ok result ->
          ignore (ops.Sun_cli_control_plane.update_service_digest
            release_id svc_name result.image_tag result.digest);
          built := { Sun_cli_registry.
            service_name = svc_name;
            service_status = Sun_cli_registry.Service_live;
            image = Some result.image_tag;
            digest = Some result.digest;
          } :: !built;
          true
      ) services in
      if all_ok then begin
        ops.Sun_cli_control_plane.append_log_line release_id
          "[deploy] release complete: status=live";
        let updated_release = { release with
          Sun_cli_registry.services = List.rev !built;
          digest = None;
        } in
        if output_json then
          print_string (Yojson.Safe.pretty_to_string
            (Sun_cli_registry.release_to_json updated_release))
        else begin
          Printf.printf "Release:  %s\n" release_id;
          List.iter (fun (s : Sun_cli_registry.release_service) ->
            match s.digest with
            | None -> ()
            | Some d ->
              Printf.printf "  %s: %s\n" s.service_name d
          ) (List.rev !built);
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
