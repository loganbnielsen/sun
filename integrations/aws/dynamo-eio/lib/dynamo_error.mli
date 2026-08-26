(** Error type for {!Dynamo_client}/{!Dynamo_table}, extending {!Aws_error.t}
    the same way [kafka-eio-service]'s [Kafka_error.t] extends the raw
    librdkafka codes. *)

type t =
  | Aws of Aws_error.t
      (** Transport, signature, or credential-resolution failure from
          [aws-eio] itself. *)
  | Resource_not_found  (** [ResourceNotFoundException] — table/index doesn't exist. *)
  | Conditional_check_failed  (** [ConditionalCheckFailedException]. *)
  | Service_error of { exn_type : string; message : string }
      (** Other DynamoDB exception with a parseable [__type]/[message] body. *)
  | Unparseable_error_response of { status : int; body : string }
      (** Non-2xx whose body didn't parse as DynamoDB's JSON error shape. *)
  | Malformed_response of string
      (** A 2xx response whose JSON didn't have the shape the calling
          operation expected (e.g. [GetItem] without an [Item] or
          [ConsumedCapacity]-only response) — distinct from a transport or
          service-reported error. *)
  | Wrong_entity of { expected : string; got : string option }
      (** {!Dynamo_table.Entity}'s discriminator check failed: the item's
          stamped entity name didn't match [expected] ([got = None] means the
          discriminator attribute was missing or not a string entirely). *)
  | Invalid_config of string
      (** [config.region] failed a fail-closed CR/LF check before being used
          to build the Host header/connection target — see
          {!Dynamo_client.validate_config}. *)

val of_response : status:int -> body:string -> t
(** Classify a non-2xx DynamoDB response: [ResourceNotFoundException]/
    [ConditionalCheckFailedException] in [__type] become their own cases;
    any other parseable [{"__type": ..., "message": ...}] body becomes
    [Service_error]; anything else becomes [Unparseable_error_response]. *)

val to_string : t -> string
