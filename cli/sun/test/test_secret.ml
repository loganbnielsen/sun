let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else
    let found = ref false in
    for i = 0 to hl - nl do
      if not !found && String.sub haystack i nl = needle then found := true
    done;
    !found

let test_key_validation_accepts_env_style_key () =
  check_bool "valid key" true
    (Sun_cli_secret.validate_key "DATABASE_URL" = Ok ())

let test_key_validation_rejects_lowercase () =
  match Sun_cli_secret.validate_key "database_url" with
  | Ok () -> Alcotest.fail "lowercase key accepted"
  | Error msg ->
    check_string "error"
      "secret key must start with an uppercase letter"
      msg

let test_key_validation_rejects_hyphen () =
  match Sun_cli_secret.validate_key "API-TOKEN" with
  | Ok () -> Alcotest.fail "hyphenated key accepted"
  | Error msg ->
    check_string "error"
      "secret key may contain only uppercase letters, digits, and underscores"
      msg

let test_secret_manifest_contains_value_boundary () =
  let yaml =
    Sun_cli_secret.secret_manifest
      ~existing_data:[ "API_TOKEN", "ZXhpc3Rpbmc=" ]
      ~namespace:"myapp-payments"
      ~key:"DATABASE_URL"
      ~value:"postgres://secret"
  in
  check_bool "manifest names Secret" true (contains yaml "kind: Secret");
  check_bool "manifest has runtime secret name" true (contains yaml "name: sun-secrets");
  check_bool "manifest preserves existing encoded key" true
    (contains yaml "API_TOKEN: ZXhpc3Rpbmc=");
  check_bool "manifest has value for k8s materialization" true
    (contains yaml {|DATABASE_URL: "postgres://secret"|})

let test_redacted_result_hides_value () =
  let out = Sun_cli_secret.redacted_result (Sun_cli_secret.Applied [ "myapp-payments" ]) in
  check_string "redacted output" "secret set in 1 namespace(s)" out;
  check_bool "no secret value" false (contains out "postgres://secret")

let test_hosted_stub_boundary () =
  match Sun_cli_secret.set
          ~env:"hosted"
          ~workspace:"myapp"
          ~namespaces:[ "myapp-payments" ]
          ~key:"DATABASE_URL"
          ~value:"postgres://secret" with
  | Ok _ -> Alcotest.fail "hosted set unexpectedly succeeded"
  | Error msg ->
    check_string "hosted boundary"
      "hosted secret management will use the Sun control-plane API; no hosted endpoint is configured yet"
      msg

let () =
  Alcotest.run "secret"
    [ "validation", [
        Alcotest.test_case "accepts env style key" `Quick test_key_validation_accepts_env_style_key
      ; Alcotest.test_case "rejects lowercase" `Quick test_key_validation_rejects_lowercase
      ; Alcotest.test_case "rejects hyphen" `Quick test_key_validation_rejects_hyphen
      ]
    ; "rendering", [
        Alcotest.test_case "k8s materialization manifest" `Quick test_secret_manifest_contains_value_boundary
      ; Alcotest.test_case "redacted result" `Quick test_redacted_result_hides_value
      ]
    ; "hosted", [
        Alcotest.test_case "stub boundary" `Quick test_hosted_stub_boundary
      ]
    ]
