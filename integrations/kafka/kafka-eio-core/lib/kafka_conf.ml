let build pairs =
  let conf = Kafka_raw.conf_new () in
  let first_err = ref None in
  let set k v =
    if !first_err = None then
      match Kafka_raw.conf_set conf k v with
      | Ok ()    -> ()
      | Error msg -> first_err := Some ("kafka conf " ^ k ^ ": " ^ msg)
  in
  List.iter (fun (k, v) -> set k v) pairs;
  match !first_err with
  | Some msg -> Error msg
  | None     -> Ok conf
