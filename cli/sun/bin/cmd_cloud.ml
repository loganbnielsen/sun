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

let cloud_deploy environment image_tag dry_run output_json =
  let workspace = Filename.basename (Sys.getcwd ()) in
  let sha = match image_tag with Some t -> t | None -> git_sha () in

  let registry = Sun_cli_registry.create () in
  let project = Sun_cli_registry.create_project registry ~workspace
    |> get_ok_or_exit in

  if dry_run then begin
    Printf.printf "Project:  %s\nEnv:      %s\nTag:      %s\n"
      project.Sun_cli_registry.project_id environment sha;
    Printf.printf "(dry-run: no release recorded)\n%!"
  end else begin
    let services = Sun_cli_manifest.discover_services ~filter_path:None in
    let service_names =
      List.map (fun (s : Sun_cli_manifest.service) ->
        Sun_cli_deployment_plan.k8s_name_of s.name)
        services
    in
    let release = Sun_cli_registry.create_release registry
        ~project_id:project.Sun_cli_registry.project_id
        ~environment
        ~image_tag:sha
        ~service_names
      |> get_ok_or_exit
    in
    if output_json then
      print_string (Yojson.Safe.pretty_to_string
        (Sun_cli_registry.release_to_json release))
    else begin
      Printf.printf "Release:  %s\n" release.Sun_cli_registry.release_id;
      Printf.printf "Project:  %s\n" release.Sun_cli_registry.project_id;
      Printf.printf "Env:      %s\n" release.Sun_cli_registry.environment;
      Printf.printf "Tag:      %s\n" release.Sun_cli_registry.image_tag;
      Printf.printf "Status:   %s\n"
        (Sun_cli_registry.release_status_to_string release.Sun_cli_registry.status);
      if release.Sun_cli_registry.services <> [] then begin
        Printf.printf "Services:\n";
        List.iter (fun (s : Sun_cli_registry.release_service) ->
          Printf.printf "  %-30s  %s\n"
            s.service_name
            (Sun_cli_registry.service_status_to_string s.service_status))
          release.Sun_cli_registry.services
      end
    end;
    print_char '\n'; flush stdout
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
         ~doc:"Print project/env/tag without recording a release")

let output_json_flag =
  Arg.(value & flag &
       info ["output-json"]
         ~doc:"Print the release record as JSON")

let deploy_cmd =
  Cmd.v
    (Cmd.info "deploy"
       ~doc:"Record a hosted release in the project registry. \
             Creates the project if it does not exist, then records a new \
             release with status=live. Use --dry-run to preview without \
             recording.")
    Term.(const cloud_deploy $ environment_arg $ cloud_image_tag_arg
          $ cloud_dry_run_flag $ output_json_flag)

let cmd =
  Cmd.group
    (Cmd.info "cloud"
       ~doc:"Manage cloud infrastructure and hosted deployments")
    [ init_cmd; deploy_cmd ]
