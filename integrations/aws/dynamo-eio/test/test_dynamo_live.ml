(* Live DynamoDB smoke test, same shape as s3-eio's and aws-eio's. Skipped
   entirely unless DYNAMO_EIO_LIVE=1 is set: the default `dune runtest`
   must never touch a real AWS account or table.

   Required environment: DYNAMO_EIO_LIVE=1, DYNAMO_EIO_LIVE_TABLE=<a table
   you control, primary key: partition "pk" (S), sort "sk" (S)>, plus
   credentials Aws_credentials's Env_chain already knows how to read
   (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, optionally AWS_SESSION_TOKEN).
   AWS_REGION is optional, defaulting to us-east-1.

   Writes exactly one item per test run under a sun-live-test# prefixed key
   and deletes it in Fun.protect, so a failed assertion still cleans up. *)

let live_enabled () = Sys.getenv_opt "DYNAMO_EIO_LIVE" = Some "1"

let region () = Option.value (Sys.getenv_opt "AWS_REGION") ~default:"us-east-1"

let config () =
  let region = region () in
  { Dynamo_client.table = Option.value (Sys.getenv_opt "DYNAMO_EIO_LIVE_TABLE") ~default:"";
    region;
    credentials = Aws_credentials.of_env ~region ();
  }

let live_key = [ ("pk", Dynamo_value.S "sun-live-test#s3-eio-smoke"); ("sk", Dynamo_value.S "item") ]

let with_live_item ~net ~clock config item f =
  match Dynamo_client.put_item ~net ~clock config ~item with
  | Error e -> Alcotest.failf "PutItem failed: %s" (Dynamo_error.to_string e)
  | Ok () ->
    Fun.protect
      ~finally:(fun () ->
        match Dynamo_client.delete_item ~net ~clock config ~key:live_key with
        | Ok () | Error _ -> ())
      (fun () -> f ())

let test_put_get_delete_roundtrip () =
  if not (live_enabled ()) then
    Printf.printf "[skip] DYNAMO_EIO_LIVE not set to 1 — skipping live DynamoDB smoke test\n%!"
  else
    Eio_main.run @@ fun env ->
    let net = env#net and clock = env#clock in
    let config = config () in
    let item = live_key @ [ ("count", Dynamo_value.N "42") ] in
    with_live_item ~net ~clock config item (fun () ->
        match Dynamo_client.get_item ~net ~clock config ~key:live_key with
        | Error e -> Alcotest.failf "GetItem failed: %s" (Dynamo_error.to_string e)
        | Ok None -> Alcotest.fail "expected the item we just put"
        | Ok (Some got) ->
          Alcotest.(check bool) "count round-tripped" true
            (List.assoc_opt "count" got = Some (Dynamo_value.N "42")))

let test_missing_key_returns_none () =
  if not (live_enabled ()) then
    Printf.printf "[skip] DYNAMO_EIO_LIVE not set to 1 — skipping live DynamoDB smoke test\n%!"
  else
    Eio_main.run @@ fun env ->
    let config = config () in
    let missing_key = [ ("pk", Dynamo_value.S "sun-live-test#does-not-exist"); ("sk", Dynamo_value.S "item") ] in
    match Dynamo_client.get_item ~net:env#net ~clock:env#clock config ~key:missing_key with
    | Ok None -> ()
    | Ok (Some _) -> Alcotest.fail "expected the known-missing key to return None"
    | Error e -> Alcotest.failf "GetItem failed: %s" (Dynamo_error.to_string e)

let () =
  Alcotest.run "dynamo_live"
    [ ( "smoke",
        [ Alcotest.test_case "put/get/delete round trip" `Quick test_put_get_delete_roundtrip;
          Alcotest.test_case "known-missing key returns None" `Quick test_missing_key_returns_none;
        ] );
    ]
