type s3_record = {
  bucket : string;
  key : string;
  event_name : string;
}

type sqs_record = {
  message_id : string;
  body : string;
}

type dynamodb_stream_record = {
  event_name : string;
  keys : Yojson.Safe.t;
  new_image : Yojson.Safe.t option;
  old_image : Yojson.Safe.t option;
}

let ( let* ) = Result.bind

(* Plain pattern matching throughout, not Yojson.Safe.Util — member/
   to_string_option etc. raise Type_error on unexpected shapes. Every
   accessor here returns a Result instead. *)

let string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String s) -> Ok s
  | Some _ -> Error (Printf.sprintf "field %S is not a JSON string" key)
  | None -> Error (Printf.sprintf "missing field %S" key)

let records_of_json ~parse_record json =
  match json with
  | `Assoc fields -> (
    match List.assoc_opt "Records" fields with
    | Some (`List records) ->
      List.fold_left
        (fun acc r ->
          let* acc = acc in
          let* v = parse_record r in
          Ok (v :: acc))
        (Ok []) records
      |> Result.map List.rev
    | Some _ -> Error {|"Records" is not a JSON array|}
    | None -> Error {|missing "Records" field|})
  | _ -> Error {|expected a JSON object with a "Records" field|}

let s3_record_of_json = function
  | `Assoc fields -> (
    let* event_name = string_field "eventName" fields in
    match List.assoc_opt "s3" fields with
    | Some (`Assoc s3_fields) -> (
      match (List.assoc_opt "bucket" s3_fields, List.assoc_opt "object" s3_fields) with
      | Some (`Assoc bucket_fields), Some (`Assoc object_fields) ->
        let* bucket = string_field "name" bucket_fields in
        let* key = string_field "key" object_fields in
        Ok { bucket; key; event_name }
      | _ -> Error "S3 record missing s3.bucket.name or s3.object.key")
    | _ -> Error {|S3 record missing "s3" field|})
  | _ -> Error "expected a JSON object for an S3 record"

let s3_records_of_json json = records_of_json ~parse_record:s3_record_of_json json

let sqs_record_of_json = function
  | `Assoc fields ->
    let* message_id = string_field "messageId" fields in
    let* body = string_field "body" fields in
    Ok { message_id; body }
  | _ -> Error "expected a JSON object for an SQS record"

let sqs_records_of_json json = records_of_json ~parse_record:sqs_record_of_json json

let dynamodb_stream_record_of_json = function
  | `Assoc fields -> (
    let* event_name = string_field "eventName" fields in
    match List.assoc_opt "dynamodb" fields with
    | Some (`Assoc dynamo_fields) -> (
      match List.assoc_opt "Keys" dynamo_fields with
      | None -> Error "DynamoDB Streams record missing dynamodb.Keys"
      | Some keys ->
        let new_image = List.assoc_opt "NewImage" dynamo_fields in
        let old_image = List.assoc_opt "OldImage" dynamo_fields in
        Ok { event_name; keys; new_image; old_image })
    | _ -> Error {|DynamoDB Streams record missing "dynamodb" field|})
  | _ -> Error "expected a JSON object for a DynamoDB Streams record"

let dynamodb_stream_records_of_json json = records_of_json ~parse_record:dynamodb_stream_record_of_json json
