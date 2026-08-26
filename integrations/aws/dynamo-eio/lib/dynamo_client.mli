(** Raw DynamoDB operations on top of [aws-eio]. See [dynamo-eio.md] for wire
    protocol details and what v1 deliberately leaves out (pagination, update
    expressions, conditional writes, batch/transactions). *)

type config = {
  table : string;
  region : string;
  credentials : Aws_credentials.t;
}

type item = (string * Dynamo_value.t) list

val put_item : net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> item:item -> (unit, Dynamo_error.t) result

val get_item : net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:item -> (item option, Dynamo_error.t) result
(** [None] when the key doesn't exist — GetItem returns HTTP 200 with no
    ["Item"] field in that case, not a 404 (unlike {!S3_client.get_object}'s
    404-on-missing-key; DynamoDB's protocol just works differently). *)

val delete_item : net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:item -> (unit, Dynamo_error.t) result
(** Succeeds whether or not the key existed — DynamoDB's DeleteItem does not
    report "not found" as an error. *)

val query :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config ->
  ?index_name:string ->
  ?expression_attribute_names:(string * string) list
      (** ["#name" -> "real_attribute_name"] aliases for
          [key_condition_expression] — DynamoDB reserves ~600 words
          (["Name"], ["Status"], ["Data"], ... — the full list is in AWS's
          own docs) that cannot appear literally in an expression; aliasing
          every attribute name through a placeholder avoids the caller
          needing to know that reserved-word list. *)
  -> key_condition_expression:string ->
  expression_attribute_values:item ->
  unit ->
  (item list, Dynamo_error.t) result
(** Single page only — does not read [LastEvaluatedKey]. A query whose real
    result set exceeds DynamoDB's 1MB-per-page limit silently returns only
    the first page; see [dynamo-eio.md]'s "Out of Scope". *)

(** {2 Exposed for testing} *)

val build_request_body : (string * Yojson.Safe.t) list -> string
(** The exact JSON body an operation signs and sends, given its
    action-specific fields (["TableName"], ["Item"]/["Key"]/etc. — this
    package's operations add those; this just serializes the final
    [`Assoc]). *)

val item_to_json : item -> Yojson.Safe.t
val item_of_json : Yojson.Safe.t -> (item, string) result

val validate_config : config -> (unit, Dynamo_error.t) result
(** The CR/LF fail-closed check every operation runs before building a
    request — [config.region] becomes an unencoded Host header/connection
    target with no percent-encoding pass. *)

val reclassify_transport_result :
  (int * (string * string) list * string, Aws_error.t) result ->
  (int * (string * string) list * string, Dynamo_error.t) result
(** [Aws_http.signed_request] already converts every non-2xx status into
    [Error (Http_error (status, body))] — this re-threads that back into the
    [Ok] shape [interpret_*] expects, so their non-2xx classification
    branches are actually reachable. *)

val interpret_put : int * (string * string) list * string -> (unit, Dynamo_error.t) result
val interpret_get : int * (string * string) list * string -> (item option, Dynamo_error.t) result
val interpret_delete : int * (string * string) list * string -> (unit, Dynamo_error.t) result
val interpret_query : int * (string * string) list * string -> (item list, Dynamo_error.t) result
