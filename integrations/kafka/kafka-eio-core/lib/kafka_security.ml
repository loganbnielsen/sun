type protocol =
  | Plaintext
  | Ssl
  | Sasl_plaintext
  | Sasl_ssl

type t = {
  protocol        : protocol;
  ssl_ca_location : string option;
  sasl_mechanism  : string option;
  sasl_username   : string option;
  sasl_password   : string option;
}

let default = {
  protocol        = Plaintext;
  ssl_ca_location = None;
  sasl_mechanism  = None;
  sasl_username   = None;
  sasl_password   = None;
}

let protocol_to_string = function
  | Plaintext      -> "plaintext"
  | Ssl            -> "ssl"
  | Sasl_plaintext -> "sasl_plaintext"
  | Sasl_ssl       -> "sasl_ssl"

let env_opt name =
  match Sys.getenv_opt name with Some v when v <> "" -> Some v | _ -> None

let of_env () =
  let protocol =
    match Option.map String.lowercase_ascii (env_opt "KAFKA_SECURITY_PROTOCOL") with
    | Some "ssl"            -> Ssl
    | Some "sasl_plaintext" -> Sasl_plaintext
    | Some "sasl_ssl"       -> Sasl_ssl
    | _                     -> Plaintext
  in
  {
    protocol;
    ssl_ca_location = env_opt "KAFKA_SSL_CA_LOCATION";
    sasl_mechanism  = env_opt "KAFKA_SASL_MECHANISM";
    sasl_username   = env_opt "KAFKA_SASL_USERNAME";
    sasl_password   = env_opt "KAFKA_SASL_PASSWORD";
  }

let apply conf t =
  let errs = ref [] in
  let set k v = match Kafka_raw.conf_set conf k v with
    | Ok ()   -> ()
    | Error s -> errs := ("kafka security conf " ^ k ^ ": " ^ s) :: !errs
  in
  set "security.protocol" (protocol_to_string t.protocol);
  Option.iter (set "ssl.ca.location") t.ssl_ca_location;
  Option.iter (set "sasl.mechanism") t.sasl_mechanism;
  Option.iter (set "sasl.username") t.sasl_username;
  Option.iter (set "sasl.password") t.sasl_password;
  (match t.protocol with
   | Sasl_plaintext | Sasl_ssl ->
     if t.sasl_mechanism = None then
       errs := "kafka security: sasl_mechanism required for SASL protocols" :: !errs;
     if t.sasl_username = None then
       errs := "kafka security: sasl_username required for SASL protocols" :: !errs;
     if t.sasl_password = None then
       errs := "kafka security: sasl_password required for SASL protocols" :: !errs
   | Plaintext | Ssl -> ());
  match !errs with
  | []   -> Ok ()
  | errs -> Error (String.concat "; " (List.rev errs))

let make_base_conf ~brokers ~security =
  let conf = Kafka_raw.conf_new () in
  let first_err = ref None in
  let set k v =
    if !first_err = None then
      match Kafka_raw.conf_set conf k v with
      | Ok ()   -> ()
      | Error s -> first_err := Some ("kafka conf " ^ k ^ ": " ^ s)
  in
  set "bootstrap.servers" (String.concat "," brokers);
  (match apply conf security with
   | Error s -> if !first_err = None then first_err := Some s
   | Ok () -> ());
  (conf, set, first_err)
