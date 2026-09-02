let check_string = Alcotest.(check string)
let check_bool   = Alcotest.(check bool)

module U = Sun_cli_observability_url

let url_of = function
  | U.Url s -> s
  | U.No_url reason -> Alcotest.fail ("expected Url, got No_url " ^ reason)

let reason_of = function
  | U.Url s -> Alcotest.fail ("expected No_url, got Url " ^ s)
  | U.No_url reason -> reason

(* ── backend_of_string / backend_to_string ──────────────────────────────── *)

let test_backend_of_string_valid () =
  check_bool "local"                true (U.backend_of_string "local" = Some U.Local);
  check_bool "self_hosted_durable"   true (U.backend_of_string "self_hosted_durable" = Some U.Self_hosted_durable);
  check_bool "external"              true (U.backend_of_string "external" = Some U.External)

let test_backend_of_string_invalid () =
  check_bool "unknown string -> None" true (U.backend_of_string "bogus" = None)

let test_backend_to_string_roundtrip () =
  List.iter (fun b ->
    check_bool "roundtrip" true
      (U.backend_of_string (U.backend_to_string b) = Some b)
  ) [U.Local; U.Self_hosted_durable; U.External]

(* ── resolve ─────────────────────────────────────────────────────────────── *)

let test_resolve_local_default () =
  check_string "local default" "http://localhost:3000"
    (url_of (U.resolve ~backend:U.Local ()))

let test_resolve_self_hosted_durable_with_base_domain () =
  check_string "self_hosted_durable" "https://grafana.acme.com"
    (url_of (U.resolve ~backend:U.Self_hosted_durable ~base_domain:"acme.com" ()))

let test_resolve_self_hosted_durable_without_base_domain () =
  check_bool "no base_domain -> No_url" true
    (String.length (reason_of (U.resolve ~backend:U.Self_hosted_durable ())) > 0)

let test_resolve_self_hosted_durable_blank_base_domain () =
  check_bool "blank base_domain -> No_url" true
    (String.length (reason_of (U.resolve ~backend:U.Self_hosted_durable ~base_domain:"   " ())) > 0)

let test_resolve_external_never_guesses () =
  check_bool "external -> No_url even with base_domain" true
    (String.length (reason_of (U.resolve ~backend:U.External ~base_domain:"acme.com" ())) > 0)

let test_resolve_override_wins_for_every_backend () =
  List.iter (fun backend ->
    check_string "override wins" "http://custom:9999"
      (url_of (U.resolve ~backend ~override:"http://custom:9999" ()))
  ) [U.Local; U.Self_hosted_durable; U.External]

let () =
  Alcotest.run "observability_url" [
    "backend_of_string", [
      Alcotest.test_case "valid values"   `Quick test_backend_of_string_valid;
      Alcotest.test_case "invalid value"  `Quick test_backend_of_string_invalid;
      Alcotest.test_case "roundtrip"      `Quick test_backend_to_string_roundtrip;
    ];
    "resolve", [
      Alcotest.test_case "local default"                          `Quick test_resolve_local_default;
      Alcotest.test_case "self_hosted_durable with base_domain"    `Quick test_resolve_self_hosted_durable_with_base_domain;
      Alcotest.test_case "self_hosted_durable without base_domain" `Quick test_resolve_self_hosted_durable_without_base_domain;
      Alcotest.test_case "self_hosted_durable blank base_domain"   `Quick test_resolve_self_hosted_durable_blank_base_domain;
      Alcotest.test_case "external never guesses"                  `Quick test_resolve_external_never_guesses;
      Alcotest.test_case "override wins for every backend"         `Quick test_resolve_override_wins_for_every_backend;
    ];
  ]
