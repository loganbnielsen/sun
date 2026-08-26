(* aws-eio's signed_request converts every non-2xx status into
   Error (Http_error (status, body)) before returning; reclassify_transport_result
   restores it so a ResourceNotFoundException still classifies as
   Resource_not_found through the real call path. *)
let test_reclassify_then_interpret_get () =
  let body = {|{"__type":"com.amazonaws.dynamodb.v20120810#ResourceNotFoundException","message":"x"}|} in
  let transport_result : (int * (string * string) list * string, Aws_error.t) result =
    Error (Aws_error.Http_error (400, body))
  in
  match Result.bind (Dynamo_client.reclassify_transport_result transport_result) Dynamo_client.interpret_get with
  | Error Resource_not_found -> ()
  | Error e -> Alcotest.failf "expected Resource_not_found, got %s" (Dynamo_error.to_string e)
  | Ok _ -> Alcotest.fail "expected an error"

let test_reclassify_passes_through_genuine_transport_errors () =
  let transport_result : (int * (string * string) list * string, Aws_error.t) result =
    Error (Aws_error.Network_error "connection refused")
  in
  Alcotest.(check bool) "a genuine transport error (not an HTTP status) stays Dynamo_error.Aws" true
    (match Dynamo_client.reclassify_transport_result transport_result with Error (Aws _) -> true | _ -> false)

let test_reclassify_passes_through_success () =
  let transport_result : (int * (string * string) list * string, Aws_error.t) result = Ok (200, [], "{}") in
  Alcotest.(check bool) "a 2xx Ok passes through unchanged" true
    (Dynamo_client.reclassify_transport_result transport_result = Ok (200, [], "{}"))

let test_validate_config_rejects_crlf_in_region () =
  let config =
    { Dynamo_client.table = "t"; region = "us-east-1\r\nX-Injected: 1";
      credentials = Aws_credentials.of_env ~region:"us-east-1" () }
  in
  Alcotest.(check bool) "CRLF in region is rejected" true
    (match Dynamo_client.validate_config config with Error (Invalid_config _) -> true | _ -> false)

let test_validate_config_accepts_normal_config () =
  let config =
    { Dynamo_client.table = "t"; region = "us-east-1"; credentials = Aws_credentials.of_env ~region:"us-east-1" () }
  in
  Alcotest.(check bool) "ordinary config passes" true (Result.is_ok (Dynamo_client.validate_config config))

(* interpret_* mappers are pure, same rationale as s3-eio's — see
   dynamo-eio.md's design notes: no network/TLS needed to test how a
   (status, headers, body) triple maps to a result. *)

let test_interpret_put_success () =
  Alcotest.(check bool) "200 -> Ok ()" true (Result.is_ok (Dynamo_client.interpret_put (200, [], "")))

let test_interpret_put_error () =
  let body = {|{"__type":"com.amazonaws.dynamodb.v20120810#ResourceNotFoundException","message":"x"}|} in
  Alcotest.(check bool) "400 -> Error Resource_not_found" true
    (match Dynamo_client.interpret_put (400, [], body) with Error Resource_not_found -> true | _ -> false)

let test_interpret_get_item_present () =
  let body = {|{"Item":{"id":{"S":"abc"},"count":{"N":"5"}}}|} in
  match Dynamo_client.interpret_get (200, [], body) with
  | Error e -> Alcotest.fail (Dynamo_error.to_string e)
  | Ok None -> Alcotest.fail "expected Some item"
  | Ok (Some item) ->
    Alcotest.(check bool) "id" true (List.assoc_opt "id" item = Some (Dynamo_value.S "abc"));
    Alcotest.(check bool) "count" true (List.assoc_opt "count" item = Some (Dynamo_value.N "5"))

let test_interpret_get_item_missing () =
  (* GetItem returns HTTP 200 with no "Item" field when the key doesn't
     exist — not a 404, unlike S3's GetObject. *)
  match Dynamo_client.interpret_get (200, [], "{}") with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "expected None"
  | Error e -> Alcotest.fail (Dynamo_error.to_string e)

let test_interpret_get_malformed_json () =
  Alcotest.(check bool) "invalid JSON -> Malformed_response" true
    (match Dynamo_client.interpret_get (200, [], "not json") with
     | Error (Malformed_response _) -> true
     | _ -> false)

let test_interpret_delete_success () =
  Alcotest.(check bool) "200 -> Ok ()" true (Result.is_ok (Dynamo_client.interpret_delete (200, [], "")))

let test_interpret_query_items () =
  let body = {|{"Items":[{"id":{"S":"a"}},{"id":{"S":"b"}}],"Count":2}|} in
  match Dynamo_client.interpret_query (200, [], body) with
  | Error e -> Alcotest.fail (Dynamo_error.to_string e)
  | Ok items ->
    Alcotest.(check int) "two items" 2 (List.length items);
    Alcotest.(check bool) "first item" true (List.assoc_opt "id" (List.nth items 0) = Some (Dynamo_value.S "a"))

let test_interpret_query_empty () =
  match Dynamo_client.interpret_query (200, [], {|{"Items":[],"Count":0}|}) with
  | Ok [] -> ()
  | Ok _ -> Alcotest.fail "expected an empty list"
  | Error e -> Alcotest.fail (Dynamo_error.to_string e)

let test_item_to_json_and_back () =
  let item = [ ("id", Dynamo_value.S "abc"); ("count", Dynamo_value.N "5"); ("active", Dynamo_value.Bool true) ] in
  let json = Dynamo_client.item_to_json item in
  match Dynamo_client.item_of_json json with
  | Error msg -> Alcotest.fail msg
  | Ok item' -> Alcotest.(check bool) "round trips" true (item = item')

let test_build_request_body_is_valid_json () =
  let body = Dynamo_client.build_request_body [ ("TableName", `String "t") ] in
  match Yojson.Safe.from_string body with
  | `Assoc [ ("TableName", `String "t") ] -> ()
  | _ -> Alcotest.failf "unexpected body: %s" body

let () =
  Alcotest.run "dynamo_client"
    [ ( "reclassify_transport_result",
        [ Alcotest.test_case "reclassified 400 -> interpret_get -> Resource_not_found" `Quick
            test_reclassify_then_interpret_get;
          Alcotest.test_case "genuine transport error stays Aws" `Quick
            test_reclassify_passes_through_genuine_transport_errors;
          Alcotest.test_case "2xx Ok passes through unchanged" `Quick test_reclassify_passes_through_success;
        ] );
      ( "validate_config",
        [ Alcotest.test_case "rejects CRLF in region" `Quick test_validate_config_rejects_crlf_in_region;
          Alcotest.test_case "accepts an ordinary config" `Quick test_validate_config_accepts_normal_config;
        ] );
      ( "interpret",
        [ Alcotest.test_case "put: success" `Quick test_interpret_put_success;
          Alcotest.test_case "put: error" `Quick test_interpret_put_error;
          Alcotest.test_case "get: item present" `Quick test_interpret_get_item_present;
          Alcotest.test_case "get: item missing (200, no Item field)" `Quick test_interpret_get_item_missing;
          Alcotest.test_case "get: malformed JSON" `Quick test_interpret_get_malformed_json;
          Alcotest.test_case "delete: success" `Quick test_interpret_delete_success;
          Alcotest.test_case "query: items" `Quick test_interpret_query_items;
          Alcotest.test_case "query: empty" `Quick test_interpret_query_empty;
        ] );
      ( "item encoding",
        [ Alcotest.test_case "item_to_json / item_of_json round trip" `Quick test_item_to_json_and_back;
          Alcotest.test_case "build_request_body produces valid JSON" `Quick test_build_request_body_is_valid_json;
        ] );
    ]
