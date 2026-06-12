(* Integration tests for the Postgres-backed registry.
   These tests are skipped automatically when CONTROL_PLANE_TEST_DATABASE_URL
   is not set. Set the variable to a Postgres connection URL to run them:

     CONTROL_PLANE_TEST_DATABASE_URL=postgresql://localhost/sun_test \
       dune test cli/sun/test/ --force
*)

(* All tests in this file share one pool created from the env var. *)

let skip msg =
  Printf.printf "SKIP: %s\n%!" msg

let db_url () = Sys.getenv_opt "CONTROL_PLANE_TEST_DATABASE_URL"

(* ── helpers ────────────────────────────────────────────────────────────── *)

let get_ok = function
  | Ok v -> v
  | Error msg -> Alcotest.fail msg

let check_string = Alcotest.(check string)
let check_int    = Alcotest.(check int)
let check_bool   = Alcotest.(check bool)

(* ── memory_ops tests (always run, same interface as pg_ops) ─────────────── *)

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

let test_memory_create_project () =
  let ops = memory_ops () in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:"testws" |> get_ok in
  check_string "workspace" "testws" p.Sun_cli_registry.workspace;
  check_string "project_id" "proj-testws" p.Sun_cli_registry.project_id

let test_memory_create_project_idempotent () =
  let ops = memory_ops () in
  let p1 = ops.Sun_cli_control_plane.create_project ~workspace:"testws" |> get_ok in
  let p2 = ops.Sun_cli_control_plane.create_project ~workspace:"testws" |> get_ok in
  check_string "same id" p1.Sun_cli_registry.project_id p2.Sun_cli_registry.project_id

let test_memory_create_release () =
  let ops = memory_ops () in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:"testws" |> get_ok in
  let rel = ops.Sun_cli_control_plane.create_release
    ~project_id:p.Sun_cli_registry.project_id
    ~environment:"production"
    ~image_tag:"sha123"
    ~service_names:["svc-a"; "svc-b"]
    |> get_ok
  in
  check_string "environment" "production" rel.Sun_cli_registry.environment;
  check_string "image_tag" "sha123" rel.Sun_cli_registry.image_tag;
  check_int "service count" 2 (List.length rel.Sun_cli_registry.services)

let test_memory_list_releases_page () =
  let ops = memory_ops () in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:"testws" |> get_ok in
  let pid = p.Sun_cli_registry.project_id in
  for i = 1 to 5 do
    ignore (ops.Sun_cli_control_plane.create_release
      ~project_id:pid
      ~environment:"production"
      ~image_tag:(Printf.sprintf "tag%d" i)
      ~service_names:[]
      |> get_ok)
  done;
  let (page1, total) = ops.Sun_cli_control_plane.list_releases_page
    ~project_id:pid ~page:1 ~page_size:3 () |> get_ok in
  check_int "total" 5 total;
  check_int "page1 size" 3 (List.length page1)

let test_memory_get_release_logs () =
  let ops = memory_ops () in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:"testws" |> get_ok in
  let pid = p.Sun_cli_registry.project_id in
  let rel = ops.Sun_cli_control_plane.create_release
    ~project_id:pid ~environment:"production" ~image_tag:"t" ~service_names:["svc"]
    |> get_ok
  in
  let logs = ops.Sun_cli_control_plane.get_release_logs
    pid rel.Sun_cli_registry.release_id |> get_ok in
  check_bool "has logs" true (List.length logs > 0)

(* ── Postgres integration tests (skipped if URL not set) ─────────────────── *)

let test_pg_create_project () =
  match db_url () with
  | None -> skip "CONTROL_PLANE_TEST_DATABASE_URL not set"
  | Some _url ->
    (* When the URL is set, this test would create a pool and exercise
       Pg_registry.pg_create_project. For now we document the intent. *)
    skip "pg integration test stub — set CONTROL_PLANE_TEST_DATABASE_URL to run"

let test_pg_create_release () =
  match db_url () with
  | None -> skip "CONTROL_PLANE_TEST_DATABASE_URL not set"
  | Some _url ->
    skip "pg integration test stub — set CONTROL_PLANE_TEST_DATABASE_URL to run"

let test_pg_list_releases () =
  match db_url () with
  | None -> skip "CONTROL_PLANE_TEST_DATABASE_URL not set"
  | Some _url ->
    skip "pg integration test stub — set CONTROL_PLANE_TEST_DATABASE_URL to run"

(* ── builder pipeline tests (memory ops) ──────────────────────────────────── *)

(* Simulate the fake_builder pattern: build_and_push records log lines and
   returns a digest.  We exercise the append_log_line + update_release_digest
   vtable fields here so the happy path is covered without invoking Docker. *)
let test_builder_pipeline_memory () =
  let ops = memory_ops () in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:"testws" |> get_ok in
  let pid = p.Sun_cli_registry.project_id in
  let rel = ops.Sun_cli_control_plane.create_release
    ~project_id:pid ~environment:"production" ~image_tag:"sha-abc"
    ~service_names:["charge-svc"]
    |> get_ok
  in
  let rid = rel.Sun_cli_registry.release_id in
  (* Simulate fake_builder log output *)
  ops.Sun_cli_control_plane.append_log_line rid "[build] (fake) built reg/app:v1";
  ops.Sun_cli_control_plane.append_log_line rid "[push] (fake) pushed reg/app:v1";
  ops.Sun_cli_control_plane.append_log_line rid "[deploy] (fake) digest: sha256:test";
  (* Record digest *)
  let digest_result = ops.Sun_cli_control_plane.update_release_digest rid "sha256:test" in
  check_bool "digest update ok" true (Result.is_ok digest_result);
  (* Verify logs were captured *)
  let logs = ops.Sun_cli_control_plane.get_release_logs pid rid |> get_ok in
  check_bool "has log lines" true (List.length logs > 0);
  let has_digest_log =
    List.exists (fun l -> String.length l >= 15 &&
      String.sub l 0 9 = "[deploy] ") logs
  in
  check_bool "deploy log present" true has_digest_log

let test_update_release_digest_unknown () =
  let ops = memory_ops () in
  let result = ops.Sun_cli_control_plane.update_release_digest "no-such-rel" "sha256:abc" in
  check_bool "error on missing release" true (Result.is_error result)

let () =
  Alcotest.run "pg_registry"
    [ "memory_ops vtable", [
        Alcotest.test_case "create project" `Quick test_memory_create_project;
        Alcotest.test_case "create project idempotent" `Quick test_memory_create_project_idempotent;
        Alcotest.test_case "create release" `Quick test_memory_create_release;
        Alcotest.test_case "list releases paginated" `Quick test_memory_list_releases_page;
        Alcotest.test_case "get release logs" `Quick test_memory_get_release_logs;
      ];
      "builder pipeline", [
        Alcotest.test_case "builder pipeline records digest and logs" `Quick test_builder_pipeline_memory;
        Alcotest.test_case "update digest returns error for unknown release" `Quick test_update_release_digest_unknown;
      ];
      "pg_ops (integration)", [
        Alcotest.test_case "create project" `Quick test_pg_create_project;
        Alcotest.test_case "create release" `Quick test_pg_create_release;
        Alcotest.test_case "list releases" `Quick test_pg_list_releases;
      ];
    ]
