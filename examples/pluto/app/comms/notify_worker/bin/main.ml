let env_nonempty name =
  match Sys.getenv_opt name with
  | Some value when value <> "" -> Some value
  | _ -> None

let optional_log_backend ~net ~clock = function
  | None     -> Obs_eio.stdout
  | Some url ->
    Obs_loki.create ~net ~clock ~url
      ~label_names:[Obs_loki.stream_label "team"] ()

let optional_db_pool ~sw ~stdenv postgres_url =
  Option.bind postgres_url (fun url ->
    Db.create_pool ~url ~sw ~stdenv () |> Result.to_option)

let require_ok label = function
  | Ok value -> value
  | Error e  -> failwith (label ^ ": " ^ e)

let () =
  let postgres_url = env_nonempty "POSTGRES_URL" in
  let loki_url     = env_nonempty "LOKI_URL" in
  let kafka_config = Kafka_service.config_of_env () |> require_ok "kafka config" in
  Eio_main.run @@ fun env ->
  let log_backend = optional_log_backend ~net:env#net ~clock:env#clock loki_url in
  let prom, _render = Obs_prometheus.create () in
  let ot =
    Obs_eio.with_context
      (Obs_eio.create ~service:"pluto-notify-worker" ~mono_clock:env#mono_clock
         ~backend:(Obs_eio.compose log_backend prom) ())
      [("team", "comms")]
  in
  Eio.Switch.run @@ fun sw ->
  let pool = optional_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) postgres_url in
  let module W = Notify_worker.Make(struct
    let pool = pool
    let ot   = ot
  end) in
  let module WR = Worker.Make(W) in
  WR.run ~env ~config:kafka_config ~ot ()
  |> Result.map_error Worker.run_error_to_string
  |> function Ok () -> () | Error msg -> failwith msg
