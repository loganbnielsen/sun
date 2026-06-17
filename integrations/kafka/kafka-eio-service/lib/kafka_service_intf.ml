module type MESSAGE = sig
  type t
  val topic_name : string
  val schema : string
  val encode : t -> Yojson.Safe.t
  val decode : Yojson.Safe.t -> (t, string) result
end

type 'a topic = {
  name      : string;
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
  security            : Kafka_security.t;
}

type t = {
  producer            : Kafka_producer.t;
  brokers             : string list;
  schema_registry_url : string;
  admin_url           : string;
  partitions          : int;
  security            : Kafka_security.t;
}

let ensure_topic rk ~topic_name ~partitions =
  let err = Kafka_raw.create_topic rk topic_name partitions 1 in
  if err <> 0 then
    Error (Printf.sprintf "could not provision topic %s: %s" topic_name (Kafka_raw.err2str err))
  else
    Ok ()

let query_topic_partitions net ~clock ~admin_url ~topic_name =
  match Kafka_service_http.http_get net ~clock ~base_url:admin_url
          ~path:(Printf.sprintf "/v1/topics/%s" topic_name) with
  | Error _ | Ok (404, _) -> None
  | Ok (200, body) ->
    (try
      match Yojson.Safe.from_string body with
      | `Assoc fields ->
        (match List.assoc_opt "partitions" fields with
         | Some (`List parts) -> Some (List.length parts)
         | _ -> None)
      | _ -> None
    with _ -> None)
  | Ok _ -> None

let wrap_on_decode_error ~ot ~topic_name user_on_decode_error =
  let decode_err_count = match ot with
    | None -> None
    | Some o ->
      Some (Obs.register_counter o
        ~name:"sun_worker_decode_errors_total"
        ~help:"Total Kafka messages dropped due to decode errors"
        ~label_names:[])
  in
  fun e ~raw_bytes ~ack ->
    (match decode_err_count with Some c -> c 1 | None -> ());
    (match ot with
     | None -> ()
     | Some o ->
       Obs.log_t o Obs.Error
         ~fields:[("error", e);
                  ("raw_bytes_len", string_of_int (Bytes.length raw_bytes));
                  ("topic", topic_name)]
         "sun-worker: decode error, skipping message");
    user_on_decode_error e ~raw_bytes ~ack
