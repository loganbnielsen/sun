let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)

let get_ok = function
  | Ok v -> v
  | Error msg -> Alcotest.fail msg

let get_error = function
  | Ok _ -> Alcotest.fail "expected Error"
  | Error msg -> msg

let dns_safe_segment_string s =
  Sun_cli_hosted_url.dns_safe_segment s
  |> get_ok
  |> Sun_cli_hosted_url.dns_label_to_string

let custom_domain_config ~domain ~verification_token =
  Sun_cli_hosted_url.make_custom_domain_config ~domain ~verification_token
  |> get_ok

let test_dns_safe_segment_lowercase () =
  check_string "lowercase" "charge-svc"
    (dns_safe_segment_string "charge-svc");
  check_string "uppercase normalized" "charge-svc"
    (dns_safe_segment_string "Charge-Svc");
  check_string "underscores" "notify-worker"
    (dns_safe_segment_string "notify_worker")

let test_dns_safe_segment_strips_specials () =
  check_string "dots stripped" "acme" (dns_safe_segment_string "acme.");
  check_string "spaces to hyphens" "my-workspace"
    (dns_safe_segment_string "my workspace")

let test_dns_safe_segment_rejects_invalid () =
  let msg = Sun_cli_hosted_url.dns_safe_segment "..." |> get_error in
  check_string "empty rejected" "invalid DNS label: \"\"" msg;
  let msg = Sun_cli_hosted_url.dns_safe_segment "_svc_" |> get_error in
  check_string "edge hyphens rejected" "invalid DNS label: \"-svc-\"" msg

let test_generate_default_url () =
  let url =
    Sun_cli_hosted_url.generate_default_url
      ~service_name:"charge-svc"
      ~workspace:"pluto"
      ~environment_name:"production"
      ~base_domain:"sun.dev"
    |> get_ok
  in
  check_string "url" "charge-svc.pluto.production.apps.sun.dev" url

let test_generate_default_url_normalizes () =
  let url =
    Sun_cli_hosted_url.generate_default_url
      ~service_name:"Charge_Svc"
      ~workspace:"My_Workspace"
      ~environment_name:"PRODUCTION"
      ~base_domain:"sun.dev"
    |> get_ok
  in
  check_string "url normalized" "charge-svc.my-workspace.production.apps.sun.dev" url

let test_generate_default_url_rejects_invalid () =
  let msg =
    Sun_cli_hosted_url.generate_default_url
      ~service_name:"..."
      ~workspace:"pluto"
      ~environment_name:"production"
      ~base_domain:"sun.dev"
    |> get_error
  in
  check_string "invalid service" "invalid DNS label: \"\"" msg;
  let msg =
    Sun_cli_hosted_url.generate_default_url
      ~service_name:"charge-svc"
      ~workspace:"pluto"
      ~environment_name:"production"
      ~base_domain:"bad_domain"
    |> get_error
  in
  check_string "invalid base domain" "invalid DNS domain: \"bad_domain\"" msg

let test_verification_record_name () =
  let domain = Sun_cli_hosted_url.make_dns_domain "api.acme.com" |> get_ok in
  check_string "name"
    "_sun-verify.api.acme.com"
    (Sun_cli_hosted_url.verification_record_name domain)

let test_verification_record_value () =
  check_string "value"
    "sun-verify=tok_abc123"
    (Sun_cli_hosted_url.verification_record_value "tok_abc123")

let test_dns_records_for_custom_domain () =
  let cfg = custom_domain_config
      ~domain:"api.acme.com"
      ~verification_token:"tok_abc123" in
  let default_url = "charge-svc.pluto.production.apps.sun.dev" in
  let records =
    Sun_cli_hosted_url.dns_records_for_custom_domain cfg ~default_url
    |> get_ok
  in
  check_int "two records" 2 (List.length records);
  let cname = List.nth records 0 in
  let txt = List.nth records 1 in
  check_string "cname name" "api.acme.com" cname.name;
  check_string "cname kind" "CNAME"
    (Sun_cli_hosted_url.dns_record_kind_to_string cname.kind);
  check_string "cname value" default_url cname.value;
  check_int "cname ttl" 300 (Sun_cli_hosted_url.positive_ttl_to_int cname.ttl);
  check_string "txt name" "_sun-verify.api.acme.com" txt.name;
  check_string "txt kind" "TXT"
    (Sun_cli_hosted_url.dns_record_kind_to_string txt.kind);
  check_string "txt value" "sun-verify=tok_abc123" txt.value;
  check_int "txt ttl" 300 (Sun_cli_hosted_url.positive_ttl_to_int txt.ttl)

let test_custom_domain_rejects_invalid () =
  let msg =
    Sun_cli_hosted_url.make_custom_domain_config
      ~domain:"api..acme.com"
      ~verification_token:"tok_abc123"
    |> get_error
  in
  check_string "domain rejected" "invalid DNS domain: \"api..acme.com\"" msg;
  let msg =
    Sun_cli_hosted_url.make_positive_ttl 0
    |> get_error
  in
  check_string "ttl rejected" "invalid DNS TTL: 0" msg

let test_dns_records_reject_invalid_default_url () =
  let cfg = custom_domain_config
      ~domain:"api.acme.com"
      ~verification_token:"tok_abc123" in
  let msg =
    Sun_cli_hosted_url.dns_records_for_custom_domain cfg
      ~default_url:"charge-svc..sun.dev"
    |> get_error
  in
  check_string "default url rejected"
    "invalid DNS domain: \"charge-svc..sun.dev\"" msg

let test_dns_record_to_json () =
  let cfg = custom_domain_config
      ~domain:"api.acme.com"
      ~verification_token:"tok_abc123" in
  let records =
    Sun_cli_hosted_url.dns_records_for_custom_domain cfg
      ~default_url:"charge-svc.pluto.production.apps.sun.dev"
    |> get_ok
  in
  let json = Yojson.Safe.to_string
      (`List (List.map Sun_cli_hosted_url.dns_record_to_json records)) in
  if not (String.length json > 0) then Alcotest.fail "expected non-empty JSON";
  let open Yojson.Safe.Util in
  let arr = Yojson.Safe.from_string json in
  check_string "first record name" "api.acme.com"
    (arr |> index 0 |> member "name" |> to_string);
  check_string "first record kind" "CNAME"
    (arr |> index 0 |> member "kind" |> to_string);
  check_string "first record value" "charge-svc.pluto.production.apps.sun.dev"
    (arr |> index 0 |> member "value" |> to_string);
  check_int "first record ttl" 300
    (arr |> index 0 |> member "ttl" |> to_int);
  check_string "second record name" "_sun-verify.api.acme.com"
    (arr |> index 1 |> member "name" |> to_string);
  check_string "second record kind" "TXT"
    (arr |> index 1 |> member "kind" |> to_string);
  check_string "second record value" "sun-verify=tok_abc123"
    (arr |> index 1 |> member "value" |> to_string);
  check_int "second record ttl" 300
    (arr |> index 1 |> member "ttl" |> to_int)

let () =
  Alcotest.run "hosted_url"
    [ "dns_safe_segment", [
        Alcotest.test_case "lowercase passthrough" `Quick test_dns_safe_segment_lowercase;
        Alcotest.test_case "strips specials" `Quick test_dns_safe_segment_strips_specials;
        Alcotest.test_case "rejects invalid" `Quick test_dns_safe_segment_rejects_invalid;
      ];
      "generate_default_url", [
        Alcotest.test_case "basic url" `Quick test_generate_default_url;
        Alcotest.test_case "normalizes components" `Quick test_generate_default_url_normalizes;
        Alcotest.test_case "rejects invalid" `Quick test_generate_default_url_rejects_invalid;
      ];
      "custom_domain", [
        Alcotest.test_case "verification record name" `Quick test_verification_record_name;
        Alcotest.test_case "verification record value" `Quick test_verification_record_value;
        Alcotest.test_case "dns records" `Quick test_dns_records_for_custom_domain;
        Alcotest.test_case "rejects invalid config" `Quick test_custom_domain_rejects_invalid;
        Alcotest.test_case "rejects invalid default url" `Quick test_dns_records_reject_invalid_default_url;
        Alcotest.test_case "dns record json" `Quick test_dns_record_to_json;
      ];
    ]
