let check_int  = Alcotest.(check int)
let check_str  = Alcotest.(check string)
let check_bool = Alcotest.(check bool)
let check_status =
  Alcotest.(check (of_pp (fun fmt -> function
    | Sun_process.Exited n -> Format.fprintf fmt "Exited %d" n
    | Signaled n -> Format.fprintf fmt "Signaled %d" n
    | Stopped n -> Format.fprintf fmt "Stopped %d" n)))

(* ── run / structured result ─────────────────────────────────────────────── *)

let test_run_success () =
  let r = Sun_process.run_shell ~echo:false "echo hello" in
  check_status "status"      (Sun_process.Exited 0) r.status;
  check_int  "exit code 0"   0       (Sun_process.exit_code r);
  check_str  "stdout"        "hello" r.stdout

let test_run_nonzero () =
  let r = Sun_process.run_shell ~echo:false "exit 42" in
  check_status "status" (Sun_process.Exited 42) r.status;
  check_int  "exit code 42" 42 (Sun_process.exit_code r)

let test_status_shell_codes () =
  check_int "exited" 42
    (Sun_process.status_to_exit_code (Sun_process.Exited 42));
  check_int "signaled" 143
    (Sun_process.status_to_exit_code (Sun_process.Signaled 15));
  check_int "stopped" 147
    (Sun_process.status_to_exit_code (Sun_process.Stopped 19))

let test_run_signaled () =
  let r = Sun_process.run_argv ~echo:false ["sh"; "-c"; "kill -TERM $$"] in
  match r.status with
  | Sun_process.Signaled 15 ->
      check_int "shell-compatible exit code" 143 (Sun_process.exit_code r)
  | status ->
      check_status "status" (Sun_process.Signaled 15) status

let test_run_stderr_captured () =
  let r = Sun_process.run_shell ~echo:false "echo bar >&2" in
  check_str  "stdout empty"  ""    r.stdout;
  check_str  "stderr"        "bar" r.stderr

let test_run_both_streams () =
  let r = Sun_process.run_shell ~echo:false "echo out; echo err >&2" in
  check_str  "stdout" "out" r.stdout;
  check_str  "stderr" "err" r.stderr

let test_run_command_not_found () =
  let r = Sun_process.run_shell ~echo:false "nonexistent_command_sun_process_test_abc123" in
  check_bool "exit code non-zero" true (Sun_process.exit_code r <> 0)

(* ── run_argv ────────────────────────────────────────────────────────────── *)

let test_run_argv_basic () =
  let r = Sun_process.run_argv ~echo:false ["echo"; "hello world"] in
  check_status "status"     (Sun_process.Exited 0) r.status;
  check_int  "exit code 0"  0             (Sun_process.exit_code r);
  check_str  "stdout"       "hello world" r.stdout

let test_run_argv_special_chars () =
  (* Argument with a space must arrive as one token, not two *)
  let r = Sun_process.run_argv ~echo:false ["printf"; "%s"; "a b"] in
  check_str "stdout with space" "a b" r.stdout

let test_run_argv_no_shell_interpretation () =
  let r = Sun_process.run_argv ~echo:false ["printf"; "%s"; "a; echo injected"] in
  check_int "exit code 0" 0 (Sun_process.exit_code r);
  check_str "metacharacters are literal" "a; echo injected" r.stdout

let test_run_argv_command_not_found () =
  let r =
    Sun_process.run_argv ~echo:false
      ["nonexistent_command_sun_process_test_abc123"]
  in
  check_status "status" (Sun_process.Exited 127) r.status;
  check_bool "exit code non-zero" true (Sun_process.exit_code r <> 0);
  check_str "stdout empty" "" r.stdout

(* ── lines ──────────────────────────────────────────────────────────────── *)

let test_lines_basic () =
  let ls = Sun_process.lines_shell ~echo:false "printf 'a\\nb\\nc'" in
  check_bool "three lines" true (List.length ls = 3);
  check_str  "first line"  "a" (List.nth ls 0);
  check_str  "last line"   "c" (List.nth ls 2)

let test_lines_empty_filtered () =
  (* Blank lines should be omitted from the result *)
  let ls = Sun_process.lines_shell ~echo:false "printf 'a\\n\\nb'" in
  check_bool "blank line filtered" true (List.length ls = 2)

let test_lines_stderr_not_captured () =
  (* stderr must not bleed into the stdout lines *)
  let ls = Sun_process.lines_shell ~echo:false "echo out; echo err >&2" in
  check_bool "only one line"          true (List.length ls = 1);
  check_str  "line is from stdout"    "out" (List.nth ls 0)

(* ── output ─────────────────────────────────────────────────────────────── *)

let test_output_trimmed () =
  let s = Sun_process.output_shell ~echo:false "printf '  hello  '" in
  check_str "trimmed" "hello" s

(* ── run_rc ─────────────────────────────────────────────────────────────── *)

let test_run_rc_success () =
  check_int "rc 0" 0 (Sun_process.run_shell_rc ~echo:false "true")

let test_run_rc_failure () =
  check_bool "rc non-zero" true (Sun_process.run_shell_rc ~echo:false "false" <> 0)

(* ── run_ok ─────────────────────────────────────────────────────────────── *)

let test_run_ok_success () =
  (* Should not raise *)
  Sun_process.run_shell_ok ~echo:false "true"

let test_run_ok_failure () =
  let raised =
    try Sun_process.run_shell_ok ~echo:false "false"; false
    with Failure _ -> true
  in
  check_bool "raises Failure on non-zero" true raised

(* ── entry point ─────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "sun_process"
    [ "run", [
        Alcotest.test_case "success result"         `Quick test_run_success
      ; Alcotest.test_case "non-zero exit code"     `Quick test_run_nonzero
      ; Alcotest.test_case "shell-compatible status codes" `Quick test_status_shell_codes
      ; Alcotest.test_case "signaled status"        `Quick test_run_signaled
      ; Alcotest.test_case "stderr captured"        `Quick test_run_stderr_captured
      ; Alcotest.test_case "both streams"           `Quick test_run_both_streams
      ; Alcotest.test_case "command not found"      `Quick test_run_command_not_found
      ]
    ; "run_argv", [
        Alcotest.test_case "basic argv"             `Quick test_run_argv_basic
      ; Alcotest.test_case "special chars quoted"   `Quick test_run_argv_special_chars
      ; Alcotest.test_case "no shell interpretation" `Quick test_run_argv_no_shell_interpretation
      ; Alcotest.test_case "command not found"       `Quick test_run_argv_command_not_found
      ]
    ; "lines", [
        Alcotest.test_case "basic lines"            `Quick test_lines_basic
      ; Alcotest.test_case "blank lines filtered"   `Quick test_lines_empty_filtered
      ; Alcotest.test_case "stderr excluded"        `Quick test_lines_stderr_not_captured
      ]
    ; "output", [
        Alcotest.test_case "trimmed string"         `Quick test_output_trimmed
      ]
    ; "run_rc", [
        Alcotest.test_case "success → 0"            `Quick test_run_rc_success
      ; Alcotest.test_case "failure → non-zero"     `Quick test_run_rc_failure
      ]
    ; "run_ok", [
        Alcotest.test_case "success → no raise"     `Quick test_run_ok_success
      ; Alcotest.test_case "failure → Failure"      `Quick test_run_ok_failure
      ]
    ]
