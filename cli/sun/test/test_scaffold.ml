(* Tests for Sun workspace scaffold (cmd_new.ml / sun new workspace).
   Calls new_workspace in a temp directory and asserts that the expected
   files are created with the correct content.  No build or cluster needed. *)

(* ── helpers ──────────────────────────────────────────────────────────────── *)

let check_bool  = Alcotest.(check bool)

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else begin
    let found = ref false in
    for i = 0 to hl - nl do
      if not !found && String.sub haystack i nl = needle then found := true
    done;
    !found
  end

let assert_contains label haystack needle =
  check_bool (Printf.sprintf "%s: contains %S" label needle) true
    (contains haystack needle)

let read_file path =
  let ic = open_in path in
  let s  = In_channel.input_all ic in
  close_in ic; s

(* Run [f] inside a fresh temp directory, then restore cwd and delete the tree. *)
let in_temp_dir f =
  let orig_cwd = Sys.getcwd () in
  let tmpdir   = Filename.temp_file "sun-scaffold-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Sys.chdir tmpdir;
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir orig_cwd;
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    f

(* ── scaffold tests ───────────────────────────────────────────────────────── *)

(* Verify that sun-ci.yml is generated *)
let test_ci_workflow_created () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let path = "testapp/.github/workflows/sun-ci.yml" in
  check_bool "sun-ci.yml created" true (Sys.file_exists path)

(* Verify that the existing deploy.yml is still generated *)
let test_deploy_workflow_created () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let path = "testapp/.github/workflows/deploy.yml" in
  check_bool "deploy.yml created" true (Sys.file_exists path)

(* Verify that sun-ci.yml contains 'sun deploy' *)
let test_ci_contains_sun_deploy () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sun-ci.yml" in
  assert_contains "sun-ci.yml" content "sun deploy"

(* Verify that sun-ci.yml contains '--emit-plan-to' (FEAT-008 integration) *)
let test_ci_contains_emit_plan_to () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sun-ci.yml" in
  assert_contains "sun-ci.yml" content "--emit-plan-to"

(* Verify that sun-ci.yml contains '--emit-to' (GitOps mode) *)
let test_ci_contains_emit_to () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sun-ci.yml" in
  assert_contains "sun-ci.yml" content "--emit-to"

(* Verify that sun-ci.yml contains 'dune build' and 'dune runtest' *)
let test_ci_contains_dune_commands () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sun-ci.yml" in
  assert_contains "sun-ci.yml" content "dune build";
  assert_contains "sun-ci.yml" content "dune runtest"

(* Verify no KUBECONFIG in the test/build job — cluster creds must stay out *)
let test_ci_no_kubeconfig_in_build_job () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sun-ci.yml" in
  (* KUBECONFIG must not appear as a required secret or env var *)
  check_bool "no KUBECONFIG in sun-ci.yml" false
    (contains content "KUBECONFIG_B64")

(* Verify that registry credentials are referenced as secrets (placeholders) *)
let test_ci_registry_secrets () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/.github/workflows/sun-ci.yml" in
  assert_contains "sun-ci.yml" content "secrets.REGISTRY";
  assert_contains "sun-ci.yml" content "secrets.REGISTRY_USER";
  assert_contains "sun-ci.yml" content "secrets.REGISTRY_PASSWORD"

(* Verify that other expected workspace files are still present *)
let test_existing_files_still_generated () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let expected = [
    "testapp/.ocamlformat";
    "testapp/.dockerignore";
    "testapp/dune-project";
    "testapp/README.md";
    "testapp/vendor/framework";
    "testapp/vendor/integrations";
    "testapp/events/payments/charged.ml";
    "testapp/events/payments/dune";
    "testapp/lib/notification.ml";
    "testapp/app/payments/charge_svc/bin/main.ml";
    "testapp/app/payments/charge_svc/sun.toml";
    "testapp/app/comms/notify_worker/bin/main.ml";
    "testapp/app/comms/notify_worker/sun.toml";
    "testapp/db/migrations/0001_notifications.sql";
  ] in
  List.iter (fun path ->
    check_bool (Printf.sprintf "%s exists" path) true (Sys.file_exists path)
  ) expected;
  (* quick count: at least 21 files *)
  let count = ref 0 in
  let rec walk dir =
    Array.iter (fun entry ->
      let full = Filename.concat dir entry in
      if full = "testapp/vendor" then ()
      else if Sys.is_directory full then walk full
      else incr count
    ) (Sys.readdir dir)
  in
  walk "testapp";
  check_bool "at least 21 files generated" true (!count >= 21)

let test_workspace_has_dune_project () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/dune-project" in
  assert_contains "dune-project" content "(lang dune 3.0)"

let test_dockerfile_paths_are_workspace_relative () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/app/payments/charge_svc/Dockerfile" in
  assert_contains "Dockerfile" content
    "COPY --from=build /workspace/_build/default/app/payments/charge_svc/bin/main.exe";
  assert_contains "Dockerfile" content "dune build app/payments/charge_svc/bin/main.exe";
  check_bool "Dockerfile does not include nested workspace path" false
    (contains content "_build/default/testapp/app/payments/charge_svc")

let test_readme_migrate_hint_substituted () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let content = read_file "testapp/README.md" in
  assert_contains "README" content "sun migrate";
  check_bool "README has no template placeholder" false (contains content "{{name}}")

let test_sun_sources_linked () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  check_bool "framework source linked" true
    (Sys.file_exists "testapp/vendor/framework/sun-svc/lib/dune");
  check_bool "integrations source linked" true
    (Sys.file_exists "testapp/vendor/integrations/kafka/kafka-eio-service/lib/dune")

let test_charge_svc_publishes_kafka_event () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let handler = read_file "testapp/app/payments/charge_svc/lib/handler.ml" in
  let main_ml = read_file "testapp/app/payments/charge_svc/bin/main.ml" in
  assert_contains "handler" handler "publish_charged event";
  check_bool "handler does not insert notification directly" false
    (contains handler "Notification.insert");
  assert_contains "main" main_ml "Kafka_service.register";
  assert_contains "main" main_ml "Kafka_service.publish"

let test_workspace_generated_json_decoders_are_result_based () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let event = read_file "testapp/events/payments/charged.ml" in
  let handler = read_file "testapp/app/payments/charge_svc/lib/handler.ml" in
  assert_contains "event" event "let required_string fields name";
  assert_contains "event" event "let required_int fields name";
  assert_contains "event" event "Result.bind (required_string fields \"id\")";
  assert_contains "handler" handler "let decode_charge json";
  assert_contains "handler" handler "Response.bad_request msg";
  check_bool "handler has no default string fallback" false
    (contains handler "Option.value ~default:\"\"");
  check_bool "handler has no default int fallback" false
    (contains handler "Option.value ~default:0");
  check_bool "event has no missing-fields catch-all" false
    (contains event "missing required fields")

(* ── bundle source resolution tests ──────────────────────────────────────── *)

(* Verify that infer_sun_home resolves correctly when SUN_HOME points to a
   directory with the self-contained release bundle layout:
     <bundle>/bin/sun       ← binary lives here (represented by SUN_HOME itself)
     <bundle>/framework/sun-svc/lib/dune
     <bundle>/integrations/kafka/kafka-eio-service/lib/dune
   is_sun_home checks for both sentinel files, so both must be present. *)
let test_bundle_layout_resolves_sun_home () =
  let tmpdir = Filename.temp_file "sun-bundle-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
      (* Create the bundle directory structure *)
      let mkdir_p path =
        ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))
      in
      mkdir_p (Filename.concat tmpdir "bin");
      mkdir_p (Filename.concat tmpdir "framework/sun-svc/lib");
      mkdir_p (Filename.concat tmpdir "integrations/kafka/kafka-eio-service/lib");
      (* Create the two sentinel dune files that is_sun_home checks *)
      let touch path =
        let oc = open_out path in close_out oc
      in
      touch (Filename.concat tmpdir "framework/sun-svc/lib/dune");
      touch (Filename.concat tmpdir "integrations/kafka/kafka-eio-service/lib/dune");
      (* Point SUN_HOME at the bundle root — infer_sun_home should accept it *)
      let result =
        let saved = Sys.getenv_opt "SUN_HOME" in
        Unix.putenv "SUN_HOME" tmpdir;
        let r = Sun_cli_cmd_new.infer_sun_home () in
        (match saved with
         | None     -> Unix.putenv "SUN_HOME" ""   (* can't unset, but empty won't match *)
         | Some v   -> Unix.putenv "SUN_HOME" v);
        r
      in
      check_bool "bundle layout: infer_sun_home resolves to Some" true
        (result <> None);
      check_bool "bundle layout: resolved path matches tmpdir" true
        (result = Some tmpdir))

(* Verify that a directory missing the kafka-eio-service sentinel is rejected.
   This guards against accidentally accepting a partial bundle. *)
let test_incomplete_bundle_rejected () =
  let tmpdir = Filename.temp_file "sun-bundle-partial-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
      let mkdir_p path =
        ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))
      in
      (* Only create the framework sentinel, not the integrations one *)
      mkdir_p (Filename.concat tmpdir "framework/sun-svc/lib");
      let touch path = let oc = open_out path in close_out oc in
      touch (Filename.concat tmpdir "framework/sun-svc/lib/dune");
      (* SUN_HOME pointing here should be rejected — integrations sentinel missing *)
      let result =
        let saved = Sys.getenv_opt "SUN_HOME" in
        Unix.putenv "SUN_HOME" tmpdir;
        let r = Sun_cli_cmd_new.infer_sun_home () in
        (match saved with
         | None   -> Unix.putenv "SUN_HOME" ""
         | Some v -> Unix.putenv "SUN_HOME" v);
        r
      in
      check_bool "incomplete bundle: infer_sun_home returns None" true
        (result = None))

(* Verify that find_ancestor + is_sun_home resolve the bundle root when starting
   from a simulated bin/ subdirectory — this is the primary runtime path used
   when a user downloads the release bundle and runs the binary directly.
   SUN_HOME is deliberately NOT set during this test. *)
let test_ancestor_walk_finds_bundle_root () =
  let tmpdir = Filename.temp_file "sun-ancestor-walk-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
      let mkdir_p path =
        ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))
      in
      let touch path = let oc = open_out path in close_out oc in
      (* Create the bundle layout: tmpdir/bin/, tmpdir/framework/..., tmpdir/integrations/... *)
      mkdir_p (Filename.concat tmpdir "bin");
      mkdir_p (Filename.concat tmpdir "framework/sun-svc/lib");
      mkdir_p (Filename.concat tmpdir "integrations/kafka/kafka-eio-service/lib");
      touch (Filename.concat tmpdir "framework/sun-svc/lib/dune");
      touch (Filename.concat tmpdir "integrations/kafka/kafka-eio-service/lib/dune");
      (* is_sun_home should accept the bundle root *)
      check_bool "is_sun_home returns true for valid bundle root" true
        (Sun_cli_cmd_new.is_sun_home tmpdir);
      (* find_ancestor starting from the bin/ subdirectory should walk up to tmpdir *)
      let bin_dir = Filename.concat tmpdir "bin" in
      let result  = Sun_cli_cmd_new.find_ancestor Sun_cli_cmd_new.is_sun_home bin_dir in
      check_bool "find_ancestor: returns Some" true (result <> None);
      check_bool "find_ancestor: resolved path matches bundle root" true
        (result = Some tmpdir))

(* Verify that the generic worker template calls ack() after side effects,
   not before them.  The Printf.printf call is the stub side effect; ack ()
   must appear later in the file. *)
let test_worker_ack_after_side_effect () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_worker "comms/notify";
  let lib = read_file "app/comms/notify_worker/lib/notify_worker.ml" in
  assert_contains "worker lib" lib "ack ()";
  assert_contains "worker lib" lib "Printf.printf";
  (* ack () must not precede the Printf.printf side effect *)
  let ack_pos =
    let i = ref (-1) in
    (try
      let needle = "ack ()" in
      let hl = String.length lib and nl = String.length needle in
      for j = 0 to hl - nl do
        if !i = -1 && String.sub lib j nl = needle then i := j
      done
    with _ -> ());
    !i
  in
  let printf_pos =
    let i = ref (-1) in
    (try
      let needle = "Printf.printf" in
      let hl = String.length lib and nl = String.length needle in
      for j = 0 to hl - nl do
        if !i = -1 && String.sub lib j nl = needle then i := j
      done
    with _ -> ());
    !i
  in
  check_bool "Printf.printf appears before ack ()" true
    (printf_pos >= 0 && ack_pos > printf_pos)

(* ── pending_migration_count tests ──────────────────────────────────────── *)

(* No db/migrations directory → count is 0 *)
let test_pending_migrations_no_dir () =
  let tmpdir = Filename.temp_file "sun-mig-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
      check_bool "no mig dir → 0" true
        (Sun_cli_workspace.pending_migration_count ~dir:tmpdir = 0))

(* db/migrations exists but is empty → count is 0 *)
let test_pending_migrations_empty_dir () =
  let tmpdir = Filename.temp_file "sun-mig-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
      ignore (Sys.command
        (Printf.sprintf "mkdir -p %s/db/migrations"
           (Filename.quote tmpdir)));
      check_bool "empty dir → 0" true
        (Sun_cli_workspace.pending_migration_count ~dir:tmpdir = 0))

(* db/migrations with two .sql files → count is 2 *)
let test_pending_migrations_counts_sql_files () =
  let tmpdir = Filename.temp_file "sun-mig-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () ->
      ignore (Sys.command
        (Printf.sprintf "mkdir -p %s/db/migrations"
           (Filename.quote tmpdir)));
      let touch name =
        let path = Printf.sprintf "%s/db/migrations/%s" tmpdir name in
        let oc = open_out path in close_out oc
      in
      touch "0001_init.sql";
      touch "0002_add_column.sql";
      touch "README.md";    (* non-.sql — must not be counted *)
      check_bool "two sql files → 2" true
        (Sun_cli_workspace.pending_migration_count ~dir:tmpdir = 2))

(* workspace scaffold generates one .sql file → count is 1 *)
let test_pending_migrations_workspace_scaffold () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  check_bool "scaffold workspace → 1 migration file" true
    (Sun_cli_workspace.pending_migration_count ~dir:"testapp" = 1)

(* ── golden tests ────────────────────────────────────────────────────────── *)

(* Golden: sun-ci.yml is byte-for-byte equivalent to the template source after
   substitution of {{name}}.  Any change to the template is visible in this diff. *)
let test_golden_ci_workflow () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let actual   = read_file "testapp/.github/workflows/sun-ci.yml" in
  let expected = Sun_cli_scaffold.subst [("name", "testapp"); ("Name", "Testapp")]
                   Sun_cli_scaffold_templates.tpl_github_ci in
  Alcotest.(check string) "sun-ci.yml golden" expected actual

(* Golden: charge_svc Dockerfile is byte-for-byte equivalent. *)
let test_golden_dockerfile () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let actual   = read_file "testapp/app/payments/charge_svc/Dockerfile" in
  let expected = Sun_cli_scaffold.subst
                   [("name", "testapp"); ("Name", "Testapp");
                    ("repo_dir", "app/payments/charge_svc");
                    ("binary", "testapp-charge-svc")]
                   Sun_cli_scaffold_templates.tpl_dockerfile in
  Alcotest.(check string) "Dockerfile golden" expected actual

(* Golden: charge_svc bin/main.ml *)
let test_golden_svc_bin_ml () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let actual   = read_file "testapp/app/payments/charge_svc/bin/main.ml" in
  let expected = Sun_cli_scaffold.subst [("name", "testapp"); ("Name", "Testapp")]
                   Sun_cli_scaffold_templates.ws_svc_bin_ml in
  Alcotest.(check string) "svc bin/main.ml golden" expected actual

(* Golden: notify_worker bin/main.ml *)
let test_golden_worker_bin_ml () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let actual   = read_file "testapp/app/comms/notify_worker/bin/main.ml" in
  let expected = Sun_cli_scaffold.subst [("name", "testapp"); ("Name", "Testapp")]
                   Sun_cli_scaffold_templates.ws_worker_bin_ml in
  Alcotest.(check string) "worker bin/main.ml golden" expected actual

(* Golden: test/dune — exact content check so scaffold schema-test regressions
   show up as a readable diff rather than a silent missing-file failure. *)
let test_golden_test_dune () =
  in_temp_dir @@ fun () ->
  Sun_cli_cmd_new.new_workspace "testapp";
  let actual   = read_file "testapp/test/dune" in
  let expected = Sun_cli_scaffold.subst [("name", "testapp"); ("Name", "Testapp")]
                   Sun_cli_scaffold_templates.ws_test_dune in
  Alcotest.(check string) "test/dune golden" expected actual

(* ── entry point ─────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "scaffold"
    [ "ci_workflow", [
        Alcotest.test_case "sun-ci.yml created"           `Quick test_ci_workflow_created
      ; Alcotest.test_case "deploy.yml still created"     `Quick test_deploy_workflow_created
      ; Alcotest.test_case "contains sun deploy"          `Quick test_ci_contains_sun_deploy
      ; Alcotest.test_case "--emit-plan-to present"       `Quick test_ci_contains_emit_plan_to
      ; Alcotest.test_case "--emit-to present"            `Quick test_ci_contains_emit_to
      ; Alcotest.test_case "dune build + runtest"         `Quick test_ci_contains_dune_commands
      ; Alcotest.test_case "no KUBECONFIG_B64 in workflow" `Quick test_ci_no_kubeconfig_in_build_job
      ; Alcotest.test_case "registry secret placeholders" `Quick test_ci_registry_secrets
      ]
    ; "existing_files", [
        Alcotest.test_case "all prior files still present" `Quick test_existing_files_still_generated
      ; Alcotest.test_case "dune-project generated"        `Quick test_workspace_has_dune_project
      ; Alcotest.test_case "Dockerfile paths relative"      `Quick test_dockerfile_paths_are_workspace_relative
      ; Alcotest.test_case "README hints substituted"       `Quick test_readme_migrate_hint_substituted
      ; Alcotest.test_case "Sun sources linked"             `Quick test_sun_sources_linked
      ; Alcotest.test_case "charge_svc publishes event"     `Quick test_charge_svc_publishes_kafka_event
      ; Alcotest.test_case "JSON decoders are result based" `Quick test_workspace_generated_json_decoders_are_result_based
      ]
    ; "worker_ack_order", [
        Alcotest.test_case "ack() comes after side effects" `Quick test_worker_ack_after_side_effect
      ]
    ; "bundle_resolution", [
        Alcotest.test_case "complete bundle layout resolves sun_home" `Quick test_bundle_layout_resolves_sun_home
      ; Alcotest.test_case "incomplete bundle is rejected"            `Quick test_incomplete_bundle_rejected
      ; Alcotest.test_case "ancestor walk finds bundle root from bin/" `Quick test_ancestor_walk_finds_bundle_root
      ]
    ; "pending_migrations", [
        Alcotest.test_case "no db/migrations dir → 0"     `Quick test_pending_migrations_no_dir
      ; Alcotest.test_case "empty db/migrations dir → 0"  `Quick test_pending_migrations_empty_dir
      ; Alcotest.test_case "counts only .sql files"        `Quick test_pending_migrations_counts_sql_files
      ; Alcotest.test_case "scaffold workspace → 1 migration" `Quick test_pending_migrations_workspace_scaffold
      ]
    ; "golden", [
        Alcotest.test_case "sun-ci.yml"            `Quick test_golden_ci_workflow
      ; Alcotest.test_case "charge_svc Dockerfile" `Quick test_golden_dockerfile
      ; Alcotest.test_case "charge_svc bin/main.ml" `Quick test_golden_svc_bin_ml
      ; Alcotest.test_case "notify_worker bin/main.ml" `Quick test_golden_worker_bin_ml
      ; Alcotest.test_case "test/dune"             `Quick test_golden_test_dune
      ]
    ]
