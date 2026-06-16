(* Hosted release listing and log display for `sun cloud`. *)

open Cmdliner

(* ── cloud releases ──────────────────────────────────────────────────────── *)

let cloud_releases project_id_opt page page_size =
  let workspace = Filename.basename (Sys.getcwd ()) in
  let project_id = match project_id_opt with
    | Some id -> id
    | None -> Sun_cli_registry.project_id_of_workspace workspace
  in
  Cmd_cloud_registry.with_registry (fun ops ->
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
  Cmd_cloud_registry.with_registry (fun ops ->
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
