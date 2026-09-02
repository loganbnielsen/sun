let check_bool = Alcotest.(check bool)

module S = Sun_cli_status

let test_all_healthy () =
  check_bool "no diagnoses -> Healthy" true
    (S.rollup_domain_status ~ns_exists:true [] = S.Healthy);
  check_bool "all None -> Healthy" true
    (S.rollup_domain_status ~ns_exists:true [None; None] = S.Healthy)

let test_one_degraded () =
  check_bool "one Some -> Degraded" true
    (S.rollup_domain_status ~ns_exists:true [None; Some "charge-svc rollout failed"]
     = S.Degraded)

let test_not_deployed_overrides_diagnoses () =
  check_bool "ns missing -> Not_deployed regardless of diagnoses" true
    (S.rollup_domain_status ~ns_exists:false [None] = S.Not_deployed);
  check_bool "ns missing with a failing diagnosis -> still Not_deployed" true
    (S.rollup_domain_status ~ns_exists:false [Some "x"] = S.Not_deployed)

let test_domain_status_to_string () =
  check_bool "Healthy label" true (S.domain_status_to_string S.Healthy = "healthy");
  check_bool "Degraded label is upper-cased" true
    (S.domain_status_to_string S.Degraded = "DEGRADED");
  check_bool "Not_deployed label is upper-cased" true
    (S.domain_status_to_string S.Not_deployed = "NOT DEPLOYED")

let () =
  Alcotest.run "status" [
    "rollup_domain_status", [
      Alcotest.test_case "all healthy"              `Quick test_all_healthy;
      Alcotest.test_case "one degraded"              `Quick test_one_degraded;
      Alcotest.test_case "not deployed overrides"    `Quick test_not_deployed_overrides_diagnoses;
    ];
    "domain_status_to_string", [
      Alcotest.test_case "labels"                    `Quick test_domain_status_to_string;
    ];
  ]
