let get_ok = function
  | Ok v -> v
  | Error msg -> Alcotest.fail msg

let get_error = function
  | Ok _ -> Alcotest.fail "expected Error"
  | Error msg -> msg

let check_string = Alcotest.(check string)
let check_int    = Alcotest.(check int)
let check_bool   = Alcotest.(check bool)

(* ── create project ─────────────────────────────────────────────────────── *)

let test_create_project () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto" |> get_ok in
  check_string "workspace" "pluto" p.Sun_cli_registry.workspace;
  check_string "project_id" "proj-pluto" p.Sun_cli_registry.project_id

let test_create_project_idempotent () =
  let r = Sun_cli_registry.create () in
  let p1 = Sun_cli_registry.create_project r ~workspace:"pluto" |> get_ok in
  let p2 = Sun_cli_registry.create_project r ~workspace:"pluto" |> get_ok in
  check_string "same id" p1.Sun_cli_registry.project_id p2.Sun_cli_registry.project_id

let test_create_project_normalizes_workspace () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"My_Workspace" |> get_ok in
  check_string "project_id" "proj-my-workspace" p.Sun_cli_registry.project_id

let test_get_project () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto" |> get_ok in
  let found = Sun_cli_registry.get_project r p.Sun_cli_registry.project_id |> get_ok in
  check_string "workspace" "pluto" found.Sun_cli_registry.workspace

let test_get_project_not_found () =
  let r = Sun_cli_registry.create () in
  let msg = Sun_cli_registry.get_project r "proj-unknown" |> get_error in
  check_bool "error contains id" true
    (let needle = "proj-unknown" in
     let s = msg in
     let nl = String.length needle in
     let sl = String.length s in
     let rec go i =
       if i > sl - nl then false
       else if String.sub s i nl = needle then true
       else go (i + 1)
     in
     go 0)

let test_list_projects () =
  let r = Sun_cli_registry.create () in
  ignore (Sun_cli_registry.create_project r ~workspace:"pluto" |> get_ok);
  ignore (Sun_cli_registry.create_project r ~workspace:"venus" |> get_ok);
  let projects = Sun_cli_registry.list_projects r in
  check_int "count" 2 (List.length projects)

(* ── create release ─────────────────────────────────────────────────────── *)

let test_create_release () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto" |> get_ok in
  let rel = Sun_cli_registry.create_release r
      ~project_id:p.Sun_cli_registry.project_id
      ~environment:"production"
      ~image_tag:"abc123"
      ~service_names:["charge-svc"; "notify-worker"]
    |> get_ok
  in
  check_string "project_id" p.Sun_cli_registry.project_id
    rel.Sun_cli_registry.project_id;
  check_string "environment" "production" rel.Sun_cli_registry.environment;
  check_string "image_tag" "abc123" rel.Sun_cli_registry.image_tag;
  check_string "status" "live"
    (Sun_cli_registry.release_status_to_string rel.Sun_cli_registry.status);
  check_int "service count" 2
    (List.length rel.Sun_cli_registry.services)

let test_create_release_increments_id () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto" |> get_ok in
  let pid = p.Sun_cli_registry.project_id in
  let rel1 = Sun_cli_registry.create_release r ~project_id:pid
      ~environment:"production" ~image_tag:"abc" ~service_names:[] |> get_ok in
  let rel2 = Sun_cli_registry.create_release r ~project_id:pid
      ~environment:"production" ~image_tag:"def" ~service_names:[] |> get_ok in
  check_bool "different ids" true
    (rel1.Sun_cli_registry.release_id <> rel2.Sun_cli_registry.release_id)

let test_create_release_unknown_project () =
  let r = Sun_cli_registry.create () in
  let msg = Sun_cli_registry.create_release r
      ~project_id:"proj-ghost"
      ~environment:"production"
      ~image_tag:"abc"
      ~service_names:[]
    |> get_error
  in
  check_bool "error contains id" true (String.length msg > 0)

(* ── list releases ──────────────────────────────────────────────────────── *)

let test_list_releases () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto" |> get_ok in
  let pid = p.Sun_cli_registry.project_id in
  ignore (Sun_cli_registry.create_release r ~project_id:pid
    ~environment:"production" ~image_tag:"abc" ~service_names:[] |> get_ok);
  ignore (Sun_cli_registry.create_release r ~project_id:pid
    ~environment:"staging" ~image_tag:"def" ~service_names:[] |> get_ok);
  let releases = Sun_cli_registry.list_releases r ~project_id:pid |> get_ok in
  check_int "count" 2 (List.length releases)

let test_list_releases_isolation () =
  let r = Sun_cli_registry.create () in
  let p1 = Sun_cli_registry.create_project r ~workspace:"pluto" |> get_ok in
  let p2 = Sun_cli_registry.create_project r ~workspace:"venus" |> get_ok in
  ignore (Sun_cli_registry.create_release r
    ~project_id:p1.Sun_cli_registry.project_id
    ~environment:"production" ~image_tag:"a" ~service_names:[] |> get_ok);
  ignore (Sun_cli_registry.create_release r
    ~project_id:p2.Sun_cli_registry.project_id
    ~environment:"production" ~image_tag:"b" ~service_names:[] |> get_ok);
  let rels1 = Sun_cli_registry.list_releases r
    ~project_id:p1.Sun_cli_registry.project_id |> get_ok in
  let rels2 = Sun_cli_registry.list_releases r
    ~project_id:p2.Sun_cli_registry.project_id |> get_ok in
  check_int "p1 releases" 1 (List.length rels1);
  check_int "p2 releases" 1 (List.length rels2)

(* ── get release ────────────────────────────────────────────────────────── *)

let test_get_release () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto" |> get_ok in
  let rel = Sun_cli_registry.create_release r
      ~project_id:p.Sun_cli_registry.project_id
      ~environment:"production" ~image_tag:"abc" ~service_names:[] |> get_ok in
  let found = Sun_cli_registry.get_release r rel.Sun_cli_registry.release_id |> get_ok in
  check_string "release_id" rel.Sun_cli_registry.release_id
    found.Sun_cli_registry.release_id

let test_get_release_not_found () =
  let r = Sun_cli_registry.create () in
  let msg = Sun_cli_registry.get_release r "rel-unknown" |> get_error in
  check_bool "error contains id" true (String.length msg > 0)

(* ── JSON ───────────────────────────────────────────────────────────────── *)

let test_project_to_json () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto" |> get_ok in
  let json = Sun_cli_registry.project_to_json p in
  let open Yojson.Safe.Util in
  check_string "project_id" "proj-pluto"
    (json |> member "project_id" |> to_string);
  check_string "workspace" "pluto"
    (json |> member "workspace" |> to_string)

let test_release_to_json () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto" |> get_ok in
  let rel = Sun_cli_registry.create_release r
      ~project_id:p.Sun_cli_registry.project_id
      ~environment:"production"
      ~image_tag:"abc123"
      ~service_names:["charge-svc"]
    |> get_ok
  in
  let json = Sun_cli_registry.release_to_json rel in
  let open Yojson.Safe.Util in
  check_string "status" "live" (json |> member "status" |> to_string);
  check_string "environment" "production" (json |> member "environment" |> to_string);
  check_string "image_tag" "abc123" (json |> member "image_tag" |> to_string);
  check_int "service count" 1
    (json |> member "services" |> to_list |> List.length);
  check_string "service status" "live"
    (json |> member "services" |> index 0 |> member "status" |> to_string)

(* ── project_id_of_workspace ────────────────────────────────────────────── *)

let test_project_id_of_workspace () =
  check_string "simple" "proj-pluto"
    (Sun_cli_registry.project_id_of_workspace "pluto");
  check_string "underscores" "proj-my-workspace"
    (Sun_cli_registry.project_id_of_workspace "My_Workspace");
  check_string "uppercase" "proj-venus"
    (Sun_cli_registry.project_id_of_workspace "VENUS")

let () =
  Alcotest.run "registry"
    [ "create_project", [
        Alcotest.test_case "basic" `Quick test_create_project;
        Alcotest.test_case "idempotent" `Quick test_create_project_idempotent;
        Alcotest.test_case "normalizes workspace" `Quick test_create_project_normalizes_workspace;
        Alcotest.test_case "get project" `Quick test_get_project;
        Alcotest.test_case "get not found" `Quick test_get_project_not_found;
        Alcotest.test_case "list projects" `Quick test_list_projects;
      ];
      "create_release", [
        Alcotest.test_case "basic" `Quick test_create_release;
        Alcotest.test_case "increments id" `Quick test_create_release_increments_id;
        Alcotest.test_case "unknown project" `Quick test_create_release_unknown_project;
      ];
      "list_releases", [
        Alcotest.test_case "basic" `Quick test_list_releases;
        Alcotest.test_case "isolation" `Quick test_list_releases_isolation;
      ];
      "get_release", [
        Alcotest.test_case "basic" `Quick test_get_release;
        Alcotest.test_case "not found" `Quick test_get_release_not_found;
      ];
      "json", [
        Alcotest.test_case "project_to_json" `Quick test_project_to_json;
        Alcotest.test_case "release_to_json" `Quick test_release_to_json;
      ];
      "project_id_of_workspace", [
        Alcotest.test_case "normalization" `Quick test_project_id_of_workspace;
      ];
    ]
