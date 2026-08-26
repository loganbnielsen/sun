(* Example payloads are AWS's own published examples (Lambda sample event
   shapes), not hand-invented shapes — same principle as aws-eio's
   Aws_credentials tests using AWS's real API reference response shape. *)

let s3_event_json =
  {|{
  "Records": [
    {
      "eventName": "ObjectCreated:Put",
      "s3": {
        "bucket": { "name": "example-bucket" },
        "object": { "key": "test/key.txt" }
      }
    }
  ]
}|}

let test_s3_records_of_json () =
  match Lambda_event.s3_records_of_json (Yojson.Safe.from_string s3_event_json) with
  | Error msg -> Alcotest.fail msg
  | Ok [ { bucket; key; event_name } ] ->
    Alcotest.(check string) "bucket" "example-bucket" bucket;
    Alcotest.(check string) "key" "test/key.txt" key;
    Alcotest.(check string) "event_name" "ObjectCreated:Put" event_name
  | Ok records -> Alcotest.failf "expected exactly one record, got %d" (List.length records)

let sqs_event_json =
  {|{
  "Records": [
    { "messageId": "19dd0b57-b21e-4ac1-bd88-01bbb068cb78", "body": "Hello from SQS!" }
  ]
}|}

let test_sqs_records_of_json () =
  match Lambda_event.sqs_records_of_json (Yojson.Safe.from_string sqs_event_json) with
  | Error msg -> Alcotest.fail msg
  | Ok [ { message_id; body } ] ->
    Alcotest.(check string) "message_id" "19dd0b57-b21e-4ac1-bd88-01bbb068cb78" message_id;
    Alcotest.(check string) "body" "Hello from SQS!" body
  | Ok records -> Alcotest.failf "expected exactly one record, got %d" (List.length records)

let dynamodb_stream_event_json =
  {|{
  "Records": [
    {
      "eventName": "INSERT",
      "dynamodb": {
        "Keys": { "Id": { "N": "101" } },
        "NewImage": { "Id": { "N": "101" }, "Message": { "S": "hi" } }
      }
    }
  ]
}|}

let test_dynamodb_stream_records_of_json () =
  match Lambda_event.dynamodb_stream_records_of_json (Yojson.Safe.from_string dynamodb_stream_event_json) with
  | Error msg -> Alcotest.fail msg
  | Ok [ { event_name; keys; new_image; old_image } ] ->
    Alcotest.(check string) "event_name" "INSERT" event_name;
    Alcotest.(check bool) "keys present" true (keys <> `Null);
    Alcotest.(check bool) "new_image present" true (Option.is_some new_image);
    Alcotest.(check bool) "old_image absent (an INSERT has no prior image)" true (Option.is_none old_image)
  | Ok records -> Alcotest.failf "expected exactly one record, got %d" (List.length records)

let test_missing_records_field () =
  Alcotest.(check bool) "an object with no Records field is rejected" true
    (match Lambda_event.s3_records_of_json (`Assoc [ ("foo", `String "bar") ]) with
     | Error _ -> true
     | Ok _ -> false)

let test_malformed_record_does_not_raise () =
  Alcotest.(check bool) "a Records array with a malformed entry is rejected, not an exception" true
    (match Lambda_event.s3_records_of_json (`Assoc [ ("Records", `List [ `String "not a record object" ]) ]) with
     | Error _ -> true
     | Ok _ -> false)

let () =
  Alcotest.run "lambda_event"
    [ ( "records_of_json",
        [ Alcotest.test_case "S3 event" `Quick test_s3_records_of_json;
          Alcotest.test_case "SQS event" `Quick test_sqs_records_of_json;
          Alcotest.test_case "DynamoDB Streams event" `Quick test_dynamodb_stream_records_of_json;
          Alcotest.test_case "missing Records field" `Quick test_missing_records_field;
          Alcotest.test_case "malformed record does not raise" `Quick test_malformed_record_does_not_raise;
        ] );
    ]
