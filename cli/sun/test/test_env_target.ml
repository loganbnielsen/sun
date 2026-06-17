let check_string = Alcotest.(check string)
let check_opt_str = Alcotest.(check (option string))

(* ── local_defaults ──────────────────────────────────────────────────────── *)

let test_local_registry () =
  let t = Sun_cli_env_target.local_defaults ~image_tag:"abc123" in
  check_string "cluster registry" "sun-registry:5000"
    (Sun_cli_env_target.registry t)

let test_local_image_tag () =
  let t = Sun_cli_env_target.local_defaults ~image_tag:"abc123" in
  check_string "image tag preserved" "abc123"
    (Sun_cli_env_target.image_tag t)

let test_local_target_variant () =
  let t = Sun_cli_env_target.local_defaults ~image_tag:"dev" in
  Alcotest.(check bool) "target is Local_k3d" true
    (Sun_cli_env_target.target t = Sun_cli_env_target.Local_k3d)

let test_local_infra_none () =
  let t = Sun_cli_env_target.local_defaults ~image_tag:"dev" in
  check_opt_str "kafka_brokers None" None    (Sun_cli_env_target.kafka_brokers t);
  check_opt_str "postgres None"      None    (Sun_cli_env_target.postgres_secret_name t);
  check_opt_str "loki None"          None    (Sun_cli_env_target.loki_url t);
  check_opt_str "pushgateway None"   None    (Sun_cli_env_target.pushgateway_url t)

(* ── customer_cloud_defaults — direct mode ───────────────────────────────── *)

let test_customer_direct_registry () =
  let t = Sun_cli_env_target.customer_cloud_defaults
    ~registry:"123456789.dkr.ecr.us-east-1.amazonaws.com"
    ~image_tag:"sha-deadbeef"
    ~emit_to:None
    ()
  in
  check_string "ECR registry" "123456789.dkr.ecr.us-east-1.amazonaws.com"
    (Sun_cli_env_target.registry t)

let test_customer_direct_target_variant () =
  let t = Sun_cli_env_target.customer_cloud_defaults
    ~registry:"reg" ~image_tag:"tag" ~emit_to:None ()
  in
  Alcotest.(check bool) "target is Customer_k8s_direct" true
    (Sun_cli_env_target.target t = Sun_cli_env_target.Customer_k8s_direct)

(* ── customer_cloud_defaults — gitops mode ───────────────────────────────── *)

let test_customer_gitops_target_variant () =
  let t = Sun_cli_env_target.customer_cloud_defaults
    ~registry:"reg" ~image_tag:"tag"
    ~emit_to:(Some "/tmp/manifests")
    ()
  in
  Alcotest.(check bool) "target is Customer_k8s_gitops" true
    (Sun_cli_env_target.target t = Sun_cli_env_target.Customer_k8s_gitops)

(* ── to_env_config ───────────────────────────────────────────────────────── *)

let test_to_env_config_local () =
  let t   = Sun_cli_env_target.local_defaults ~image_tag:"abc123" in
  let cfg = Sun_cli_env_target.to_env_config ~name:"local" t in
  check_string  "name"      "local"            cfg.Sun_cli_deployment_plan.name;
  check_string  "registry"  "sun-registry:5000" cfg.Sun_cli_deployment_plan.registry;
  check_string  "image_tag" "abc123"             cfg.Sun_cli_deployment_plan.image_tag;
  Alcotest.(check bool) "mode Local" true
    (cfg.Sun_cli_deployment_plan.mode = Sun_cli_deployment_plan.Local)

let test_to_env_config_customer () =
  let t   = Sun_cli_env_target.customer_cloud_defaults
    ~registry:"gcr.io/myproject"
    ~image_tag:"v1.2.3"
    ~emit_to:None
    ()
  in
  let cfg = Sun_cli_env_target.to_env_config ~name:"production" t in
  check_string "mode Customer_cloud" "production" cfg.Sun_cli_deployment_plan.name;
  Alcotest.(check bool) "mode Customer_cloud" true
    (cfg.Sun_cli_deployment_plan.mode = Sun_cli_deployment_plan.Customer_cloud)

(* ── validate ────────────────────────────────────────────────────────────── *)

let test_validate_local_ok () =
  let t = Sun_cli_env_target.local_defaults ~image_tag:"dev" in
  Alcotest.(check bool) "local k3d validates Ok" true
    (Sun_cli_env_target.validate t = Ok ())

let test_validate_customer_with_registry_ok () =
  let t = Sun_cli_env_target.customer_cloud_defaults
    ~registry:"123456789.dkr.ecr.us-east-1.amazonaws.com"
    ~image_tag:"sha-abc"
    ~emit_to:None
    ()
  in
  Alcotest.(check bool) "customer with registry validates Ok" true
    (Sun_cli_env_target.validate t = Ok ())

let test_validate_customer_gitops_with_registry_ok () =
  let t = Sun_cli_env_target.customer_cloud_defaults
    ~registry:"gcr.io/myproject"
    ~image_tag:"sha-abc"
    ~emit_to:(Some "/tmp/manifests")
    ()
  in
  Alcotest.(check bool) "gitops with registry validates Ok" true
    (Sun_cli_env_target.validate t = Ok ())

let test_validate_customer_empty_registry_fails () =
  let t = Sun_cli_env_target.customer_cloud_defaults
    ~registry:""
    ~image_tag:"sha-abc"
    ~emit_to:None
    ()
  in
  match Sun_cli_env_target.validate t with
  | Ok ()    -> Alcotest.fail "expected Error but got Ok"
  | Error msg ->
    (* The error message must mention "registry" so the user knows what to fix. *)
    let contains_registry =
      let needle = "registry" in
      let nlen   = String.length needle in
      let mlen   = String.length msg in
      let found  = ref false in
      for i = 0 to mlen - nlen do
        if String.sub msg i nlen = needle then found := true
      done;
      !found
    in
    Alcotest.(check bool) "error mentions registry" true contains_registry

let test_validate_customer_whitespace_registry_fails () =
  let t = Sun_cli_env_target.customer_cloud_defaults
    ~registry:"   "
    ~image_tag:"sha-abc"
    ~emit_to:None
    ()
  in
  Alcotest.(check bool) "whitespace registry fails validation" true
    (match Sun_cli_env_target.validate t with Error _ -> true | Ok () -> false)

let () =
  Alcotest.run "env_target"
    [ "local_defaults", [
        Alcotest.test_case "cluster registry"     `Quick test_local_registry
      ; Alcotest.test_case "image tag"            `Quick test_local_image_tag
      ; Alcotest.test_case "target variant"       `Quick test_local_target_variant
      ; Alcotest.test_case "infra fields all None"`Quick test_local_infra_none
      ]
    ; "customer_cloud_defaults", [
        Alcotest.test_case "ECR registry"         `Quick test_customer_direct_registry
      ; Alcotest.test_case "direct target"        `Quick test_customer_direct_target_variant
      ; Alcotest.test_case "gitops target"        `Quick test_customer_gitops_target_variant
      ]
    ; "to_env_config", [
        Alcotest.test_case "local"                `Quick test_to_env_config_local
      ; Alcotest.test_case "customer"             `Quick test_to_env_config_customer
      ]
    ; "validate", [
        Alcotest.test_case "local k3d ok"                 `Quick test_validate_local_ok
      ; Alcotest.test_case "customer with registry ok"    `Quick test_validate_customer_with_registry_ok
      ; Alcotest.test_case "gitops with registry ok"      `Quick test_validate_customer_gitops_with_registry_ok
      ; Alcotest.test_case "empty registry fails"         `Quick test_validate_customer_empty_registry_fails
      ; Alcotest.test_case "whitespace registry fails"    `Quick test_validate_customer_whitespace_registry_fails
      ]
    ]
