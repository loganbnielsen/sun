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

(* ── probe_url / reachability_of_probe (OBS-018) ────────────────────────── *)

module O = Sun_cli_observability_url

let test_probe_url_explicit_always_wins () =
  List.iter (fun backend ->
    check_bool "explicit url wins" true
      (S.probe_url ~backend ~explicit_url:(Some "http://custom:9999")
         ~default_local_url:"http://localhost:3100" ~probe_path:"/ready"
       = Some "http://custom:9999/ready")
  ) [O.Local; O.Self_hosted_durable; O.External]

let test_probe_url_local_default_when_no_explicit () =
  check_bool "local default used" true
    (S.probe_url ~backend:O.Local ~explicit_url:None
       ~default_local_url:"http://localhost:3100" ~probe_path:"/ready"
     = Some "http://localhost:3100/ready")

let test_probe_url_non_local_without_explicit_is_none () =
  List.iter (fun backend ->
    check_bool "no default guessed for non-local" true
      (S.probe_url ~backend ~explicit_url:None
         ~default_local_url:"http://localhost:3100" ~probe_path:"/ready"
       = None)
  ) [O.Self_hosted_durable; O.External]

let test_reachability_of_probe_not_checked () =
  check_bool "None -> Not_checked" true
    (S.reachability_of_probe ~probe_url:None ~is_reachable:(fun _ -> true) = S.Not_checked)

let test_reachability_of_probe_healthy () =
  check_bool "reachable -> Healthy" true
    (S.reachability_of_probe ~probe_url:(Some "http://x") ~is_reachable:(fun _ -> true)
     = S.Healthy)

let test_reachability_of_probe_unreachable () =
  check_bool "unreachable -> Unreachable" true
    (S.reachability_of_probe ~probe_url:(Some "http://x") ~is_reachable:(fun _ -> false)
     = S.Unreachable)

let test_reachability_to_string () =
  check_bool "Healthy label" true (S.reachability_to_string S.Healthy = "healthy");
  check_bool "Unreachable label" true (S.reachability_to_string S.Unreachable = "unreachable");
  check_bool "Not_checked label" true (S.reachability_to_string S.Not_checked = "not checked")

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
    "probe_url", [
      Alcotest.test_case "explicit always wins"           `Quick test_probe_url_explicit_always_wins;
      Alcotest.test_case "local default when no explicit" `Quick test_probe_url_local_default_when_no_explicit;
      Alcotest.test_case "non-local without explicit -> None" `Quick test_probe_url_non_local_without_explicit_is_none;
    ];
    "reachability_of_probe", [
      Alcotest.test_case "None -> Not_checked"  `Quick test_reachability_of_probe_not_checked;
      Alcotest.test_case "reachable -> Healthy" `Quick test_reachability_of_probe_healthy;
      Alcotest.test_case "unreachable -> Unreachable" `Quick test_reachability_of_probe_unreachable;
      Alcotest.test_case "reachability_to_string labels" `Quick test_reachability_to_string;
    ];
  ]
