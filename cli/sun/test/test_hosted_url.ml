let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)

let test_dns_safe_segment_lowercase () =
  check_string "lowercase" "charge-svc"
    (Sun_cli_hosted_url.dns_safe_segment "charge-svc");
  check_string "uppercase normalized" "charge-svc"
    (Sun_cli_hosted_url.dns_safe_segment "Charge-Svc");
  check_string "underscores" "notify-worker"
    (Sun_cli_hosted_url.dns_safe_segment "notify_worker")

let test_dns_safe_segment_strips_specials () =
  check_string "dots stripped" "acme" (Sun_cli_hosted_url.dns_safe_segment "acme.");
  check_string "spaces to hyphens" "my-workspace"
    (Sun_cli_hosted_url.dns_safe_segment "my workspace");
  check_string "empty falls back" "unknown"
    (Sun_cli_hosted_url.dns_safe_segment "...")

let test_generate_default_url () =
  let url =
    Sun_cli_hosted_url.generate_default_url
      ~service_name:"charge-svc"
      ~workspace:"pluto"
      ~environment_name:"production"
      ~base_domain:"sun.dev"
  in
  check_string "url" "charge-svc.pluto.production.apps.sun.dev" url

let test_generate_default_url_normalizes () =
  let url =
    Sun_cli_hosted_url.generate_default_url
      ~service_name:"Charge_Svc"
      ~workspace:"My_Workspace"
      ~environment_name:"PRODUCTION"
      ~base_domain:"sun.dev"
  in
  check_string "url normalized" "charge-svc.my-workspace.production.apps.sun.dev" url

let test_verification_record_name () =
  check_string "name"
    "_sun-verify.api.acme.com"
    (Sun_cli_hosted_url.verification_record_name "api.acme.com")

let test_verification_record_value () =
  check_string "value"
    "sun-verify=tok_abc123"
    (Sun_cli_hosted_url.verification_record_value "tok_abc123")

let test_dns_records_for_custom_domain () =
  let cfg : Sun_cli_hosted_url.custom_domain_config = {
    domain = "api.acme.com";
    verification_token = "tok_abc123";
  } in
  let default_url = "charge-svc.pluto.production.apps.sun.dev" in
  let records = Sun_cli_hosted_url.dns_records_for_custom_domain cfg ~default_url in
  check_int "two records" 2 (List.length records);
  let cname = List.nth records 0 in
  let txt = List.nth records 1 in
  check_string "cname name" "api.acme.com" cname.name;
  check_string "cname kind" "CNAME"
    (Sun_cli_hosted_url.dns_record_kind_to_string cname.kind);
  check_string "cname value" default_url cname.value;
  check_int "cname ttl" 300 cname.ttl;
  check_string "txt name" "_sun-verify.api.acme.com" txt.name;
  check_string "txt kind" "TXT"
    (Sun_cli_hosted_url.dns_record_kind_to_string txt.kind);
  check_string "txt value" "sun-verify=tok_abc123" txt.value;
  check_int "txt ttl" 300 txt.ttl

let test_dns_record_to_json () =
  let cfg : Sun_cli_hosted_url.custom_domain_config = {
    domain = "api.acme.com";
    verification_token = "tok_abc123";
  } in
  let records =
    Sun_cli_hosted_url.dns_records_for_custom_domain cfg
      ~default_url:"charge-svc.pluto.production.apps.sun.dev"
  in
  let json = Yojson.Safe.to_string
      (`List (List.map Sun_cli_hosted_url.dns_record_to_json records)) in
  if not (String.length json > 0) then Alcotest.fail "expected non-empty JSON";
  let open Yojson.Safe.Util in
  let arr = Yojson.Safe.from_string json in
  check_string "first record name" "api.acme.com"
    (arr |> index 0 |> member "name" |> to_string);
  check_string "second record kind" "TXT"
    (arr |> index 1 |> member "kind" |> to_string)

let () =
  Alcotest.run "hosted_url"
    [ "dns_safe_segment", [
        Alcotest.test_case "lowercase passthrough" `Quick test_dns_safe_segment_lowercase;
        Alcotest.test_case "strips specials" `Quick test_dns_safe_segment_strips_specials;
      ];
      "generate_default_url", [
        Alcotest.test_case "basic url" `Quick test_generate_default_url;
        Alcotest.test_case "normalizes components" `Quick test_generate_default_url_normalizes;
      ];
      "custom_domain", [
        Alcotest.test_case "verification record name" `Quick test_verification_record_name;
        Alcotest.test_case "verification record value" `Quick test_verification_record_value;
        Alcotest.test_case "dns records" `Quick test_dns_records_for_custom_domain;
        Alcotest.test_case "dns record json" `Quick test_dns_record_to_json;
      ];
    ]
