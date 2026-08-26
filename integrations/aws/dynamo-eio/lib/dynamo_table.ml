module type INDEX = sig
  type pk
  type sk

  val index_name : string option
  val format_pk : pk -> string
  val format_sk : sk -> string
  val pk_attribute : string
  val sk_attribute : string
end

module Index (I : INDEX) = struct
  (* DynamoDB only guarantees pk+sk uniqueness on a table's own primary key
     (I.index_name = None), not on secondary indexes — a fully-specified
     pk+sk can legitimately match more than one item there. Fail loud rather
     than silently return the first match; callers needing every match on a
     non-unique index should use query, not get. *)
  let interpret_get_results = function
    | [] -> Ok None
    | [ item ] -> Ok (Some item)
    | _ :: _ :: _ as items ->
      Error
        (Dynamo_error.Malformed_response
           (Printf.sprintf
              "Index.get expects at most one item for a fully-specified pk+sk, got %d — %s"
              (List.length items)
              (match I.index_name with
               | None -> "this is the primary index, which should be impossible; investigate the table schema"
               | Some name ->
                 Printf.sprintf
                   "%s is a secondary index, which DynamoDB does not enforce key uniqueness on; use query instead \
                    of get if more than one item can share this key"
                   name)))

  let get ~net ~clock config ~pk ~sk =
    match
      Dynamo_client.query ~net ~clock config ?index_name:I.index_name
        ~expression_attribute_names:[ ("#pk", I.pk_attribute); ("#sk", I.sk_attribute) ]
        ~key_condition_expression:"#pk = :pk AND #sk = :sk"
        ~expression_attribute_values:
          [ (":pk", Dynamo_value.S (I.format_pk pk)); (":sk", Dynamo_value.S (I.format_sk sk)) ]
        ()
    with
    | Error _ as e -> e
    | Ok items -> interpret_get_results items

  let query ~net ~clock config ~pk () =
    Dynamo_client.query ~net ~clock config ?index_name:I.index_name
      ~expression_attribute_names:[ ("#pk", I.pk_attribute) ]
      ~key_condition_expression:"#pk = :pk"
      ~expression_attribute_values:[ (":pk", Dynamo_value.S (I.format_pk pk)) ]
      ()
end

module type ENTITY = sig
  val name : string
end

module Entity (E : ENTITY) = struct
  let discriminator_attribute = "__dynamo_eio_entity__"

  let stamp item = (discriminator_attribute, Dynamo_value.S E.name) :: item

  let check item =
    match List.assoc_opt discriminator_attribute item with
    | Some (Dynamo_value.S got) when got = E.name -> Ok item
    | Some (Dynamo_value.S got) -> Error (Dynamo_error.Wrong_entity { expected = E.name; got = Some got })
    | Some _ | None -> Error (Dynamo_error.Wrong_entity { expected = E.name; got = None })
end
