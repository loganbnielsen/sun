(* Live S3 smoke test — the remaining half of AWS-001 (see
   project/tickets/READY_FOR_ENGINEERING/AWS-001.md and
   docs/planning/OPAM_FOUNDATION_TRACKER.md), the STS half already merged
   into aws-eio. Skipped entirely unless S3_EIO_LIVE=1 is set: the default
   `dune runtest` must never touch a real AWS account or bucket.

   Required environment: S3_EIO_LIVE=1, S3_EIO_LIVE_BUCKET=<a bucket you
   control>, plus credentials Aws_credentials's Env_chain already knows how
   to read (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, optionally
   AWS_SESSION_TOKEN). AWS_REGION is optional, defaulting to us-east-1.

   Writes exactly one tiny object under the sun-live-test/ prefix per test
   run and deletes it in Fun.protect, so a failed assertion still cleans up.
   The IAM policy this needs is documented in
   docs/planning/OPAM_FOUNDATION_TRACKER.md's Phase 5 section: PutObject/
   GetObject/DeleteObject scoped to s3:::<bucket>/sun-live-test/*, plus
   ListBucket scoped to that prefix. *)

let live_enabled () = Sys.getenv_opt "S3_EIO_LIVE" = Some "1"

let region () = Option.value (Sys.getenv_opt "AWS_REGION") ~default:"us-east-1"

let config () =
  let region = region () in
  { S3_client.bucket = Option.value (Sys.getenv_opt "S3_EIO_LIVE_BUCKET") ~default:"";
    region;
    credentials = Aws_credentials.of_env ~region ();
    endpoint = None }

let live_key = "sun-live-test/s3-eio-smoke.txt"
let live_body = "s3-eio live smoke test"

let with_live_object ~net ~clock config f =
  match S3_client.put_object ~net ~clock config ~key:live_key ~body:live_body with
  | Error e -> Alcotest.failf "PutObject failed: %s" (S3_error.to_string e)
  | Ok () ->
    Fun.protect
      ~finally:(fun () ->
        match S3_client.delete_object ~net ~clock config ~key:live_key with
        | Ok () | Error _ -> ())
      (fun () -> f ())

let test_put_head_get_delete_roundtrip () =
  if not (live_enabled ()) then
    Printf.printf "[skip] S3_EIO_LIVE not set to 1 — skipping live S3 smoke test\n%!"
  else
    Eio_main.run @@ fun env ->
    let net = env#net and clock = env#clock in
    let config = config () in
    with_live_object ~net ~clock config (fun () ->
        (match S3_client.head_object ~net ~clock config ~key:live_key with
         | Error e -> Alcotest.failf "HeadObject failed: %s" (S3_error.to_string e)
         | Ok { content_length; _ } ->
           Alcotest.(check (option int)) "Content-Length matches the body we wrote"
             (Some (String.length live_body)) content_length);
        match S3_client.get_object ~net ~clock config ~key:live_key with
        | Error e -> Alcotest.failf "GetObject failed: %s" (S3_error.to_string e)
        | Ok body -> Alcotest.(check string) "round-tripped body" live_body body)

let test_missing_key_error_path () =
  if not (live_enabled ()) then
    Printf.printf "[skip] S3_EIO_LIVE not set to 1 — skipping live S3 smoke test\n%!"
  else
    Eio_main.run @@ fun env ->
    let config = config () in
    match S3_client.head_object ~net:env#net ~clock:env#clock config ~key:"sun-live-test/does-not-exist.txt" with
    | Error S3_error.Not_found -> ()
    | Error e -> Alcotest.failf "expected Not_found, got %s" (S3_error.to_string e)
    | Ok _ -> Alcotest.fail "expected the known-missing key to 404"

let () =
  Alcotest.run "s3_live"
    [ ( "smoke",
        [ Alcotest.test_case "put/head/get/delete round trip" `Quick test_put_head_get_delete_roundtrip;
          Alcotest.test_case "known-missing key returns Not_found" `Quick test_missing_key_error_path;
        ] );
    ]
