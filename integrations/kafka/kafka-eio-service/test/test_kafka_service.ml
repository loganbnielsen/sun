(** Unit tests for kafka-eio-service. No broker required. *)

(* ------------------------------------------------------------------ *)
(* Wire format — uses the production Confluent_wire codec              *)
(* ------------------------------------------------------------------ *)

let test_wire_roundtrip () =
  let json = `Assoc [("amount", `Int 100); ("currency", `String "USD")] in
  let schema_id = 42 in
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id json in
  match Kafka_service.Confluent_wire.decode encoded with
  | Error e -> Alcotest.failf "decode failed: %s" e
  | Ok (got_id, json_str) ->
    Alcotest.(check int) "schema id roundtrips" schema_id got_id;
    let decoded = Yojson.Safe.from_string json_str in
    Alcotest.(check string) "json roundtrips"
      (Yojson.Safe.to_string json)
      (Yojson.Safe.to_string decoded)

let test_wire_large_schema_id () =
  let schema_id = 0x00FFFFFF in
  let json = `String "hello" in
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id json in
  match Kafka_service.Confluent_wire.decode encoded with
  | Error e -> Alcotest.failf "decode failed: %s" e
  | Ok (got_id, _) ->
    Alcotest.(check int) "large schema id roundtrips" schema_id got_id

let test_wire_bad_magic () =
  let bad = Bytes.of_string "\x01\x00\x00\x00\x01{}" in
  Alcotest.(check bool) "bad magic returns error"
    true (Result.is_error (Kafka_service.Confluent_wire.decode bad))

let test_wire_too_short () =
  let bad = Bytes.of_string "\x00\x00" in
  Alcotest.(check bool) "too short returns error"
    true (Result.is_error (Kafka_service.Confluent_wire.decode bad))

let test_wire_magic_byte () =
  (* Verify the first byte of any encoded message is 0x00 *)
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id:1 (`String "x") in
  Alcotest.(check char) "magic byte is 0x00" '\x00' (Bytes.get encoded 0)

let test_wire_schema_id_big_endian () =
  (* schema_id 0x01020304 must appear at bytes 1..4 in big-endian order *)
  let encoded = Kafka_service.Confluent_wire.encode ~schema_id:0x01020304 (`String "x") in
  Alcotest.(check char) "byte 1" '\x01' (Bytes.get encoded 1);
  Alcotest.(check char) "byte 2" '\x02' (Bytes.get encoded 2);
  Alcotest.(check char) "byte 3" '\x03' (Bytes.get encoded 3);
  Alcotest.(check char) "byte 4" '\x04' (Bytes.get encoded 4)

(* ------------------------------------------------------------------ *)
(* URL construction via Uri (replaces hand-written parse_base_url)    *)
(* ------------------------------------------------------------------ *)

(* Exercises the same Uri.of_string (base_url ^ path) parsing http_do_once
   uses in production. *)

let check_uri msg ~expected_host ~expected_port ~expected_scheme url =
  let u = Uri.of_string url in
  Alcotest.(check (option string)) (msg ^ " host")
    (Some expected_host) (Uri.host u);
  Alcotest.(check (option int))   (msg ^ " port")
    expected_port (Uri.port u);
  Alcotest.(check (option string)) (msg ^ " scheme")
    (Some expected_scheme) (Uri.scheme u)

let test_parse_url () =
  check_uri "http://localhost:8081"
    ~expected_host:"localhost" ~expected_port:(Some 8081) ~expected_scheme:"http"
    "http://localhost:8081";
  check_uri "http://localhost:9644"
    ~expected_host:"localhost" ~expected_port:(Some 9644) ~expected_scheme:"http"
    "http://localhost:9644";
  check_uri "http no explicit port"
    ~expected_host:"localhost" ~expected_port:None ~expected_scheme:"http"
    "http://localhost"

let test_parse_url_https () =
  check_uri "https:// with explicit port"
    ~expected_host:"registry.example.com" ~expected_port:(Some 8081) ~expected_scheme:"https"
    "https://registry.example.com:8081";
  check_uri "https:// no explicit port"
    ~expected_host:"registry.confluent.io" ~expected_port:None ~expected_scheme:"https"
    "https://registry.confluent.io"

(* ------------------------------------------------------------------ *)
(* Env config                                                          *)
(* ------------------------------------------------------------------ *)

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

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect f ~finally:(fun () ->
    Unix.putenv name (Option.value old ~default:""))

let test_config_of_env_rejects_unknown_security_protocol () =
  with_env "KAFKA_SECURITY_PROTOCOL" "scram" (fun () ->
    match Kafka_service.config_of_env () with
    | Ok _ -> Alcotest.fail "expected invalid security protocol to fail"
    | Error msg ->
      Alcotest.(check bool) "clear env protocol error" true
        (contains msg "KAFKA_SECURITY_PROTOCOL"))

(* ------------------------------------------------------------------ *)
(* Topic names                                                         *)
(* ------------------------------------------------------------------ *)

let test_topic_name_accepts_kafka_compatible_names () =
  let check name =
    match Kafka_service.topic_name name with
    | Ok topic ->
      Alcotest.(check string) name name topic
    | Error e -> Alcotest.failf "%s should be valid: %s" name e
  in
  List.iter check [
    "orders";
    "sun-demo-orders";
    "payments.charges_v1";
    "__consumer_offsets";
  ]

let test_topic_name_rejects_invalid_names () =
  let long_name = String.make 250 'a' in
  let check name =
    match Kafka_service.topic_name name with
    | Ok _ -> Alcotest.failf "%S should be invalid" name
    | Error _ -> ()
  in
  List.iter check [
    "";
    ".";
    "..";
    "orders/v1";
    "orders v1";
    long_name;
  ]

(* ------------------------------------------------------------------ *)
(* Schema Registry response decoding                                  *)
(* ------------------------------------------------------------------ *)

let result_error () = Alcotest.testable
  (fun fmt -> function
    | Ok _ -> Format.fprintf fmt "Ok _"
    | Error e -> Format.fprintf fmt "Error %S" e)
  (=)

let test_decode_compatibility_response () =
  match Kafka_service_schema.decode_compatibility_response {|{"is_compatible":true}|} with
  | Ok response ->
    Alcotest.(check bool) "is compatible" true
      response.Kafka_service_schema.is_compatible
  | Error e -> Alcotest.failf "decode failed: %s" e

let test_decode_compatibility_response_errors () =
  Alcotest.(check (result_error ())) "missing field"
    (Error {|unexpected registry response: {"ok":true}|})
    (Kafka_service_schema.decode_compatibility_response {|{"ok":true}|});
  Alcotest.(check (result_error ())) "malformed json"
    (Error {|json parse error in registry response: {"is_compatible":|})
    (Kafka_service_schema.decode_compatibility_response {|{"is_compatible":|})

let test_decode_registration_response () =
  match Kafka_service_schema.decode_registration_response {|{"id":42}|} with
  | Ok response ->
    Alcotest.(check int) "schema id" 42
      response.Kafka_service_schema.id
  | Error e -> Alcotest.failf "decode failed: %s" e

let test_decode_registration_response_errors () =
  Alcotest.(check (result_error ())) "missing id"
    (Error {|schema registry: missing 'id' in: {"schema":{}}|})
    (Kafka_service_schema.decode_registration_response {|{"schema":{}}|});
  Alcotest.(check (result_error ())) "unexpected shape"
    (Error {|schema registry: unexpected response: []|})
    (Kafka_service_schema.decode_registration_response {|[]|});
  Alcotest.(check (result_error ())) "malformed json"
    (Error {|schema registry: json parse error in: {"id":|})
    (Kafka_service_schema.decode_registration_response {|{"id":|})

(* ------------------------------------------------------------------ *)
(* Redpanda admin topic metadata decoding                             *)
(* ------------------------------------------------------------------ *)

let test_decode_topic_partitions () =
  match Kafka_service_intf.decode_topic_partitions
          {|{"partitions":[{"id":0},{"id":1},{"id":2}]}|} with
  | Ok (Kafka_service_intf.Topic_partitions partitions) ->
    Alcotest.(check int) "partition count" 3 partitions
  | Ok Kafka_service_intf.Topic_not_found ->
    Alcotest.fail "decoder should not return Topic_not_found for HTTP 200"
  | Error e ->
    Alcotest.failf "decode failed: %s"
      (Kafka_service_intf.topic_partition_error_to_string e)

let test_decode_topic_partitions_errors () =
  let check_error name body =
    match Kafka_service_intf.decode_topic_partitions body with
    | Ok _ -> Alcotest.failf "%s: expected malformed response" name
    | Error e ->
      Alcotest.(check string) name
        ("malformed admin API topic response: " ^ body)
        (Kafka_service_intf.topic_partition_error_to_string e)
  in
  check_error "missing partitions" {|{"name":"orders"}|};
  check_error "partitions not list" {|{"partitions":3}|};
  check_error "malformed json" {|{"partitions":|}

(* ------------------------------------------------------------------ *)
(* Runner                                                              *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run "kafka_service" [
    "wire_format", [
      test_case "roundtrip"              `Quick test_wire_roundtrip;
      test_case "large schema id"        `Quick test_wire_large_schema_id;
      test_case "bad magic byte"         `Quick test_wire_bad_magic;
      test_case "too short"              `Quick test_wire_too_short;
      test_case "magic byte is 0x00"     `Quick test_wire_magic_byte;
      test_case "schema id big-endian"   `Quick test_wire_schema_id_big_endian;
    ];
    "url_parser", [
      test_case "parse base url"       `Quick test_parse_url;
      test_case "https:// tls=true"   `Quick test_parse_url_https;
    ];
    "config", [
      test_case "unknown security protocol fails clearly" `Quick test_config_of_env_rejects_unknown_security_protocol;
    ];
    "topic_name", [
      test_case "accepts Kafka-compatible names" `Quick test_topic_name_accepts_kafka_compatible_names;
      test_case "rejects invalid names" `Quick test_topic_name_rejects_invalid_names;
    ];
    "schema_registry_decoding", [
      test_case "compatibility response" `Quick test_decode_compatibility_response;
      test_case "compatibility response errors" `Quick test_decode_compatibility_response_errors;
      test_case "registration response" `Quick test_decode_registration_response;
      test_case "registration response errors" `Quick test_decode_registration_response_errors;
    ];
    "admin_topic_metadata", [
      test_case "topic partitions" `Quick test_decode_topic_partitions;
      test_case "topic partition errors" `Quick test_decode_topic_partitions_errors;
    ];
  ]
