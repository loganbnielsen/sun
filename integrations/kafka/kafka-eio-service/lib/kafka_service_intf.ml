type topic_name = string

let validate_topic_name name =
  let len = String.length name in
  if len = 0 then
    Error "topic name must not be empty"
  else if len > 249 then
    Error "topic name must be at most 249 bytes"
  else if name = "." || name = ".." then
    Error "topic name must not be '.' or '..'"
  else
    let is_valid_char = function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
      | _ -> false
    in
    let rec loop i =
      if i = len then Ok ()
      else if is_valid_char name.[i] then loop (i + 1)
      else
        Error (Printf.sprintf
          "topic name contains invalid character %C at byte %d"
          name.[i] i)
    in
    loop 0

let topic_name name =
  match validate_topic_name name with
  | Ok () -> Ok name
  | Error e -> Error e

let topic_name_exn name =
  match topic_name name with
  | Ok topic -> topic
  | Error e -> invalid_arg ("invalid Kafka topic name " ^ Printf.sprintf "%S" name ^ ": " ^ e)

let topic_name_to_string topic = topic

module type MESSAGE = sig
  type t
  val topic_name : topic_name
  val schema : string
  val encode : t -> Yojson.Safe.t
  val decode : Yojson.Safe.t -> (t, string) result
end

type 'a topic = {
  name      : topic_name;
  schema_id : int;
  encode    : 'a -> Yojson.Safe.t;
  decode    : Yojson.Safe.t -> ('a, string) result;
}

type config = {
  brokers             : string list;
  schema_registry_url : string;
  admin_url           : string;
  linger_ms           : int;
  partitions          : int;
  security            : Kafka.Security.t;
}

type t = {
  producer            : Kafka.Producer.t;
  brokers             : string list;
  schema_registry_url : string;
  admin_url           : string;
  partitions          : int;
  security            : Kafka.Security.t;
}

type consume_partitioned_error =
  | Consumer_error of Kafka.Error.t
  | Partition_errors of (int32 * Kafka.Error.t) list

let ensure_topic producer ~topic_name ~partitions =
  match Kafka.Producer.create_topic producer ~topic_name ~partitions ~replication_factor:1 with
  | Ok ()   -> Ok ()
  | Error e -> Error e

type topic_partition_metadata =
  | Topic_not_found
  | Topic_partitions of int

type topic_partition_error =
  | Topic_admin_request_failed of string
  | Topic_admin_unexpected_status of int * string
  | Topic_admin_malformed_response of string

let topic_partition_error_to_string = function
  | Topic_admin_request_failed e ->
    "admin API request failed: " ^ e
  | Topic_admin_unexpected_status (status, body) ->
    Printf.sprintf "admin API HTTP %d: %s" status body
  | Topic_admin_malformed_response body ->
    "malformed admin API topic response: " ^ body

let decode_topic_partitions body =
  try
    match Yojson.Safe.from_string body with
    | `Assoc fields ->
      (match List.assoc_opt "partitions" fields with
       | Some (`List parts) -> Ok (Topic_partitions (List.length parts))
       | _ -> Error (Topic_admin_malformed_response body))
    | _ -> Error (Topic_admin_malformed_response body)
  with Yojson.Json_error _ ->
    Error (Topic_admin_malformed_response body)

let query_topic_partitions net ~clock ~admin_url ~topic_name =

  match Kafka_service_http.http_get net ~clock ~base_url:admin_url
          ~path:(Printf.sprintf "/v1/topics/%s" topic_name) with
  | Error e -> Error (Topic_admin_request_failed e)
  | Ok (404, _) -> Ok Topic_not_found
  | Ok (200, body) -> decode_topic_partitions body
  | Ok (status, body) -> Error (Topic_admin_unexpected_status (status, body))

let wrap_on_decode_error ~ot ~topic_name user_on_decode_error =

  let decode_err_count = match ot with
    | None -> None
    | Some o ->
      Some (Obs_eio.register_counter o
        ~name:"sun_worker_decode_errors_total"
        ~help:"Total Kafka messages dropped due to decode errors"
        ~label_names:[])
  in
  fun e ~raw_bytes ~ack ->
    (match decode_err_count with Some c -> c 1 | None -> ());
    (match ot with
     | None -> ()
     | Some o ->
       Obs_eio.log_standalone o Obs_eio.Error
         ~fields:[("error", e);
                  ("raw_bytes_len", string_of_int (Option.fold ~none:0 ~some:Bytes.length raw_bytes));
                  ("topic", topic_name)]
         "sun-worker: decode error, skipping message");
    user_on_decode_error e ~raw_bytes ~ack
