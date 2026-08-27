let test_tls_authenticator_fails_closed_without_ca_bundle () =
  Alcotest.(check bool) "missing CA paths are rejected"
    true
    (match Obs_prometheus_tls.authenticator
             ~ca_paths:["/sun/does/not/exist/ca-certificates.crt"] () with
     | Error `No_system_ca_bundle -> true
     | _ -> false)

let test_tls_authenticator_ignores_invalid_ca_bundle () =
  let path = Filename.temp_file "sun-invalid-ca" ".pem" in
  Fun.protect
    (fun () ->
       let oc = open_out path in
       output_string oc "not a pem certificate";
       close_out oc;
       Alcotest.(check bool) "invalid CA file is rejected"
         true
         (match Obs_prometheus_tls.authenticator ~ca_paths:[path] () with
          | Error `No_system_ca_bundle -> true
          | _ -> false))
    ~finally:(fun () -> Sys.remove path)

let test_tls_wrapper_returns_typed_error_without_ca_bundle () =
  Alcotest.(check bool) "wrapper setup returns typed CA error"
    true
    (match Obs_prometheus_tls.make_https_wrapper
             ~ca_paths:["/sun/does/not/exist/ca-certificates.crt"] () with
     | Error `No_system_ca_bundle -> true
     | _ -> false)

let () =
  let open Alcotest in
  run "obs_tls" [
    "tls", [
      test_case "authenticator fails closed without CA bundle" `Quick
        test_tls_authenticator_fails_closed_without_ca_bundle;
      test_case "authenticator ignores invalid CA bundle" `Quick
        test_tls_authenticator_ignores_invalid_ca_bundle;
      test_case "wrapper returns typed error without CA bundle" `Quick
        test_tls_wrapper_returns_typed_error_without_ca_bundle;
    ];
  ]
