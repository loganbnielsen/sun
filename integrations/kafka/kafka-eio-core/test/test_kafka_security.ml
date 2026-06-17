let contains s sub =
  let slen = String.length s and sublen = String.length sub in
  if sublen = 0 then true
  else if sublen > slen then false
  else
    let rec go i =
      if i > slen - sublen then false
      else if String.sub s i sublen = sub then true
      else go (i + 1)
    in
    go 0

let full_sasl = Kafka_security.{
  protocol        = Sasl_ssl;
  ssl_ca_location = None;
  sasl_mechanism  = Some "PLAIN";
  sasl_username   = Some "user";
  sasl_password   = Some "pass";
}

let test_protocol_of_string_valid () =
  let cases =
    [ ("plaintext", Kafka_security.Plaintext)
    ; ("SSL", Kafka_security.Ssl)
    ; ("sasl_plaintext", Kafka_security.Sasl_plaintext)
    ; ("SASL_SSL", Kafka_security.Sasl_ssl)
    ]
  in
  List.iter (fun (raw, expected) ->
    Alcotest.(check bool) raw true
      (Kafka_security.protocol_of_string raw = Ok expected)
  ) cases

let test_protocol_of_string_invalid () =
  match Kafka_security.protocol_of_string "scram" with
  | Ok _ -> Alcotest.fail "expected invalid protocol error"
  | Error msg ->
    Alcotest.(check bool) "message names env var" true
      (contains msg "KAFKA_SECURITY_PROTOCOL");
    Alcotest.(check bool) "message includes bad value" true
      (contains msg "scram")

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect f ~finally:(fun () ->
    Unix.putenv name (Option.value old ~default:""))

let test_of_env_rejects_unknown_protocol () =
  with_env "KAFKA_SECURITY_PROTOCOL" "scram" (fun () ->
    match Kafka_security.of_env () with
    | Ok _ -> Alcotest.fail "expected of_env to reject unknown protocol"
    | Error msg ->
      Alcotest.(check bool) "clear protocol error" true
        (contains msg "unknown KAFKA_SECURITY_PROTOCOL"))

let test_plaintext_ok () =
  let conf = Kafka_raw.conf_new () in
  Alcotest.(check bool) "plaintext → Ok" true
    (Kafka_security.apply conf Kafka_security.default = Ok ())

let test_ssl_no_sasl_ok () =
  let conf = Kafka_raw.conf_new () in
  let sec = Kafka_security.{ default with protocol = Ssl } in
  Alcotest.(check bool) "ssl without sasl → Ok" true
    (Kafka_security.apply conf sec = Ok ())

let test_sasl_ssl_all_fields_ok () =
  let conf = Kafka_raw.conf_new () in
  Alcotest.(check bool) "sasl_ssl all fields → Ok" true
    (Kafka_security.apply conf full_sasl = Ok ())

let test_sasl_missing_mechanism () =
  let conf = Kafka_raw.conf_new () in
  let sec = Kafka_security.{ full_sasl with sasl_mechanism = None } in
  match Kafka_security.apply conf sec with
  | Ok () -> Alcotest.fail "expected error for missing sasl_mechanism"
  | Error msg ->
    Alcotest.(check bool) "message mentions sasl_mechanism" true
      (contains msg "sasl_mechanism")

let test_sasl_missing_username () =
  let conf = Kafka_raw.conf_new () in
  let sec = Kafka_security.{ full_sasl with sasl_username = None } in
  match Kafka_security.apply conf sec with
  | Ok () -> Alcotest.fail "expected error for missing sasl_username"
  | Error msg ->
    Alcotest.(check bool) "message mentions sasl_username" true
      (contains msg "sasl_username")

let test_sasl_missing_password () =
  let conf = Kafka_raw.conf_new () in
  let sec = Kafka_security.{ full_sasl with sasl_password = None } in
  match Kafka_security.apply conf sec with
  | Ok () -> Alcotest.fail "expected error for missing sasl_password"
  | Error msg ->
    Alcotest.(check bool) "message mentions sasl_password" true
      (contains msg "sasl_password")

let test_sasl_plaintext_missing_all () =
  let conf = Kafka_raw.conf_new () in
  let sec = Kafka_security.{
    protocol        = Sasl_plaintext;
    ssl_ca_location = None;
    sasl_mechanism  = None;
    sasl_username   = None;
    sasl_password   = None;
  } in
  match Kafka_security.apply conf sec with
  | Ok () -> Alcotest.fail "expected error when all SASL fields missing"
  | Error msg ->
    Alcotest.(check bool) "error covers all three missing fields" true
      (contains msg "sasl_mechanism" && contains msg "sasl_username" && contains msg "sasl_password")

let () =
  Alcotest.run "kafka_security" [
    "parse", [
      Alcotest.test_case "valid protocols"              `Quick test_protocol_of_string_valid;
      Alcotest.test_case "invalid protocol is an error" `Quick test_protocol_of_string_invalid;
      Alcotest.test_case "of_env rejects unknown protocol" `Quick test_of_env_rejects_unknown_protocol;
    ];
    "apply", [
      Alcotest.test_case "plaintext ok"               `Quick test_plaintext_ok;
      Alcotest.test_case "ssl no sasl ok"             `Quick test_ssl_no_sasl_ok;
      Alcotest.test_case "sasl_ssl all fields ok"     `Quick test_sasl_ssl_all_fields_ok;
      Alcotest.test_case "sasl missing mechanism"     `Quick test_sasl_missing_mechanism;
      Alcotest.test_case "sasl missing username"      `Quick test_sasl_missing_username;
      Alcotest.test_case "sasl missing password"      `Quick test_sasl_missing_password;
      Alcotest.test_case "sasl_plaintext all missing" `Quick test_sasl_plaintext_missing_all;
    ];
  ]
