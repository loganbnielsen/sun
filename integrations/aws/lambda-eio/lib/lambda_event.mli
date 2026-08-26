(** Parsing helpers for common Lambda event-trigger envelope shapes. Each
    [*_of_json] is lenient — extra fields are ignored, matching every other
    [*_of_json] in this codebase's AWS integrations (e.g. {!Dynamo_value}).
    Add a new shape when a real caller needs one; this is not meant to be
    an exhaustive catalog of every AWS event source. *)

type s3_record = {
  bucket : string;
  key : string;
  event_name : string;  (** e.g. ["ObjectCreated:Put"] *)
}

val s3_records_of_json : Yojson.Safe.t -> (s3_record list, string) result

type sqs_record = {
  message_id : string;
  body : string;
}

val sqs_records_of_json : Yojson.Safe.t -> (sqs_record list, string) result

type dynamodb_stream_record = {
  event_name : string;  (** ["INSERT"], ["MODIFY"], or ["REMOVE"] *)
  keys : Yojson.Safe.t;  (** DynamoDB attribute-value JSON — decode with {!Dynamo_value.of_json} if needed *)
  new_image : Yojson.Safe.t option;
  old_image : Yojson.Safe.t option;
}

val dynamodb_stream_records_of_json : Yojson.Safe.t -> (dynamodb_stream_record list, string) result
