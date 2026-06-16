(* Returns (conf, set, record_error, finalize) where:
   - [set k v] applies [k=v] to [conf], recording the first error silently.
   - [record_error msg] records [msg] as the first error if none has been set.
   - [finalize ()] returns Ok conf or Error <first_error_message>. *)
let make () =
  let conf = Kafka_raw.conf_new () in
  let first_err = ref None in
  let set k v =
    if !first_err = None then
      match Kafka_raw.conf_set conf k v with
      | Ok ()   -> ()
      | Error s -> first_err := Some ("kafka conf " ^ k ^ ": " ^ s)
  in
  let record_error msg =
    if !first_err = None then first_err := Some msg
  in
  let finalize () =
    match !first_err with
    | Some msg -> Error msg
    | None     -> Ok conf
  in
  (conf, set, record_error, finalize)
