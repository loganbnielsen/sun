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

(* Verify that Uri.of_string correctly parses the URLs we pass to the
   HTTP client.  This exercises the same parsing path used in production
   since http_do_once calls Uri.of_string (base_url ^ path). *)

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
  ]
