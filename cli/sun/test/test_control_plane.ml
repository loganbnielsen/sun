let check_int    = Alcotest.(check int)
let check_string = Alcotest.(check string)

(* Build a vtable backed by an in-memory registry *)
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
  }

(* ── POST /projects ─────────────────────────────────────────────────────── *)

let test_post_projects_creates () =
  let ops = memory_ops () in
  let resp =
    Sun_cli_control_plane.handle ops
      (Sun_cli_control_plane.post_projects ~workspace:"pluto")
  in
  check_int "status 201" 201 resp.Sun_cli_control_plane.status;
  let open Yojson.Safe.Util in
  check_string "project_id" "proj-pluto"
    (resp.body |> member "project_id" |> to_string)

let test_post_projects_idempotent () =
  let ops = memory_ops () in
  let req = Sun_cli_control_plane.post_projects ~workspace:"pluto" in
  let r1 = Sun_cli_control_plane.handle ops req in
  let r2 = Sun_cli_control_plane.handle ops req in
  check_int "both 201" r1.status r2.status;
  let open Yojson.Safe.Util in
  check_string "same id"
    (r1.body |> member "project_id" |> to_string)
    (r2.body |> member "project_id" |> to_string)

let test_post_projects_missing_body () =
  let ops = memory_ops () in
  let req = { Sun_cli_control_plane.meth = Post; path = "/projects"; body = None; params = [] } in
  let resp = Sun_cli_control_plane.handle ops req in
  check_int "status 400" 400 resp.status

(* ── GET /projects/{id} ─────────────────────────────────────────────────── *)

let test_get_project_returns_metadata () =
  let ops = memory_ops () in
  ignore (Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.post_projects ~workspace:"pluto"));
  let resp =
    Sun_cli_control_plane.handle ops
      (Sun_cli_control_plane.get_project ~project_id:"proj-pluto")
  in
  check_int "status 200" 200 resp.status;
  let open Yojson.Safe.Util in
  check_string "workspace" "pluto"
    (resp.body |> member "project" |> member "workspace" |> to_string)

let test_get_project_includes_release_ids () =
  let ops = memory_ops () in
  ignore (Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.post_projects ~workspace:"pluto"));
  ignore (Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.post_release
      ~project_id:"proj-pluto"
      ~environment:"production"
      ~image_tag:"abc123"
      ~service_names:["charge-svc"]));
  let resp =
    Sun_cli_control_plane.handle ops
      (Sun_cli_control_plane.get_project ~project_id:"proj-pluto")
  in
  let open Yojson.Safe.Util in
  check_int "one release_id" 1
    (resp.body |> member "release_ids" |> to_list |> List.length)

let test_get_project_not_found () =
  let ops = memory_ops () in
  let resp =
    Sun_cli_control_plane.handle ops
      (Sun_cli_control_plane.get_project ~project_id:"proj-ghost")
  in
  check_int "status 404" 404 resp.status

(* ── POST /projects/{id}/releases ───────────────────────────────────────── *)

let test_post_release_creates () =
  let ops = memory_ops () in
  ignore (Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.post_projects ~workspace:"pluto"));
  let resp =
    Sun_cli_control_plane.handle ops
      (Sun_cli_control_plane.post_release
        ~project_id:"proj-pluto"
        ~environment:"production"
        ~image_tag:"abc123"
        ~service_names:["charge-svc"; "notify-worker"])
  in
  check_int "status 201" 201 resp.status;
  let open Yojson.Safe.Util in
  check_string "status" "live"
    (resp.body |> member "status" |> to_string);
  check_string "environment" "production"
    (resp.body |> member "environment" |> to_string);
  check_int "service count" 2
    (resp.body |> member "services" |> to_list |> List.length)

let test_post_release_unknown_project () =
  let ops = memory_ops () in
  let resp =
    Sun_cli_control_plane.handle ops
      (Sun_cli_control_plane.post_release
        ~project_id:"proj-ghost"
        ~environment:"production"
        ~image_tag:"abc"
        ~service_names:[])
  in
  check_int "status 400" 400 resp.status

let test_post_release_missing_body () =
  let ops = memory_ops () in
  ignore (Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.post_projects ~workspace:"pluto"));
  let req = {
    Sun_cli_control_plane.meth = Post;
    path = "/projects/proj-pluto/releases";
    body = None;
    params = [];
  } in
  let resp = Sun_cli_control_plane.handle ops req in
  check_int "status 400" 400 resp.status

(* ── unknown routes ─────────────────────────────────────────────────────── *)

let test_unknown_route () =
  let ops = memory_ops () in
  let req = { Sun_cli_control_plane.meth = Get; path = "/unknown"; body = None; params = [] } in
  let resp = Sun_cli_control_plane.handle ops req in
  check_int "status 404" 404 resp.status

let () =
  Alcotest.run "control_plane"
    [ "POST /projects", [
        Alcotest.test_case "creates project" `Quick test_post_projects_creates;
        Alcotest.test_case "idempotent" `Quick test_post_projects_idempotent;
        Alcotest.test_case "missing body" `Quick test_post_projects_missing_body;
      ];
      "GET /projects/{id}", [
        Alcotest.test_case "returns metadata" `Quick test_get_project_returns_metadata;
        Alcotest.test_case "includes release ids" `Quick test_get_project_includes_release_ids;
        Alcotest.test_case "not found" `Quick test_get_project_not_found;
      ];
      "POST /projects/{id}/releases", [
        Alcotest.test_case "creates release" `Quick test_post_release_creates;
        Alcotest.test_case "unknown project" `Quick test_post_release_unknown_project;
        Alcotest.test_case "missing body" `Quick test_post_release_missing_body;
      ];
      "routing", [
        Alcotest.test_case "unknown route" `Quick test_unknown_route;
      ];
    ]
