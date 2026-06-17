(* Hosted deploy build/push orchestration for `sun cloud deploy`. *)

open Cmdliner

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
    Cmd_cloud_registry.with_registry (fun ops ->
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
        ignore (ops.Sun_cli_control_plane.update_release_status release_id Sun_cli_registry.Failed);
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
