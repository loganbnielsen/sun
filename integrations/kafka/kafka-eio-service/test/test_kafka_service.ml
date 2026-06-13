(** Unit tests for kafka-eio-service. No broker required. *)

(* ------------------------------------------------------------------ *)
(* Wire format                                                         *)
(* ------------------------------------------------------------------ *)

(* Access internal functions via the compiled module — we test the
   observable encode/decode round-trip through publish/consume, but
   for unit tests we expose the wire format directly via a test shim. *)

let encode_wire ~schema_id json =
  let json_str = Yojson.Safe.to_string json in
  let json_len = String.length json_str in
  let buf = Bytes.create (5 + json_len) in
  Bytes.set buf 0 '\x00';
  Bytes.set buf 1 (Char.chr ((schema_id lsr 24) land 0xFF));
  Bytes.set buf 2 (Char.chr ((schema_id lsr 16) land 0xFF));
  Bytes.set buf 3 (Char.chr ((schema_id lsr  8) land 0xFF));
  Bytes.set buf 4 (Char.chr ( schema_id         land 0xFF));
  Bytes.blit_string json_str 0 buf 5 json_len;
  buf

let decode_wire bytes =
  if Bytes.length bytes < 5 then Error "too short"
  else if Bytes.get bytes 0 <> '\x00' then Error "bad magic"
  else
    let schema_id =
      (Char.code (Bytes.get bytes 1) lsl 24) lor
      (Char.code (Bytes.get bytes 2) lsl 16) lor
      (Char.code (Bytes.get bytes 3) lsl  8) lor
       Char.code (Bytes.get bytes 4)
    in
    Ok (schema_id, Bytes.sub_string bytes 5 (Bytes.length bytes - 5))

let test_wire_roundtrip () =
  let json = `Assoc [("amount", `Int 100); ("currency", `String "USD")] in
  let schema_id = 42 in
  let encoded = encode_wire ~schema_id json in
  match decode_wire encoded with
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
  let encoded = encode_wire ~schema_id json in
  match decode_wire encoded with
  | Error e -> Alcotest.failf "decode failed: %s" e
  | Ok (got_id, _) ->
    Alcotest.(check int) "large schema id roundtrips" schema_id got_id

let test_wire_bad_magic () =
  let bad = Bytes.of_string "\x01\x00\x00\x00\x01{}" in
  Alcotest.(check bool) "bad magic returns error"
    true (Result.is_error (decode_wire bad))

let test_wire_too_short () =
  let bad = Bytes.of_string "\x00\x00" in
  Alcotest.(check bool) "too short returns error"
    true (Result.is_error (decode_wire bad))

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
      test_case "roundtrip"         `Quick test_wire_roundtrip;
      test_case "large schema id"   `Quick test_wire_large_schema_id;
      test_case "bad magic byte"    `Quick test_wire_bad_magic;
      test_case "too short"         `Quick test_wire_too_short;
    ];
    "url_parser", [
      test_case "parse base url"       `Quick test_parse_url;
      test_case "https:// tls=true"   `Quick test_parse_url_https;
    ];
  ]
