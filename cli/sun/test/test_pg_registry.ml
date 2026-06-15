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
    update_service_digest = (fun rid svc img dig ->
                               Sun_cli_registry.update_service_digest r rid
                                 ~service_name:svc ~image_ref:img ~digest_str:dig);
    update_release_status = (fun rid s -> Sun_cli_registry.update_release_status r rid s);
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

(* Shared pool created once from CONTROL_PLANE_TEST_DATABASE_URL, if set. *)
let pg_pool () =
  match db_url () with
  | None -> None
  | Some url ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        match Db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
        | Error e ->
          Printf.eprintf "SKIP: cannot connect to test database: %s\n%!"
            (Storage_error.to_string e);
          None
        | Ok pool ->
          Sun_cli_pg_registry.ensure_schema pool;
          Some pool))

(* Use a time-based unique workspace prefix to isolate test rows. *)
let unique_ws () =
  Printf.sprintf "test-audit-059-%d" (int_of_float (Unix.gettimeofday () *. 1000.0))

let with_pg_pool f =
  match pg_pool () with
  | None -> skip "CONTROL_PLANE_TEST_DATABASE_URL not set"
  | Some pool ->
    let ws = unique_ws () in
    Fun.protect
      ~finally:(fun () ->
        let pid = Sun_cli_registry.project_id_of_workspace ws in
        Sun_cli_pg_registry.delete_project_rows pool pid)
      (fun () ->
        Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
            (* Re-open pool inside Eio runtime so fibers can use it *)
            match db_url () with
            | None -> skip "CONTROL_PLANE_TEST_DATABASE_URL not set"
            | Some url ->
              match Db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
              | Error e -> skip (Storage_error.to_string e)
              | Ok live_pool ->
                Sun_cli_pg_registry.ensure_schema live_pool;
                f live_pool ws)))

let test_pg_create_project () =
  with_pg_pool @@ fun pool ws ->
  let ops = Sun_cli_pg_registry.pg_ops pool in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:ws |> get_ok in
  check_string "workspace" ws p.Sun_cli_registry.workspace;
  check_bool "project_id non-empty" true (String.length p.Sun_cli_registry.project_id > 0)

let test_pg_create_project_idempotent () =
  with_pg_pool @@ fun pool ws ->
  let ops = Sun_cli_pg_registry.pg_ops pool in
  let p1 = ops.Sun_cli_control_plane.create_project ~workspace:ws |> get_ok in
  let p2 = ops.Sun_cli_control_plane.create_project ~workspace:ws |> get_ok in
  check_string "same project_id" p1.Sun_cli_registry.project_id
    p2.Sun_cli_registry.project_id

let test_pg_create_release () =
  with_pg_pool @@ fun pool ws ->
  let ops = Sun_cli_pg_registry.pg_ops pool in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:ws |> get_ok in
  let pid = p.Sun_cli_registry.project_id in
  let rel = ops.Sun_cli_control_plane.create_release
    ~project_id:pid ~environment:"production" ~image_tag:"sha123"
    ~service_names:["svc-a"; "svc-b"]
    |> get_ok
  in
  check_string "environment" "production" rel.Sun_cli_registry.environment;
  check_string "image_tag" "sha123" rel.Sun_cli_registry.image_tag;
  check_int "service count" 2 (List.length rel.Sun_cli_registry.services)

let test_pg_list_releases () =
  with_pg_pool @@ fun pool ws ->
  let ops = Sun_cli_pg_registry.pg_ops pool in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:ws |> get_ok in
  let pid = p.Sun_cli_registry.project_id in
  let rel = ops.Sun_cli_control_plane.create_release
    ~project_id:pid ~environment:"production" ~image_tag:"sha-list" ~service_names:[]
    |> get_ok
  in
  let releases = ops.Sun_cli_control_plane.list_releases ~project_id:pid |> get_ok in
  check_bool "at least one release" true (List.length releases >= 1);
  check_bool "release present"
    true (List.exists (fun r -> r.Sun_cli_registry.release_id = rel.Sun_cli_registry.release_id) releases)

let test_pg_list_releases_page () =
  with_pg_pool @@ fun pool ws ->
  let ops = Sun_cli_pg_registry.pg_ops pool in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:ws |> get_ok in
  let pid = p.Sun_cli_registry.project_id in
  for i = 1 to 5 do
    ignore (ops.Sun_cli_control_plane.create_release
      ~project_id:pid ~environment:"production"
      ~image_tag:(Printf.sprintf "pg-tag%d" i) ~service_names:[]
      |> get_ok)
  done;
  let (page1, total) = ops.Sun_cli_control_plane.list_releases_page
    ~project_id:pid ~page:1 ~page_size:3 () |> get_ok in
  check_bool "total >= 5" true (total >= 5);
  check_int "page1 has 3 items" 3 (List.length page1)

let test_pg_get_release_logs () =
  with_pg_pool @@ fun pool ws ->
  let ops = Sun_cli_pg_registry.pg_ops pool in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:ws |> get_ok in
  let pid = p.Sun_cli_registry.project_id in
  let rel = ops.Sun_cli_control_plane.create_release
    ~project_id:pid ~environment:"production" ~image_tag:"sha-logs" ~service_names:["svc"]
    |> get_ok
  in
  let rid = rel.Sun_cli_registry.release_id in
  ops.Sun_cli_control_plane.append_log_line rid "[test] line 1";
  ops.Sun_cli_control_plane.append_log_line rid "[test] line 2";
  let logs = ops.Sun_cli_control_plane.get_release_logs pid rid |> get_ok in
  check_bool "has logs" true (List.length logs > 0);
  check_bool "custom log line present"
    true (List.exists (fun l -> l = "[test] line 1") logs)

let test_pg_update_service_digest () =
  with_pg_pool @@ fun pool ws ->
  let ops = Sun_cli_pg_registry.pg_ops pool in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:ws |> get_ok in
  let pid = p.Sun_cli_registry.project_id in
  let rel = ops.Sun_cli_control_plane.create_release
    ~project_id:pid ~environment:"production" ~image_tag:"sha-dig"
    ~service_names:["charge-svc"]
    |> get_ok
  in
  let rid = rel.Sun_cli_registry.release_id in
  let result = ops.Sun_cli_control_plane.update_service_digest
    rid "charge-svc" "reg/ws/charge-svc:sha-dig" "sha256:abc" in
  check_bool "digest update ok" true (Result.is_ok result)

let test_pg_update_release_status () =
  with_pg_pool @@ fun pool ws ->
  let ops = Sun_cli_pg_registry.pg_ops pool in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:ws |> get_ok in
  let pid = p.Sun_cli_registry.project_id in
  let rel = ops.Sun_cli_control_plane.create_release
    ~project_id:pid ~environment:"production" ~image_tag:"sha-status"
    ~service_names:[]
    |> get_ok
  in
  let result = ops.Sun_cli_control_plane.update_release_status
    rel.Sun_cli_registry.release_id "failed" in
  check_bool "status update ok" true (Result.is_ok result)

(* ── builder pipeline tests (memory ops) ──────────────────────────────────── *)

(* Simulate the fake_builder pattern: build_and_push records log lines and
   returns a digest.  We exercise append_log_line + update_service_digest here
   so the happy path is covered without invoking Docker. *)
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
  (* Record per-service digest *)
  let digest_result = ops.Sun_cli_control_plane.update_service_digest
    rid "charge-svc" "reg/app:v1" "sha256:test" in
  check_bool "digest update ok" true (Result.is_ok digest_result);
  (* Verify logs were captured *)
  let logs = ops.Sun_cli_control_plane.get_release_logs pid rid |> get_ok in
  check_bool "has log lines" true (List.length logs > 0);
  let has_digest_log =
    List.exists (fun l -> String.length l >= 15 &&
      String.sub l 0 9 = "[deploy] ") logs
  in
  check_bool "deploy log present" true has_digest_log

let test_update_service_digest_unknown () =
  let ops = memory_ops () in
  let result = ops.Sun_cli_control_plane.update_service_digest
    "no-such-rel" "svc" "img:v1" "sha256:abc" in
  check_bool "error on missing release" true (Result.is_error result)

(* ── update_release_status tests ─────────────────────────────────────────── *)

let test_update_release_status_failed () =
  let ops = memory_ops () in
  let p = ops.Sun_cli_control_plane.create_project ~workspace:"testws" |> get_ok in
  let pid = p.Sun_cli_registry.project_id in
  let rel = ops.Sun_cli_control_plane.create_release
    ~project_id:pid ~environment:"production" ~image_tag:"sha-abc"
    ~service_names:["svc-a"]
    |> get_ok
  in
  let rid = rel.Sun_cli_registry.release_id in
  (* Mark as failed (simulates the build-failure branch in cloud_deploy) *)
  let result = ops.Sun_cli_control_plane.update_release_status rid "failed" in
  check_bool "status update ok" true (Result.is_ok result);
  (* Append the log line that cloud_deploy now emits *)
  ops.Sun_cli_control_plane.append_log_line rid "[deploy] release failed";
  let logs = ops.Sun_cli_control_plane.get_release_logs pid rid |> get_ok in
  let has_failed_log =
    List.exists (fun l -> l = "[deploy] release failed") logs
  in
  check_bool "failed log present" true has_failed_log

let test_update_release_status_unknown () =
  let ops = memory_ops () in
  let result = ops.Sun_cli_control_plane.update_release_status "no-such-rel" "failed" in
  check_bool "error on missing release" true (Result.is_error result)

(* ── fake_builder injection test ─────────────────────────────────────────── *)

(* fake_builder type mirroring cmd_cloud.ml — avoids importing the executable *)
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

let fake_builder ?(digest = "sha256:deadbeef") () = {
  build_and_push = fun ~workspace_path:_ ~service_dir:_ ~image_ref ~log ->
    log (Printf.sprintf "[build] (fake) built %s" image_ref);
    log (Printf.sprintf "[push] (fake) pushed %s" image_ref);
    log (Printf.sprintf "[deploy] (fake) digest: %s" digest);
    Ok { image_tag = image_ref; digest }
}

(* run_deploy_pipeline: mirrors the core logic of cloud_deploy, using injectable builder *)
let run_deploy_pipeline ~ops ~builder ~workspace ~environment ~services =
  let project = ops.Sun_cli_control_plane.create_project ~workspace |> get_ok in
  let pid = project.Sun_cli_registry.project_id in
  let service_names = List.map fst services in
  let rel = ops.Sun_cli_control_plane.create_release
    ~project_id:pid ~environment ~image_tag:"sha-test"
    ~service_names |> get_ok
  in
  let rid = rel.Sun_cli_registry.release_id in
  let built = ref [] in
  let all_ok = List.for_all (fun (svc_name, svc_dir) ->
    let image_ref = Printf.sprintf "reg/%s/%s:sha-test" workspace svc_name in
    let log line = ops.Sun_cli_control_plane.append_log_line rid line in
    match builder.build_and_push
        ~workspace_path:"/tmp/ws" ~service_dir:svc_dir ~image_ref ~log with
    | Error msg ->
      ops.Sun_cli_control_plane.append_log_line rid
        (Printf.sprintf "[deploy] build failed: %s" msg);
      false
    | Ok result ->
      ignore (ops.Sun_cli_control_plane.update_service_digest
        rid svc_name result.image_tag result.digest);
      built := { Sun_cli_registry.
        service_name = svc_name;
        service_status = Sun_cli_registry.Service_live;
        image = Some result.image_tag;
        digest = Some result.digest;
      } :: !built;
      true
  ) services in
  if all_ok then begin
    ops.Sun_cli_control_plane.append_log_line rid "[deploy] release complete: status=live";
    let updated = { rel with
      Sun_cli_registry.services = List.rev !built;
      digest = None;
    } in
    Ok updated
  end else begin
    ignore (ops.Sun_cli_control_plane.update_release_status rid "failed");
    ops.Sun_cli_control_plane.append_log_line rid "[deploy] release failed";
    Error "build failed"
  end

let test_fake_builder_injection_happy_path () =
  let ops = memory_ops () in
  let builder = fake_builder ~digest:"sha256:test" () in
  let result = run_deploy_pipeline ~ops ~builder
    ~workspace:"myapp" ~environment:"production"
    ~services:[("charge-svc", "services/charge")]
  in
  check_bool "pipeline ok" true (Result.is_ok result);
  let rel = Result.get_ok result in
  (* Per-service digest is set; release-level digest is not used *)
  let svc = List.hd rel.Sun_cli_registry.services in
  check_string "per-service digest set" "sha256:test"
    (Option.value ~default:"" svc.Sun_cli_registry.digest);
  let logs = ops.Sun_cli_control_plane.get_release_logs
    "proj-myapp" rel.Sun_cli_registry.release_id |> get_ok in
  let has_complete_log =
    List.exists (fun l -> l = "[deploy] release complete: status=live") logs
  in
  check_bool "complete log present" true has_complete_log

let test_fake_builder_injection_failure () =
  let ops = memory_ops () in
  let failing_builder = {
    build_and_push = fun ~workspace_path:_ ~service_dir:_ ~image_ref:_ ~log:_ ->
      Error "simulated docker build error"
  } in
  let result = run_deploy_pipeline ~ops ~builder:failing_builder
    ~workspace:"myapp2" ~environment:"production"
    ~services:[("api-svc", "services/api")]
  in
  check_bool "pipeline fails" true (Result.is_error result);
  (* Verify that get_release_logs is accessible and contains failure log *)
  let pid = Sun_cli_registry.project_id_of_workspace "myapp2" in
  let all_releases = ops.Sun_cli_control_plane.list_releases ~project_id:pid |> get_ok in
  check_bool "release recorded" true (List.length all_releases = 1);
  let rid = (List.hd all_releases).Sun_cli_registry.release_id in
  let logs = ops.Sun_cli_control_plane.get_release_logs pid rid |> get_ok in
  let has_failed_log =
    List.exists (fun l -> l = "[deploy] release failed") logs
  in
  check_bool "failed log present" true has_failed_log

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
        Alcotest.test_case "builder pipeline records per-service digest and logs" `Quick test_builder_pipeline_memory;
        Alcotest.test_case "update service digest returns error for unknown release" `Quick test_update_service_digest_unknown;
      ];
      "update_release_status", [
        Alcotest.test_case "mark release as failed records log" `Quick test_update_release_status_failed;
        Alcotest.test_case "update status returns error for unknown release" `Quick test_update_release_status_unknown;
      ];
      "builder injection", [
        Alcotest.test_case "fake_builder happy path sets digest" `Quick test_fake_builder_injection_happy_path;
        Alcotest.test_case "fake_builder failure marks release failed" `Quick test_fake_builder_injection_failure;
      ];
      "pg_ops (integration)", [
        Alcotest.test_case "create project"             `Quick test_pg_create_project;
        Alcotest.test_case "create project idempotent"  `Quick test_pg_create_project_idempotent;
        Alcotest.test_case "create release"             `Quick test_pg_create_release;
        Alcotest.test_case "list releases"              `Quick test_pg_list_releases;
        Alcotest.test_case "list releases paginated"    `Quick test_pg_list_releases_page;
        Alcotest.test_case "get release logs"           `Quick test_pg_get_release_logs;
        Alcotest.test_case "update service digest"      `Quick test_pg_update_service_digest;
        Alcotest.test_case "update release status"      `Quick test_pg_update_release_status;
      ];
    ]
