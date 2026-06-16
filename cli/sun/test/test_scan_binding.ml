let () =
  let open Alcotest in
  run "scan_binding" [
    "let-binding whitespace", [
      test_case "standard spacing" `Quick (fun () ->
        let content = {|let topic_name = "my-topic"|} in
        check (list string) "found" ["my-topic"]
          (Sun_cli_manifest.scan_binding ~is_let:true "topic_name" content));
      test_case "no spaces around =" `Quick (fun () ->
        let content = {|let topic_name="my-topic"|} in
        check (list string) "found" ["my-topic"]
          (Sun_cli_manifest.scan_binding ~is_let:true "topic_name" content));
      test_case "extra spaces" `Quick (fun () ->
        let content = {|let topic_name  =  "my-topic"|} in
        check (list string) "found" ["my-topic"]
          (Sun_cli_manifest.scan_binding ~is_let:true "topic_name" content));
      test_case "comment line skipped" `Quick (fun () ->
        let content = "(* let topic_name = \"ignored\" *)" in
        check (list string) "empty" []
          (Sun_cli_manifest.scan_binding ~is_let:true "topic_name" content));
    ];
    "non-let binding whitespace", [
      test_case "standard spacing" `Quick (fun () ->
        let content = {|  schedule = "0 * * * *"|} in
        check (list string) "found" ["0 * * * *"]
          (Sun_cli_manifest.scan_binding ~is_let:false "schedule" content));
      test_case "no spaces around =" `Quick (fun () ->
        let content = {|  schedule="0 * * * *"|} in
        check (list string) "found" ["0 * * * *"]
          (Sun_cli_manifest.scan_binding ~is_let:false "schedule" content));
      test_case "extra spaces" `Quick (fun () ->
        let content = {|  schedule  =  "0 * * * *"|} in
        check (list string) "found" ["0 * * * *"]
          (Sun_cli_manifest.scan_binding ~is_let:false "schedule" content));
      test_case "comment line skipped" `Quick (fun () ->
        let content = "(* schedule = \"ignored\" *)" in
        check (list string) "empty" []
          (Sun_cli_manifest.scan_binding ~is_let:false "schedule" content));
      test_case "prefix not matched" `Quick (fun () ->
        let content = {|  my_schedule = "should-not-match"|} in
        check (list string) "empty" []
          (Sun_cli_manifest.scan_binding ~is_let:false "schedule" content));
    ];
  ]
