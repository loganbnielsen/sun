let check_str = Alcotest.(check string)
let check_strs = Alcotest.(check (list string))
let check_int_opt = Alcotest.(check (option int))
let check_bool = Alcotest.(check bool)

let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let mkdir_p path =
  let parts = String.split_on_char '/' path in
  let rec loop current = function
    | [] -> ()
    | part :: rest ->
      let next = if current = "" then part else Filename.concat current part in
      (try Unix.mkdir next 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      loop next rest
  in
  loop "" parts

let with_temp_dir f =
  let dir = Filename.temp_file "sun-config-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () -> Sys.chdir dir; f ())

let write_base () =
  write "sun.yml" {|
project: pluto

resources:
  app_db:
    type: postgres

  sessions:
    type: dynamodb
    partition_key: user_id
    sort_key: session_id
    indexes:
      by_expires_at:
        partition_key: tenant_id
        sort_key: expires_at

services:
  api:
    type: http
    path: app/core/api
    uses: [app_db, sessions]
|}

let test_target_path_supplies_placement () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sun/prod/aws";
    write "sun/prod/aws/us-east-1.yml" {|
target:
  cluster_name: pluto-prod
  base_domain: pluto.example.com

services:
  api:
    scale:
      min: 2
      max: 10
|};
    match Sun_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sun_cli_config.error_to_string e)
    | Ok cfg ->
      check_str "project" "pluto" (Option.get cfg.Sun_cli_config.project);
      let target = Option.get (Sun_cli_config.target cfg) in
      check_str "target name" "prod/aws/us-east-1" target.name;
      check_str "env" "prod" target.env;
      check_str "provider" "aws" target.provider;
      check_str "region" "us-east-1" target.region;
      check_str "cluster" "pluto-prod" (Option.get target.cluster_name);
      let resource = List.hd (Sun_cli_config.resources cfg) in
      check_str "resource" "app_db" resource.name;
      let service = List.hd (Sun_cli_config.services cfg) in
      check_str "service" "api" service.name;
      check_strs "uses" ["app_db"; "sessions"] service.uses;
      check_int_opt "scale min" (Some 2) service.scale_min;
      check_int_opt "scale max" (Some 10) service.scale_max)

let test_target_overlay_can_omit_resources_and_services () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sun/dev/aws";
    write "sun/dev/aws/us-east-1.yml" {|
target:
  cluster_name: sun-dev

resources:
  app_db:
    omit: true

services:
  api:
    omit: true
|};
    match Sun_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sun_cli_config.error_to_string e)
    | Ok cfg ->
      let resource_names =
        Sun_cli_config.resources cfg
        |> List.map (fun (r : Sun_cli_config.resource) -> r.name)
      in
      let service_names =
        Sun_cli_config.services cfg
        |> List.map (fun (s : Sun_cli_config.service) -> s.name)
      in
      check_strs "resources" ["sessions"] resource_names;
      check_strs "services" [] service_names)

let test_target_observability_backend_parsed () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sun/prod/aws";
    write "sun/prod/aws/us-east-1.yml" {|
target:
  base_domain: pluto.example.com
  observability_backend: self_hosted_durable
|};
    match Sun_cli_config.load_for_target ~target:"prod/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sun_cli_config.error_to_string e)
    | Ok cfg ->
      let target = Option.get (Sun_cli_config.target cfg) in
      check_str "observability_backend" "self_hosted_durable"
        (Option.get target.observability_backend))

let test_target_observability_backend_absent_when_unset () =
  with_temp_dir (fun () ->
    write_base ();
    mkdir_p "sun/dev/aws";
    write "sun/dev/aws/us-east-1.yml" {|
target:
  cluster_name: sun-dev
|};
    match Sun_cli_config.load_for_target ~target:"dev/aws/us-east-1" with
    | Error e -> Alcotest.fail (Sun_cli_config.error_to_string e)
    | Ok cfg ->
      let target = Option.get (Sun_cli_config.target cfg) in
      check_bool "observability_backend absent" true (target.observability_backend = None))

let test_bad_target_path_fails () =
  with_temp_dir (fun () ->
    write_base ();
    match Sun_cli_config.load_for_target ~target:"prod" with
    | Ok _ -> Alcotest.fail "expected invalid target path"
    | Error e ->
      check_str "message" "target must look like <env>/<provider>/<region>" e.message)

let () =
  Alcotest.run "config"
    [ "sun.yml", [
        Alcotest.test_case "target path supplies placement" `Quick test_target_path_supplies_placement;
        Alcotest.test_case "target overlay omits entries" `Quick test_target_overlay_can_omit_resources_and_services;
        Alcotest.test_case "observability_backend parsed" `Quick test_target_observability_backend_parsed;
        Alcotest.test_case "observability_backend absent when unset" `Quick test_target_observability_backend_absent_when_unset;
        Alcotest.test_case "bad target path fails" `Quick test_bad_target_path_fails;
      ]
    ]
