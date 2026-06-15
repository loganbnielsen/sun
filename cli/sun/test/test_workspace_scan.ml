(* Tests for Sun_cli_workspace.scan — verifies that vendor/, _build/, and
   symlinked framework directories are not followed during infra detection. *)

let check_bool = Alcotest.(check bool)

let in_temp_dir f =
  let orig_cwd = Sys.getcwd () in
  let tmpdir   = Filename.temp_file "sun-ws-scan-test-" "" in
  Sys.remove tmpdir;
  Unix.mkdir tmpdir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir orig_cwd;
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmpdir))))
    (fun () -> Sys.chdir tmpdir; f tmpdir)

let mkdir_p path =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote path)))

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

(* A dune file that references all four infra libraries — simulates framework src *)
let framework_dune_content =
  "(library (name sun_svc) (libraries kafka_eio_service sun_storage obs_eio_loki obs_eio_prometheus))"

(* A plain app dune file with no infra dependencies *)
let plain_app_dune =
  "(executable (name main) (libraries cohttp-eio))"

(* A dune file that only uses Kafka *)
let kafka_only_dune =
  "(library (name my_worker) (libraries kafka_eio_service))"

(* ── tests ──────────────────────────────────────────────────────────────────── *)

let test_vendor_dir_ignored () =
  in_temp_dir @@ fun tmpdir ->
  mkdir_p (tmpdir ^ "/app");
  write_file (tmpdir ^ "/app/dune") plain_app_dune;
  (* vendor/ contains dune files that reference all infra — should be ignored *)
  mkdir_p (tmpdir ^ "/vendor/framework/sun-svc/lib");
  write_file (tmpdir ^ "/vendor/framework/sun-svc/lib/dune") framework_dune_content;
  let req = Sun_cli_workspace.scan ~dir:tmpdir in
  check_bool "kafka ignored in vendor"      false req.kafka;
  check_bool "postgres ignored in vendor"   false req.postgres;
  check_bool "loki ignored in vendor"       false req.loki;
  check_bool "prometheus ignored in vendor" false req.prometheus

let test_build_dir_ignored () =
  in_temp_dir @@ fun tmpdir ->
  mkdir_p (tmpdir ^ "/app");
  write_file (tmpdir ^ "/app/dune") plain_app_dune;
  mkdir_p (tmpdir ^ "/_build/default/lib");
  write_file (tmpdir ^ "/_build/default/lib/dune") framework_dune_content;
  let req = Sun_cli_workspace.scan ~dir:tmpdir in
  check_bool "kafka ignored in _build"  false req.kafka;
  check_bool "postgres ignored in _build" false req.postgres

let test_symlinked_dir_ignored () =
  (* Create the real framework source outside the workspace tmpdir so the only
     path into it is through the symlink. *)
  let real_src = Filename.temp_file "sun-ws-real-" "" in
  Sys.remove real_src;
  Unix.mkdir real_src 0o755;
  Unix.mkdir (real_src ^ "/lib") 0o755;
  write_file (real_src ^ "/lib/dune") framework_dune_content;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote real_src))))
    (fun () ->
      in_temp_dir @@ fun tmpdir ->
      (* "third_party" is not in skip_dirs but is a symlink → must not be followed *)
      Unix.symlink real_src (tmpdir ^ "/third_party");
      let req = Sun_cli_workspace.scan ~dir:tmpdir in
      check_bool "kafka ignored via symlink"    false req.kafka;
      check_bool "postgres ignored via symlink" false req.postgres)

let test_app_infra_detected () =
  in_temp_dir @@ fun tmpdir ->
  (* Actual app code references Kafka *)
  mkdir_p (tmpdir ^ "/app/workers");
  write_file (tmpdir ^ "/app/workers/dune") kafka_only_dune;
  (* Vendor still present with all infra — should not affect result *)
  mkdir_p (tmpdir ^ "/vendor/framework/lib");
  write_file (tmpdir ^ "/vendor/framework/lib/dune") framework_dune_content;
  let req = Sun_cli_workspace.scan ~dir:tmpdir in
  check_bool "kafka detected in app"         true  req.kafka;
  check_bool "postgres not in app"           false req.postgres;
  check_bool "loki not in app"               false req.loki;
  check_bool "prometheus not in app"         false req.prometheus

let test_git_dir_ignored () =
  in_temp_dir @@ fun tmpdir ->
  mkdir_p (tmpdir ^ "/.git/hooks");
  write_file (tmpdir ^ "/.git/hooks/dune") framework_dune_content;
  let req = Sun_cli_workspace.scan ~dir:tmpdir in
  check_bool "infra ignored in .git" false req.kafka

let () =
  Alcotest.run "workspace-scan" [
    "vendor-ignored", [
      Alcotest.test_case "vendor/ dir skipped"           `Quick test_vendor_dir_ignored;
      Alcotest.test_case "_build/ dir skipped"           `Quick test_build_dir_ignored;
      Alcotest.test_case "symlinked dir skipped"          `Quick test_symlinked_dir_ignored;
      Alcotest.test_case ".git/ dir skipped"             `Quick test_git_dir_ignored;
    ];
    "app-detection", [
      Alcotest.test_case "app infra still detected"      `Quick test_app_infra_detected;
    ];
  ]
