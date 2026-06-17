open Sun_cli_manifest

let flag k v = render_helm_flag (k, v)

let () = Alcotest.run "helm_val" [
  "render_helm_flag", [
    Alcotest.test_case "bool true"  `Quick (fun () ->
      Alcotest.(check string) "same" "--set tls.enabled=true"  (flag "tls.enabled"  (Bool true)));
    Alcotest.test_case "bool false" `Quick (fun () ->
      Alcotest.(check string) "same" "--set tls.enabled=false" (flag "tls.enabled"  (Bool false)));
    Alcotest.test_case "float"      `Quick (fun () ->
      Alcotest.(check string) "same" "--set replicas=1"        (flag "replicas"     (Float 1.)));
    Alcotest.test_case "str"        `Quick (fun () ->
      Alcotest.(check string) "same" "--set-string tag=latest" (flag "tag"          (Str "latest")));
  ]
]
