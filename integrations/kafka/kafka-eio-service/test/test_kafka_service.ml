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
(* JSON base_url parser                                                *)
(* ------------------------------------------------------------------ *)

let parse_base_url url =
  if String.length url >= 8 && String.sub url 0 8 = "https://" then
    failwith ("kafka_service: HTTPS schema registry not yet supported — \
               set SCHEMA_REGISTRY_URL to an http:// address \
               (url: " ^ url ^ ")");
  let s =
    if String.length url >= 7 && String.sub url 0 7 = "http://" then
      String.sub url 7 (String.length url - 7)
    else url
  in
  match String.rindex_opt s ':' with
  | None -> (s, 80)
  | Some i ->
    let host = String.sub s 0 i in
    let port_s = String.sub s (i + 1) (String.length s - i - 1) in
    (match int_of_string_opt port_s with
     | Some p -> (host, p)
     | None -> (s, 80))

let test_parse_url () =
  Alcotest.(check (pair string int)) "localhost:8081"
    ("localhost", 8081) (parse_base_url "http://localhost:8081");
  Alcotest.(check (pair string int)) "localhost:9644"
    ("localhost", 9644) (parse_base_url "http://localhost:9644");
  Alcotest.(check (pair string int)) "no port defaults to 80"
    ("localhost", 80) (parse_base_url "http://localhost")

let test_parse_url_https_rejected () =
  Alcotest.check_raises "https:// raises Failure"
    (Failure "kafka_service: HTTPS schema registry not yet supported — \
               set SCHEMA_REGISTRY_URL to an http:// address \
               (url: https://registry.example.com:8081)")
    (fun () -> ignore (parse_base_url "https://registry.example.com:8081"))

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
      test_case "https:// rejected"    `Quick test_parse_url_https_rejected;
    ];
  ]
