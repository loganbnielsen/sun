let check_string = Alcotest.(check string)

let test_k8s_name_underscores () =
  check_string "underscore to hyphen" "charge-svc"
    (Sun_cli_deployment_plan.k8s_name_of "charge_svc")

let test_k8s_name_worker () =
  check_string "worker suffix" "notify-worker"
    (Sun_cli_deployment_plan.k8s_name_of "notify_worker")

let test_k8s_name_no_underscores () =
  check_string "no underscores unchanged" "ordersvc"
    (Sun_cli_deployment_plan.k8s_name_of "ordersvc")

let test_namespace () =
  check_string "namespace format" "myapp-payments"
    (Sun_cli_deployment_plan.namespace_of ~workspace:"myapp" ~domain:"payments")

let test_namespace_comms () =
  check_string "namespace comms domain" "pluto-comms"
    (Sun_cli_deployment_plan.namespace_of ~workspace:"pluto" ~domain:"comms")

let test_namespace_sanitizes_workspace () =
  check_string "namespace sanitizes workspace" "comet-kafka-comms"
    (Sun_cli_deployment_plan.namespace_of ~workspace:"comet_kafka" ~domain:"comms")

let test_namespace_uppercased_workspace () =
  check_string "uppercase workspace lowercased" "myapp-payments"
    (Sun_cli_deployment_plan.namespace_of ~workspace:"MyApp" ~domain:"payments")

let test_image_ref_local () =
  check_string "local k3d image ref" "sun-registry:5000/myapp/charge-svc:abc123"
    (Sun_cli_deployment_plan.image_ref
       ~registry:"sun-registry:5000" ~workspace:"myapp"
       ~k8s_name:"charge-svc" ~tag:"abc123")

let test_image_ref_ecr () =
  check_string "ECR image ref" "123456789.dkr.ecr.us-east-1.amazonaws.com/myapp/charge-svc:sha-deadbeef"
    (Sun_cli_deployment_plan.image_ref
       ~registry:"123456789.dkr.ecr.us-east-1.amazonaws.com"
       ~workspace:"myapp" ~k8s_name:"charge-svc" ~tag:"sha-deadbeef")

let test_image_ref_push_registry () =
  check_string "localhost push registry" "localhost:5000/myapp/charge-svc:dev"
    (Sun_cli_deployment_plan.image_ref
       ~registry:"localhost:5000" ~workspace:"myapp"
       ~k8s_name:"charge-svc" ~tag:"dev")

(* ── to_json tests ─────────────────────────────────────────────────────── *)

(** Build a small but complete plan for use across serialization tests. *)
let sample_plan () : Sun_cli_deployment_plan.t =
  let env : Sun_cli_deployment_plan.env_config = {
    name        = "production";
    mode        = Sun_cli_deployment_plan.Customer_cloud;
    registry    = "123.dkr.ecr.us-east-1.amazonaws.com";
    image_tag   = "abc1234";
    region      = Some "us-east-1";
    base_domain = Some "example.com";
  } in
  let svc : Sun_cli_deployment_plan.service_spec = {
    domain      = "orders";
    source_name = "charge_svc";
    k8s_name    = "charge-svc";
    namespace   = "myworkspace-orders";
    primitive   = Sun_cli_deployment_plan.Svc;
    source_dir  = "/tmp/app/orders/charge_svc";
    image       = "123.dkr.ecr.us-east-1.amazonaws.com/myworkspace/charge-svc:abc1234";
    config      = [("LOG_LEVEL", "info"); ("REGION", "us-east-1")];
    secrets     = [("DB_PASSWORD", "super-secret-value"); ("API_KEY", "also-secret")];
    schedule    = None;
    replicas         = 2;
    cpu              = "250m";
    memory           = "256Mi";
    rollout_strategy     = None;
    ingress_host         = None;
    ingress_path         = None;
    extra_labels         = [];
    progressive_delivery = None;
  } in
  { workspace   = "myworkspace"
  ; environment = env
  ; services    = [svc]
  ; topics      = ["sun-demo-orders"]
  ; migrations  = []
  }

let test_to_json_valid_json () =
  let plan = sample_plan () in
  let json = Sun_cli_deployment_plan.to_json plan in
  let s    = Yojson.Safe.to_string json in
  (* round-trip: must parse without raising *)
  let _    = Yojson.Safe.from_string s in
  ()

let test_to_json_deterministic () =
  let plan = sample_plan () in
  let s1 = Yojson.Safe.to_string (Sun_cli_deployment_plan.to_json plan) in
  let s2 = Yojson.Safe.to_string (Sun_cli_deployment_plan.to_json plan) in
  Alcotest.(check string) "byte-identical" s1 s2

let test_to_json_no_secret_values () =
  let plan = sample_plan () in
  let s    = Yojson.Safe.to_string (Sun_cli_deployment_plan.to_json plan) in
  (* Neither secret value must appear in the output *)
  if String.length (Str.global_replace (Str.regexp "super-secret-value") "" s) < String.length s then
    Alcotest.fail "secret value 'super-secret-value' leaked into plan JSON";
  if String.length (Str.global_replace (Str.regexp "also-secret") "" s) < String.length s then
    Alcotest.fail "secret value 'also-secret' leaked into plan JSON"

let test_to_json_secret_keys_present () =
  let plan = sample_plan () in
  let s    = Yojson.Safe.to_string (Sun_cli_deployment_plan.to_json plan) in
  (* Secret keys must appear *)
  assert (let re = Str.regexp "DB_PASSWORD" in
          (try ignore (Str.search_forward re s 0); true with Not_found -> false));
  assert (let re = Str.regexp "API_KEY" in
          (try ignore (Str.search_forward re s 0); true with Not_found -> false))

let test_to_json_config_values_present () =
  let plan = sample_plan () in
  let s    = Yojson.Safe.to_string (Sun_cli_deployment_plan.to_json plan) in
  (* Config values (not secrets) must appear in full *)
  assert (let re = Str.regexp "us-east-1" in
          (try ignore (Str.search_forward re s 0); true with Not_found -> false))

let test_to_json_mode_strings () =
  let check_mode mode expected =
    let env : Sun_cli_deployment_plan.env_config = {
      name = "env"; mode; registry = "r"; image_tag = "t";
      region = None; base_domain = None;
    } in
    let plan : Sun_cli_deployment_plan.t = {
      workspace = "ws"; environment = env; services = []; topics = []; migrations = [];
    } in
    let s = Yojson.Safe.to_string (Sun_cli_deployment_plan.to_json plan) in
    assert (let re = Str.regexp (Printf.sprintf {|"mode":"%s"|} expected) in
            (try ignore (Str.search_forward re s 0); true with Not_found -> false))
  in
  check_mode Sun_cli_deployment_plan.Local          "local";
  check_mode Sun_cli_deployment_plan.Customer_cloud "customer_cloud";
  check_mode Sun_cli_deployment_plan.Sun_hosted     "sun_hosted"

let () =
  Alcotest.run "deployment_plan"
    [ "k8s_name", [
        Alcotest.test_case "underscore to hyphen" `Quick test_k8s_name_underscores
      ; Alcotest.test_case "worker suffix"        `Quick test_k8s_name_worker
      ; Alcotest.test_case "no underscores"       `Quick test_k8s_name_no_underscores
      ]
    ; "namespace", [
        Alcotest.test_case "workspace-domain"       `Quick test_namespace
      ; Alcotest.test_case "comms domain"           `Quick test_namespace_comms
      ; Alcotest.test_case "sanitize workspace"     `Quick test_namespace_sanitizes_workspace
      ; Alcotest.test_case "uppercase workspace"    `Quick test_namespace_uppercased_workspace
      ]
    ; "image_ref", [
        Alcotest.test_case "local k3d"         `Quick test_image_ref_local
      ; Alcotest.test_case "ECR registry"      `Quick test_image_ref_ecr
      ; Alcotest.test_case "localhost push"    `Quick test_image_ref_push_registry
      ]
    ; "to_json", [
        Alcotest.test_case "valid JSON"              `Quick test_to_json_valid_json
      ; Alcotest.test_case "deterministic"           `Quick test_to_json_deterministic
      ; Alcotest.test_case "no secret values"        `Quick test_to_json_no_secret_values
      ; Alcotest.test_case "secret keys present"     `Quick test_to_json_secret_keys_present
      ; Alcotest.test_case "config values present"   `Quick test_to_json_config_values_present
      ; Alcotest.test_case "mode strings"            `Quick test_to_json_mode_strings
      ]
    ]
