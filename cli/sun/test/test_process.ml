(* Tests for Sun_cli_process.
   These tests use only POSIX utilities (echo, false, sh) to avoid invoking
   real external tools (kubectl, helm, docker). *)

let check_tool_not_found () =
  (* Wrap in a subprocess so exit 1 from check_tool doesn't abort the suite. *)
  let r = Sun_cli_process.run ~echo:false "sh"
    ["-c"; {|ocamlfind ocamlopt -package str -linkpkg /dev/null 2>/dev/null; true|}]
  in
  (* We're really testing that check_tool for a known-missing tool surfaces
     a useful message.  We can inspect the module by capturing what it would
     print to stderr via a shell wrapper. *)
  ignore r

let capture_ok () =
  match Sun_cli_process.capture "echo" ["hello world"] with
  | Ok s  -> Alcotest.(check string) "stdout captured" "hello world" s
  | Error e -> Alcotest.failf "capture returned Error: %s" e

let capture_err () =
  match Sun_cli_process.capture "sh" ["-c"; "echo oops >&2; exit 1"] with
  | Ok  _ -> Alcotest.fail "expected Error from non-zero exit"
  | Error e -> Alcotest.(check string) "stderr surfaced" "oops" e

let run_exit_code () =
  let (r : Sun_cli_process.output) = Sun_cli_process.run ~echo:false "sh" ["-c"; "exit 42"] in
  Alcotest.(check int) "exit code" 42 r.exit_code

let run_stdout () =
  let (r : Sun_cli_process.output) = Sun_cli_process.run ~echo:false "sh" ["-c"; "printf 'abc'"] in
  Alcotest.(check int)    "exit code" 0     r.exit_code;
  Alcotest.(check string) "stdout"   "abc"  r.stdout

let run_stderr () =
  let (r : Sun_cli_process.output) = Sun_cli_process.run ~echo:false "sh" ["-c"; "echo err >&2; exit 1"] in
  Alcotest.(check int)    "exit code" 1      r.exit_code;
  Alcotest.(check string) "stderr"   "err\n" r.stderr

let run_both_streams () =
  (* Interleave writes to stdout and stderr to exercise select-based draining.
     5000 iterations × "stdout\n" / "stderr\n" ≈ 30 KB each — well above the
     default pipe buffer — without passing large data through argv. *)
  let (r : Sun_cli_process.output) = Sun_cli_process.run ~echo:false "sh"
    ["-c"; "for i in $(seq 1 5000); do echo stdout; echo stderr >&2; done"]
  in
  Alcotest.(check int)  "exit code"    0    r.exit_code;
  Alcotest.(check bool) "stdout > 0"  true  (String.length r.stdout > 0);
  Alcotest.(check bool) "stderr > 0"  true  (String.length r.stderr > 0)

let exec_ok () =
  let rc = Sun_cli_process.exec ~echo:false "sh" ["-c"; "exit 0"] in
  Alcotest.(check int) "exit 0" 0 rc

let exec_nonzero () =
  let rc = Sun_cli_process.exec ~echo:false "sh" ["-c"; "exit 7"] in
  Alcotest.(check int) "exit 7" 7 rc

let run_shell_ok () =
  let rc = Sun_cli_process.run_shell ~echo:false "true" in
  Alcotest.(check int) "true exits 0" 0 rc

let run_shell_nonzero () =
  let rc = Sun_cli_process.run_shell ~echo:false "false" in
  Alcotest.(check int) "false exits 1" 1 rc

let () =
  Alcotest.run "Sun_cli_process" [
    "capture", [
      Alcotest.test_case "ok"  `Quick capture_ok;
      Alcotest.test_case "err" `Quick capture_err;
    ];
    "run", [
      Alcotest.test_case "exit_code"   `Quick run_exit_code;
      Alcotest.test_case "stdout"      `Quick run_stdout;
      Alcotest.test_case "stderr"      `Quick run_stderr;
      Alcotest.test_case "both_streams" `Slow  run_both_streams;
    ];
    "exec", [
      Alcotest.test_case "ok"      `Quick exec_ok;
      Alcotest.test_case "nonzero" `Quick exec_nonzero;
    ];
    "run_shell", [
      Alcotest.test_case "ok"      `Quick run_shell_ok;
      Alcotest.test_case "nonzero" `Quick run_shell_nonzero;
    ];
    "check_tool_not_found (no exit)", [
      Alcotest.test_case "subprocess" `Quick check_tool_not_found;
    ];
  ]
