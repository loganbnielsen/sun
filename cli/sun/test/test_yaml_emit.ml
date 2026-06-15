(* Tests for Sun_cli_yaml.emit_scalar.
   Covers: bare strings, strings with colons, hashes, quotes, newlines,
   empty string, boolean-like values, numeric-like strings, leading special
   chars, and multi-line values. *)

let check = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let starts_with s prefix =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix

(* ── Bare scalars ────────────────────────────────────────────────────────── *)

let test_bare_word () =
  (* Plain identifiers are emitted without quotes *)
  check "bare word" "staging" (Sun_cli_yaml.emit_scalar "staging")

let test_bare_url_path () =
  (* A path without colons is bare *)
  check "bare path" "/healthz" (Sun_cli_yaml.emit_scalar "/healthz")

let test_bare_k8s_resource_name () =
  check "k8s name" "my-service" (Sun_cli_yaml.emit_scalar "my-service")

(* ── Colon-containing values ─────────────────────────────────────────────── *)

let test_url_with_colon () =
  (* URLs with "://" must be double-quoted *)
  let s = "http://redpanda.redpanda.svc.cluster.local:9093" in
  let result = Sun_cli_yaml.emit_scalar s in
  check_bool "url starts with quote" true (starts_with result "\"");
  check_bool "url ends with quote"   true (result.[String.length result - 1] = '"')

let test_colon_in_middle () =
  let s = "key: value" in
  let result = Sun_cli_yaml.emit_scalar s in
  check_bool "colon value quoted" true (starts_with result "\"")

(* ── Hash-containing values ──────────────────────────────────────────────── *)

let test_hash_in_value () =
  (* A hash in the middle of a string must be quoted (YAML comment marker) *)
  let s = "config # comment" in
  let result = Sun_cli_yaml.emit_scalar s in
  check_bool "hash value quoted" true (starts_with result "\"")

let test_leading_hash () =
  let s = "#comment" in
  let result = Sun_cli_yaml.emit_scalar s in
  check_bool "leading hash quoted" true (starts_with result "\"")

(* ── Quote-containing values ─────────────────────────────────────────────── *)

let test_double_quote_in_value () =
  let s = {|say "hello"|} in
  let result = Sun_cli_yaml.emit_scalar s in
  check_bool "double quote value quoted" true (starts_with result "\"")

let test_single_quote_in_value () =
  let s = "it's fine" in
  let result = Sun_cli_yaml.emit_scalar s in
  check_bool "single quote value quoted" true (starts_with result "\"")

(* ── Newline-containing values ───────────────────────────────────────────── *)

let test_newline_in_value () =
  let s = "line1\nline2" in
  let result = Sun_cli_yaml.emit_scalar s in
  check_bool "newline value quoted" true (starts_with result "\"");
  (* The newline must be escaped as \n inside the double-quoted string *)
  check_bool "newline escaped" true
    (let len = String.length result in
     let inner = String.sub result 1 (len - 2) in
     let found = ref false in
     for i = 0 to String.length inner - 2 do
       if inner.[i] = '\\' && inner.[i+1] = 'n' then found := true
     done;
     !found)

(* ── Empty string ────────────────────────────────────────────────────────── *)

let test_empty_string () =
  (* Empty string must be quoted so it is not interpreted as YAML null *)
  check "empty string" {|""|} (Sun_cli_yaml.emit_scalar "")

(* ── Boolean-like strings ────────────────────────────────────────────────── *)

let test_true_string () =
  let result = Sun_cli_yaml.emit_scalar "true" in
  check_bool "true quoted" true (starts_with result "\"")

let test_false_string () =
  let result = Sun_cli_yaml.emit_scalar "false" in
  check_bool "false quoted" true (starts_with result "\"")

let test_yes_string () =
  let result = Sun_cli_yaml.emit_scalar "yes" in
  check_bool "yes quoted" true (starts_with result "\"")

let test_no_string () =
  let result = Sun_cli_yaml.emit_scalar "no" in
  check_bool "no quoted" true (starts_with result "\"")

let test_on_string () =
  let result = Sun_cli_yaml.emit_scalar "on" in
  check_bool "on quoted" true (starts_with result "\"")

let test_off_string () =
  let result = Sun_cli_yaml.emit_scalar "off" in
  check_bool "off quoted" true (starts_with result "\"")

let test_null_string () =
  let result = Sun_cli_yaml.emit_scalar "null" in
  check_bool "null quoted" true (starts_with result "\"")

let test_tilde_string () =
  let result = Sun_cli_yaml.emit_scalar "~" in
  check_bool "~ quoted" true (starts_with result "\"")

(* Case-insensitive: YAML boolean matching is case-insensitive *)
let test_true_uppercase () =
  let result = Sun_cli_yaml.emit_scalar "True" in
  check_bool "True quoted" true (starts_with result "\"")

let test_false_uppercase () =
  let result = Sun_cli_yaml.emit_scalar "FALSE" in
  check_bool "FALSE quoted" true (starts_with result "\"")

(* ── Numeric-like strings ────────────────────────────────────────────────── *)

let test_integer_string () =
  (* A string that looks like an integer must be quoted to stay a string *)
  let result = Sun_cli_yaml.emit_scalar "42" in
  check_bool "integer string quoted" true (starts_with result "\"")

let test_float_string () =
  let result = Sun_cli_yaml.emit_scalar "3.14" in
  check_bool "float string quoted" true (starts_with result "\"")

let test_negative_integer () =
  let result = Sun_cli_yaml.emit_scalar "-1" in
  check_bool "negative integer quoted" true (starts_with result "\"")

(* ── Non-numeric strings that look similar ──────────────────────────────── *)

let test_alphanumeric_not_quoted () =
  (* "abc123" is not a number and has no special chars — should be bare *)
  let result = Sun_cli_yaml.emit_scalar "abc123" in
  check_bool "alphanumeric not quoted" false (starts_with result "\"")

let test_version_string () =
  (* "1.2.3" has two dots — not a float, so bare *)
  let result = Sun_cli_yaml.emit_scalar "1.2.3" in
  check_bool "version string not quoted" false (starts_with result "\"")

(* ── Kubernetes/Sun-specific real-world values ───────────────────────────── *)

let test_postgres_url () =
  let s = "postgresql://user:pass@db.example.com:5432/app" in
  let result = Sun_cli_yaml.emit_scalar s in
  check_bool "postgres url quoted" true (starts_with result "\"")

let test_kafka_broker () =
  let s = "redpanda.redpanda.svc.cluster.local:9093" in
  let result = Sun_cli_yaml.emit_scalar s in
  check_bool "kafka broker quoted" true (starts_with result "\"")

let test_loki_url () =
  let s = "http://loki.monitoring.svc.cluster.local:3100" in
  let result = Sun_cli_yaml.emit_scalar s in
  check_bool "loki url quoted" true (starts_with result "\"")

let test_cron_schedule () =
  (* Cron schedule "0 9 * * 1" has spaces but no YAML-special chars — bare *)
  let s = "0 9 * * 1" in
  let result = Sun_cli_yaml.emit_scalar s in
  (* Spaces alone don't force quoting in our emitter; we emit bare *)
  check "cron schedule" s result

let test_memory_limit () =
  (* "128Mi" is not a number — bare *)
  check "memory limit" "128Mi" (Sun_cli_yaml.emit_scalar "128Mi")

let test_cpu_limit () =
  (* "100m" is not a number — bare *)
  check "cpu limit" "100m" (Sun_cli_yaml.emit_scalar "100m")

(* ── Roundtrip property: double-quoted output contains the original string ── *)

let roundtrip_check label s =
  let emitted = Sun_cli_yaml.emit_scalar s in
  if starts_with emitted "\"" then begin
    (* Strip outer quotes and unescape to verify the original string is recoverable *)
    let inner = String.sub emitted 1 (String.length emitted - 2) in
    (* Simple unescape: replace \n → newline, \\ → backslash *)
    let buf = Buffer.create (String.length inner) in
    let i = ref 0 in
    while !i < String.length inner do
      if inner.[!i] = '\\' && !i + 1 < String.length inner then begin
        (match inner.[!i + 1] with
         | 'n'  -> Buffer.add_char buf '\n'
         | 'r'  -> Buffer.add_char buf '\r'
         | 't'  -> Buffer.add_char buf '\t'
         | '"'  -> Buffer.add_char buf '"'
         | '\\' -> Buffer.add_char buf '\\'
         | c    -> Buffer.add_char buf '\\'; Buffer.add_char buf c);
        i := !i + 2
      end else begin
        Buffer.add_char buf inner.[!i];
        i := !i + 1
      end
    done;
    check (label ^ " roundtrip") s (Buffer.contents buf)
  end

let test_roundtrip_postgres_url () =
  roundtrip_check "postgres url"
    "postgresql://user:pass@db.example.com:5432/app"

let test_roundtrip_newline () =
  roundtrip_check "newline" "line1\nline2"

let test_roundtrip_double_quote () =
  roundtrip_check "double quote" {|say "hello"|}

let test_roundtrip_backslash () =
  roundtrip_check "backslash" "path\\to\\file"

let () =
  Alcotest.run "yaml_emit"
    [ "bare_scalars", [
        Alcotest.test_case "bare word"           `Quick test_bare_word
      ; Alcotest.test_case "bare url path"       `Quick test_bare_url_path
      ; Alcotest.test_case "bare k8s name"       `Quick test_bare_k8s_resource_name
      ]
    ; "colon", [
        Alcotest.test_case "url with colon"      `Quick test_url_with_colon
      ; Alcotest.test_case "colon in middle"     `Quick test_colon_in_middle
      ]
    ; "hash", [
        Alcotest.test_case "hash in value"       `Quick test_hash_in_value
      ; Alcotest.test_case "leading hash"        `Quick test_leading_hash
      ]
    ; "quotes", [
        Alcotest.test_case "double quote"        `Quick test_double_quote_in_value
      ; Alcotest.test_case "single quote"        `Quick test_single_quote_in_value
      ]
    ; "newlines", [
        Alcotest.test_case "newline in value"    `Quick test_newline_in_value
      ]
    ; "empty", [
        Alcotest.test_case "empty string"        `Quick test_empty_string
      ]
    ; "booleans", [
        Alcotest.test_case "true"                `Quick test_true_string
      ; Alcotest.test_case "false"               `Quick test_false_string
      ; Alcotest.test_case "yes"                 `Quick test_yes_string
      ; Alcotest.test_case "no"                  `Quick test_no_string
      ; Alcotest.test_case "on"                  `Quick test_on_string
      ; Alcotest.test_case "off"                 `Quick test_off_string
      ; Alcotest.test_case "null"                `Quick test_null_string
      ; Alcotest.test_case "tilde"               `Quick test_tilde_string
      ; Alcotest.test_case "True"                `Quick test_true_uppercase
      ; Alcotest.test_case "FALSE"               `Quick test_false_uppercase
      ]
    ; "numerics", [
        Alcotest.test_case "integer string"      `Quick test_integer_string
      ; Alcotest.test_case "float string"        `Quick test_float_string
      ; Alcotest.test_case "negative integer"    `Quick test_negative_integer
      ; Alcotest.test_case "alphanumeric bare"   `Quick test_alphanumeric_not_quoted
      ; Alcotest.test_case "version string bare" `Quick test_version_string
      ]
    ; "k8s_values", [
        Alcotest.test_case "postgres url"        `Quick test_postgres_url
      ; Alcotest.test_case "kafka broker"        `Quick test_kafka_broker
      ; Alcotest.test_case "loki url"            `Quick test_loki_url
      ; Alcotest.test_case "cron schedule"       `Quick test_cron_schedule
      ; Alcotest.test_case "memory limit"        `Quick test_memory_limit
      ; Alcotest.test_case "cpu limit"           `Quick test_cpu_limit
      ]
    ; "roundtrip", [
        Alcotest.test_case "postgres url"        `Quick test_roundtrip_postgres_url
      ; Alcotest.test_case "newline"             `Quick test_roundtrip_newline
      ; Alcotest.test_case "double quote"        `Quick test_roundtrip_double_quote
      ; Alcotest.test_case "backslash"           `Quick test_roundtrip_backslash
      ]
    ]
