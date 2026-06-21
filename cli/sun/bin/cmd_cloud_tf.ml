(* sun cloud init — provision cloud infrastructure via Terraform.
   Wraps `terraform init && terraform apply` for AWS or GCP.
   Requires: terraform binary in PATH, cloud credentials in environment. *)

open Cmdliner

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
let print_outputs infra_dir =
  match Sun_cli_terraform.output_json ~chdir:infra_dir with
  | Error _ | Ok { Sun_cli_process.exit_code = (1 | 2 | 127 | 128); _ } ->
    Printf.printf "  (could not retrieve terraform outputs)\n%!"
  | Ok r when r.Sun_cli_process.exit_code <> 0 ->
    Printf.printf "  (could not retrieve terraform outputs)\n%!"
  | Ok r ->
    (try
      let print_output_field key obj =
        match obj with
        | `Assoc fields ->
          let sensitive = match List.assoc_opt "sensitive" fields with
            | Some (`Bool b) -> b
            | _ -> true
          in
          if not sensitive then
            (match List.assoc_opt "value" fields with
             | Some (`String v) ->
               Printf.printf "  %-28s  %s\n%!" key v
             | Some (`List vs) ->
               let strs = List.filter_map (function `String s -> Some s | _ -> None) vs in
               if strs <> [] then
                 Printf.printf "  %-28s  [%s]\n%!" key (String.concat ", " strs)
             | Some `Null ->
               Printf.printf "  %-28s  (none)\n%!" key
             | _ -> ())
        | _ -> ()
      in
      let json = Yojson.Safe.from_string r.Sun_cli_process.stdout in
      (match json with
       | `Assoc pairs -> List.iter (fun (key, obj) -> print_output_field key obj) pairs
       | _ -> ())
    with _ ->
      Printf.printf "  (error parsing terraform outputs)\n%!")

(* ── cloud init ─────────────────────────────────────────────────────────── *)

type provider = Aws | Gcp

let provider_name = function Aws -> "aws" | Gcp -> "gcp"

let cloud_init ~provider ~var_file ~dry_run () =
  let pname = provider_name provider in

  (* Check prerequisites *)
  if not (Sun_cli_terraform.which_check ()) then begin
    Printf.eprintf "error: %S not found in PATH.\n" "terraform";
    Printf.eprintf "  Install: %s\n" "https://developer.hashicorp.com/terraform/install";
    exit 1
  end;

  (* Locate terraform module directory *)
  let sun_home = resolve_sun_home () in
  let infra_dir = Filename.concat sun_home
    (Printf.sprintf "platform/infra/%s" pname) in
  if not (Sys.file_exists infra_dir) then begin
    Printf.eprintf "error: Terraform module not found: %s\n" infra_dir;
    exit 1
  end;

  Printf.printf "\nInitializing cloud infrastructure (%s)...\n%!" pname;

  let exit_code_of r = match r with
    | Ok r -> r.Sun_cli_process.exit_code
    | Error _ -> 1
  in

  (* Step 1: terraform init *)
  Printf.printf "\n[1/3] terraform init\n%!";
  let rc = exit_code_of (Sun_cli_terraform.init ~chdir:infra_dir) in
  if rc <> 0 then begin
    Printf.eprintf "error: terraform init failed (exit %d).\n" rc;
    exit 1
  end;

  (* Step 2: terraform plan or apply *)
  if dry_run then begin
    Printf.printf "\n[2/3] terraform plan  (--dry-run)\n%!";
    let var_files = match var_file with None -> [] | Some f -> [f] in
    let rc = exit_code_of (Sun_cli_terraform.plan ~chdir:infra_dir ~var_files) in
    if rc <> 0 then begin
      Printf.eprintf "error: terraform plan failed (exit %d).\n" rc;
      exit 1
    end;
    Printf.printf "\n[3/3] (skipping apply in --dry-run mode)\n%!";
  end else begin
    Printf.printf "\n[2/3] terraform apply\n%!";
    let var_files = match var_file with None -> [] | Some f -> [f] in
    let rc = exit_code_of (Sun_cli_terraform.apply ~chdir:infra_dir ~var_files) in
    if rc <> 0 then begin
      Printf.eprintf "error: terraform apply failed (exit %d).\n" rc;
      exit 1
    end;

    (* Step 3: print outputs *)
    Printf.printf "\n[3/3] Provisioned endpoints:\n%!";
    print_outputs infra_dir;
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

let provider_term =
  let combine aws gcp = match aws, gcp with
    | true,  false -> `Ok Aws
    | false, true  -> `Ok Gcp
    | true,  true  -> `Error (false, "--aws and --gcp are mutually exclusive")
    | false, false -> `Error (false, "specify --aws or --gcp")
  in
  Term.(ret (const combine $ aws_flag $ gcp_flag))

let init_cmd =
  Cmd.v
    (Cmd.info "init"
       ~doc:"Provision cloud infrastructure via Terraform. \
             Requires the terraform binary in PATH and cloud credentials \
             in the environment (AWS_* or GOOGLE_* variables).")
    Term.(const (fun provider var_file dry_run ->
        cloud_init ~provider ~var_file ~dry_run ())
      $ provider_term $ var_file_arg $ dry_run_flag)
