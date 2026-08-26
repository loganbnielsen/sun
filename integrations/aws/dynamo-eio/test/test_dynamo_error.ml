let resource_not_found_body =
  {|{"__type":"com.amazonaws.dynamodb.v20120810#ResourceNotFoundException","message":"Requested resource not found"}|}

let conditional_check_failed_body =
  {|{"__type":"com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException","message":"The conditional request failed"}|}

let generic_error_body =
  {|{"__type":"com.amazonaws.dynamodb.v20120810#ValidationException","message":"Some validation message"}|}

let test_resource_not_found () =
  Alcotest.(check bool) "classifies as Resource_not_found" true
    (match Dynamo_error.of_response ~status:400 ~body:resource_not_found_body with
     | Resource_not_found -> true
     | _ -> false)

let test_conditional_check_failed () =
  Alcotest.(check bool) "classifies as Conditional_check_failed" true
    (match Dynamo_error.of_response ~status:400 ~body:conditional_check_failed_body with
     | Conditional_check_failed -> true
     | _ -> false)

let test_generic_service_error () =
  match Dynamo_error.of_response ~status:400 ~body:generic_error_body with
  | Service_error { exn_type; message } ->
    Alcotest.(check string) "exn_type" "ValidationException" exn_type;
    Alcotest.(check string) "message" "Some validation message" message
  | _ -> Alcotest.fail "expected Service_error"

let test_unparseable_body () =
  Alcotest.(check bool) "non-JSON body -> Unparseable_error_response" true
    (match Dynamo_error.of_response ~status:500 ~body:"not json" with
     | Unparseable_error_response { status = 500; _ } -> true
     | _ -> false)

let test_json_without_type_field () =
  Alcotest.(check bool) "JSON without __type -> Unparseable_error_response" true
    (match Dynamo_error.of_response ~status:500 ~body:{|{"message":"oops"}|} with
     | Unparseable_error_response _ -> true
     | _ -> false)

(* of_response is documented as a pure, always-Result classifier, so a
   non-2xx body that's valid JSON but not an object (e.g. a bare array or
   string) must not raise. *)
let test_valid_json_non_object_does_not_raise () =
  Alcotest.(check bool) "a bare JSON array body -> Unparseable_error_response, not an exception" true
    (match Dynamo_error.of_response ~status:503 ~body:{|["Service","Unavailable"]|} with
     | Unparseable_error_response { status = 503; _ } -> true
     | _ -> false)

let test_valid_json_bare_string_does_not_raise () =
  Alcotest.(check bool) "a bare JSON string body -> Unparseable_error_response, not an exception" true
    (match Dynamo_error.of_response ~status:503 ~body:{|"Service Unavailable"|} with
     | Unparseable_error_response { status = 503; _ } -> true
     | _ -> false)

let () =
  Alcotest.run "dynamo_error"
    [ ( "of_response",
        [ Alcotest.test_case "ResourceNotFoundException -> Resource_not_found" `Quick test_resource_not_found;
          Alcotest.test_case "ConditionalCheckFailedException -> Conditional_check_failed" `Quick
            test_conditional_check_failed;
          Alcotest.test_case "other exception -> Service_error" `Quick test_generic_service_error;
          Alcotest.test_case "non-JSON body -> Unparseable_error_response" `Quick test_unparseable_body;
          Alcotest.test_case "JSON without __type -> Unparseable_error_response" `Quick
            test_json_without_type_field;
          Alcotest.test_case "valid JSON array body does not raise" `Quick
            test_valid_json_non_object_does_not_raise;
          Alcotest.test_case "valid JSON bare-string body does not raise" `Quick
            test_valid_json_bare_string_does_not_raise;
        ] );
    ]
