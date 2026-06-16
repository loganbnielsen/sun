let check_string msg expected actual =
  Alcotest.(check string) msg expected actual

let check_list_string msg expected actual =
  Alcotest.(check (list string)) msg expected actual

let check_option_string msg expected actual =
  Alcotest.(check (option string)) msg expected actual

let check_bool msg expected actual =
  Alcotest.(check bool) msg expected actual

(* ── parse_frontmatter ───────────────────────────────────────────────────── *)

let test_parse_empty () =
  let fm = Sundev_ticket.parse_frontmatter "no frontmatter here" in
  Alcotest.(check (list (pair string string))) "empty" [] fm

let test_parse_basic () =
  let content = "---\nid: FEAT-001\ntype: feature\nseverity: high\n---\n\nBody" in
  let fm = Sundev_ticket.parse_frontmatter content in
  check_option_string "id"       (Some "FEAT-001") (Sundev_ticket.fm_get fm "id");
  check_option_string "type"     (Some "feature")  (Sundev_ticket.fm_get fm "type");
  check_option_string "severity" (Some "high")     (Sundev_ticket.fm_get fm "severity")

let test_fm_get_missing () =
  let fm = Sundev_ticket.parse_frontmatter "---\nid: X-1\n---\n" in
  check_option_string "missing key" None (Sundev_ticket.fm_get fm "branch")

let test_fm_get_colon_in_value () =
  let content = "---\nurl: https://example.com/path\n---\n" in
  let fm = Sundev_ticket.parse_frontmatter content in
  check_option_string "colon in value"
    (Some "https://example.com/path") (Sundev_ticket.fm_get fm "url")

(* ── parse_depends ───────────────────────────────────────────────────────── *)

let test_depends_none () =
  let content = "---\nid: X\n---\n\n**Depends on:** None.\n" in
  check_list_string "none" [] (Sundev_ticket.parse_depends content)

let test_depends_single () =
  let content = "---\nid: X\n---\n\n**Depends on:** FEAT-001.\n" in
  check_list_string "single" ["FEAT-001"] (Sundev_ticket.parse_depends content)

let test_depends_multiple () =
  let content = "---\nid: X\n---\n\n**Depends on:** FEAT-001, EXP-008.\n" in
  check_list_string "multiple" ["FEAT-001"; "EXP-008"] (Sundev_ticket.parse_depends content)

let test_depends_missing () =
  let content = "---\nid: X\n---\n\nNo depends line.\n" in
  check_list_string "missing" [] (Sundev_ticket.parse_depends content)

(* ── has_human_decision_gate ─────────────────────────────────────────────── *)

let test_no_gate () =
  let content = "---\nid: X\n---\n\nJust a ticket body.\n" in
  check_bool "no gate" false (Sundev_ticket.has_human_decision_gate content)

let test_gate_tbd () =
  let content = "---\nid: X\n---\n\nSomething TBD here.\n" in
  check_bool "TBD gate" true (Sundev_ticket.has_human_decision_gate content)

let test_gate_section () =
  let content = "---\nid: X\n---\n\n## Decision Required\nChoose A or B.\n" in
  check_bool "section gate" true (Sundev_ticket.has_human_decision_gate content)

(* ── ticket_title ────────────────────────────────────────────────────────── *)

let test_title_basic () =
  let content = "---\nid: X\n---\n\n**Depends on:** None.\n\nFix the thing\n" in
  check_string "title" "Fix the thing" (Sundev_ticket.ticket_title content)

let test_title_no_frontmatter () =
  let content = "Just a title line\n\nBody here." in
  check_string "no frontmatter" "Just a title line" (Sundev_ticket.ticket_title content)

(* ── dependency_summary ──────────────────────────────────────────────────── *)

let test_dep_summary_empty () =
  check_string "empty" "none" (Sundev_ticket.dependency_summary [])

let test_dep_summary_list () =
  check_string "list" "A, B"
    (Sundev_ticket.dependency_summary ["A"; "B"])

(* ── ticket_states ───────────────────────────────────────────────────────── *)

let test_states_include_done () =
  check_bool "DONE present" true
    (List.mem "DONE" Sundev_ticket.ticket_states)

let test_states_include_rfe () =
  check_bool "READY_FOR_ENGINEERING present" true
    (List.mem "READY_FOR_ENGINEERING" Sundev_ticket.ticket_states)

let () =
  Alcotest.run "sundev_ticket" [
    "parse_frontmatter", [
      Alcotest.test_case "empty content"         `Quick test_parse_empty;
      Alcotest.test_case "basic fields"          `Quick test_parse_basic;
      Alcotest.test_case "missing key"           `Quick test_fm_get_missing;
      Alcotest.test_case "colon in value"        `Quick test_fm_get_colon_in_value;
    ];
    "parse_depends", [
      Alcotest.test_case "none"                  `Quick test_depends_none;
      Alcotest.test_case "single dep"            `Quick test_depends_single;
      Alcotest.test_case "multiple deps"         `Quick test_depends_multiple;
      Alcotest.test_case "no depends line"       `Quick test_depends_missing;
    ];
    "has_human_decision_gate", [
      Alcotest.test_case "no gate"               `Quick test_no_gate;
      Alcotest.test_case "TBD marker"            `Quick test_gate_tbd;
      Alcotest.test_case "section marker"        `Quick test_gate_section;
    ];
    "ticket_title", [
      Alcotest.test_case "skips depends line"    `Quick test_title_basic;
      Alcotest.test_case "no frontmatter"        `Quick test_title_no_frontmatter;
    ];
    "dependency_summary", [
      Alcotest.test_case "empty"                 `Quick test_dep_summary_empty;
      Alcotest.test_case "list"                  `Quick test_dep_summary_list;
    ];
    "ticket_states", [
      Alcotest.test_case "includes DONE"         `Quick test_states_include_done;
      Alcotest.test_case "includes RFE"          `Quick test_states_include_rfe;
    ];
  ]
