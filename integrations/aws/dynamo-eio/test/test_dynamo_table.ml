(* The negative-compilation check itself — "passing one index's key to
   another index's functions is a type error, not a runtime bug" — lives in
   negative_index_mismatch.ml.txt (named .txt so dune never compiles it;
   see that file's own header for why this isn't wired into an automated
   dune rule, and how to re-verify it by hand). What's tested here is
   everything else: that the positive path (matching index/key pairs)
   actually works, and Entity's discriminator check. *)

module User_primary = struct
  type pk = [ `Org of string ]
  type sk = [ `User of string ]

  let index_name = None
  let format_pk (`Org id) = "ORG#" ^ id
  let format_sk (`User id) = "USER#" ^ id
  let pk_attribute = "PK"
  let sk_attribute = "SK"
end

module User_by_email = struct
  type pk = [ `Email of string ]
  type sk = [ `Metadata ]

  let index_name = Some "gsi1"
  let format_pk (`Email e) = "EMAIL#" ^ e
  let format_sk `Metadata = "METADATA"
  let pk_attribute = "GSI1PK"
  let sk_attribute = "GSI1SK"
end

module Primary = Dynamo_table.Index (User_primary)
module By_email = Dynamo_table.Index (User_by_email)

(* Primary and By_email are genuinely different module instances even though
   they're structurally similar — this is really just confirming the functor
   applies and the resulting modules have the expected shape; the interesting
   type-level guarantee (a mismatched pk type is a compile error) can't be
   expressed as a runtime test at all, hence the separate negative-compile
   check. *)
let test_functor_instances_are_distinct () =
  Alcotest.(check string) "User_primary formats its own pk shape" "ORG#acme" (User_primary.format_pk (`Org "acme"));
  Alcotest.(check string) "User_by_email formats its own pk shape" "EMAIL#a@example.com"
    (User_by_email.format_pk (`Email "a@example.com"));
  (* Referencing both Index applications at all proves they typecheck
     side by side with genuinely different pk/sk types — if the design's
     "one nominal type per index" claim were wrong (e.g. if pk/sk collapsed
     to a shared type), this file would already fail to compile the way the
     negative-compile check deliberately does. *)
  ignore (Primary.get, Primary.query, By_email.get, By_email.query)

(* DynamoDB doesn't enforce pk+sk uniqueness on a secondary index the way
   it does on a table's own primary key, so Index.get must not silently
   take the first result and drop the rest. *)
let test_get_results_empty () =
  Alcotest.(check bool) "no items -> Ok None" true (Primary.interpret_get_results [] = Ok None)

let test_get_results_single_item () =
  let item = [ ("PK", Dynamo_value.S "ORG#a"); ("SK", Dynamo_value.S "USER#b") ] in
  Alcotest.(check bool) "one item -> Ok (Some item)" true (Primary.interpret_get_results [ item ] = Ok (Some item))

let test_get_results_multiple_items_on_primary_fails_loud () =
  let item1 = [ ("PK", Dynamo_value.S "ORG#a") ] and item2 = [ ("PK", Dynamo_value.S "ORG#b") ] in
  Alcotest.(check bool) "more than one item -> Error, not silently the first" true
    (match Primary.interpret_get_results [ item1; item2 ] with Error (Malformed_response _) -> true | _ -> false)

let test_get_results_multiple_items_on_secondary_index_fails_loud () =
  let item1 = [ ("GSI1PK", Dynamo_value.S "EMAIL#a") ] and item2 = [ ("GSI1PK", Dynamo_value.S "EMAIL#b") ] in
  Alcotest.(check bool) "a non-unique secondary index match also fails loud, not silently the first" true
    (match By_email.interpret_get_results [ item1; item2 ] with Error (Malformed_response _) -> true | _ -> false)

module User_entity = Dynamo_table.Entity (struct
  let name = "user"
end)

module Order_entity = Dynamo_table.Entity (struct
  let name = "order"
end)

let test_entity_stamp_and_check_round_trip () =
  let item = [ ("id", Dynamo_value.S "usr_1") ] in
  let stamped = User_entity.stamp item in
  match User_entity.check stamped with
  | Error e -> Alcotest.fail (Dynamo_error.to_string e)
  | Ok item' -> Alcotest.(check bool) "stamped item still has the original field" true (item' = stamped)

let test_entity_check_rejects_wrong_entity () =
  let stamped_as_order = Order_entity.stamp [ ("id", Dynamo_value.S "ord_1") ] in
  Alcotest.(check bool) "checking a User_entity against an Order-stamped item fails" true
    (match User_entity.check stamped_as_order with
     | Error (Wrong_entity { expected = "user"; got = Some "order" }) -> true
     | _ -> false)

let test_entity_check_rejects_missing_discriminator () =
  Alcotest.(check bool) "an item with no discriminator attribute at all fails" true
    (match User_entity.check [ ("id", Dynamo_value.S "usr_1") ] with
     | Error (Wrong_entity { expected = "user"; got = None }) -> true
     | _ -> false)

let () =
  Alcotest.run "dynamo_table"
    [ ( "Index",
        [ Alcotest.test_case "functor instances are distinct, each formats its own key shape" `Quick
            test_functor_instances_are_distinct;
          Alcotest.test_case "get_results: empty -> None" `Quick test_get_results_empty;
          Alcotest.test_case "get_results: single item -> Some item" `Quick test_get_results_single_item;
          Alcotest.test_case "get_results: multiple items on primary index fails loud" `Quick
            test_get_results_multiple_items_on_primary_fails_loud;
          Alcotest.test_case "get_results: multiple items on a secondary index also fails loud" `Quick
            test_get_results_multiple_items_on_secondary_index_fails_loud;
        ] );
      ( "Entity",
        [ Alcotest.test_case "stamp then check round trips" `Quick test_entity_stamp_and_check_round_trip;
          Alcotest.test_case "check rejects a different entity's stamped item" `Quick
            test_entity_check_rejects_wrong_entity;
          Alcotest.test_case "check rejects a missing discriminator" `Quick
            test_entity_check_rejects_missing_discriminator;
        ] );
    ]
