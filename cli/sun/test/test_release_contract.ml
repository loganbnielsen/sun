(** Contract tests for POST /projects/{id}/releases response shape.

    These tests pin the exact fields and types of the release API response so
    that callers (sun cloud deploy, CLOUD-003 log/history) can rely on a
    stable contract. *)

let check_string = Alcotest.(check string)
let check_int    = Alcotest.(check int)
let check_bool   = Alcotest.(check bool)

let setup () =
  let r = Sun_cli_registry.create () in
  ignore (Sun_cli_control_plane.handle r
    (Sun_cli_control_plane.post_projects ~workspace:"pluto"));
  r

let post_release ?(environment = "production") ?(image_tag = "abc123")
    ?(service_names = ["charge-svc"; "notify-worker"]) registry =
  Sun_cli_control_plane.handle registry
    (Sun_cli_control_plane.post_release
       ~project_id:"proj-pluto"
       ~environment
       ~image_tag
       ~service_names)

(* ── required top-level fields ─────────────────────────────────────────── *)

let test_response_has_release_id () =
  let r = setup () in
  let resp = post_release r in
  let open Yojson.Safe.Util in
  let release_id = resp.Sun_cli_control_plane.body |> member "release_id" |> to_string in
  check_bool "release_id non-empty" true (String.length release_id > 0)

let test_response_has_status () =
  let r = setup () in
  let resp = post_release r in
  let open Yojson.Safe.Util in
  let status = resp.body |> member "status" |> to_string in
  check_bool "status is valid" true
    (List.mem status ["queued"; "building"; "live"; "failed"])

let test_response_status_is_live () =
  let r = setup () in
  let resp = post_release r in
  let open Yojson.Safe.Util in
  check_string "stub status" "live"
    (resp.body |> member "status" |> to_string)

let test_response_has_created_at () =
  let r = setup () in
  let resp = post_release r in
  let open Yojson.Safe.Util in
  let created_at = resp.body |> member "created_at" |> to_string in
  check_bool "created_at non-empty" true (String.length created_at > 0)

let test_response_has_environment () =
  let r = setup () in
  let resp = post_release r ~environment:"staging" in
  let open Yojson.Safe.Util in
  check_string "environment" "staging"
    (resp.body |> member "environment" |> to_string)

let test_response_has_image_tag () =
  let r = setup () in
  let resp = post_release r ~image_tag:"sha256abc" in
  let open Yojson.Safe.Util in
  check_string "image_tag" "sha256abc"
    (resp.body |> member "image_tag" |> to_string)

(* ── services list ──────────────────────────────────────────────────────── *)

let test_services_list_present () =
  let r = setup () in
  let resp = post_release r in
  let open Yojson.Safe.Util in
  let svcs = resp.body |> member "services" |> to_list in
  check_int "service count" 2 (List.length svcs)

let test_service_has_name_and_status () =
  let r = setup () in
  let resp = post_release r ~service_names:["charge-svc"] in
  let open Yojson.Safe.Util in
  let svc = resp.body |> member "services" |> index 0 in
  check_string "service_name" "charge-svc" (svc |> member "service_name" |> to_string);
  check_string "service status" "live" (svc |> member "status" |> to_string)

let test_services_empty_list () =
  let r = setup () in
  let resp = post_release r ~service_names:[] in
  let open Yojson.Safe.Util in
  check_int "empty services" 0
    (resp.body |> member "services" |> to_list |> List.length)

(* ── HTTP status codes ──────────────────────────────────────────────────── *)

let test_well_formed_request_returns_201 () =
  let r = setup () in
  let resp = post_release r in
  check_int "http 201" 201 resp.Sun_cli_control_plane.status

let test_missing_body_returns_400 () =
  let r = setup () in
  let req = {
    Sun_cli_control_plane.meth = Post;
    path = "/projects/proj-pluto/releases";
    body = None;
    params = [];
  } in
  check_int "http 400" 400 (Sun_cli_control_plane.handle r req).status

let test_unknown_project_returns_400 () =
  let r = Sun_cli_registry.create () in
  let resp = Sun_cli_control_plane.handle r
    (Sun_cli_control_plane.post_release
       ~project_id:"proj-unknown"
       ~environment:"production"
       ~image_tag:"abc"
       ~service_names:[])
  in
  check_int "http 400" 400 resp.status

(* ── release JSON serialization ─────────────────────────────────────────── *)

let test_release_json_has_all_required_fields () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto" |> function
    | Ok p -> p | Error m -> Alcotest.fail m
  in
  let rel = Sun_cli_registry.create_release r
      ~project_id:p.Sun_cli_registry.project_id
      ~environment:"production"
      ~image_tag:"abc123"
      ~service_names:["charge-svc"]
    |> function Ok r -> r | Error m -> Alcotest.fail m
  in
  let json = Sun_cli_registry.release_to_json rel in
  let open Yojson.Safe.Util in
  let required = ["release_id"; "project_id"; "environment"; "image_tag";
                  "status"; "created_at"; "services"] in
  List.iter (fun field ->
    check_bool (Printf.sprintf "has field %s" field) true
      (json |> member field <> `Null)
  ) required

let () =
  Alcotest.run "release_contract"
    [ "required fields", [
        Alcotest.test_case "release_id present" `Quick test_response_has_release_id;
        Alcotest.test_case "status present" `Quick test_response_has_status;
        Alcotest.test_case "status=live stub" `Quick test_response_status_is_live;
        Alcotest.test_case "created_at present" `Quick test_response_has_created_at;
        Alcotest.test_case "environment echoed" `Quick test_response_has_environment;
        Alcotest.test_case "image_tag echoed" `Quick test_response_has_image_tag;
      ];
      "services list", [
        Alcotest.test_case "services present" `Quick test_services_list_present;
        Alcotest.test_case "per-service name+status" `Quick test_service_has_name_and_status;
        Alcotest.test_case "empty services" `Quick test_services_empty_list;
      ];
      "http status codes", [
        Alcotest.test_case "201 on success" `Quick test_well_formed_request_returns_201;
        Alcotest.test_case "400 on missing body" `Quick test_missing_body_returns_400;
        Alcotest.test_case "400 on unknown project" `Quick test_unknown_project_returns_400;
      ];
      "json shape", [
        Alcotest.test_case "all required fields" `Quick test_release_json_has_all_required_fields;
      ];
    ]
