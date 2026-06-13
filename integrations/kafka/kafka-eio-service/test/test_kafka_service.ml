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
(* JSON base_url parser                                                *)
(* ------------------------------------------------------------------ *)

let check_url msg expected url =
  let (eh, ep, et) = expected in
  let (ah, ap, at_) = Kafka_service.parse_base_url url in
  Alcotest.(check string) (msg ^ " host")   eh ah;
  Alcotest.(check int)    (msg ^ " port")   ep ap;
  Alcotest.(check bool)   (msg ^ " use_tls") et at_

let test_parse_url () =
  check_url "http://localhost:8081"  ("localhost", 8081, false) "http://localhost:8081";
  check_url "http://localhost:9644"  ("localhost", 9644, false) "http://localhost:9644";
  check_url "http no port"           ("localhost", 80,   false) "http://localhost"

let test_parse_url_https () =
  check_url "https:// with port"
    ("registry.example.com", 8081, true) "https://registry.example.com:8081";
  check_url "https:// default 443"
    ("registry.confluent.io", 443, true)  "https://registry.confluent.io"

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
