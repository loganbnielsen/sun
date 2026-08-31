let env_nonempty name =
  match Sys.getenv_opt name with
  | Some value when value <> "" -> Some value
  | _ -> None

let optional_log_backend ~net ~clock = function
  | None     -> Obs_eio.stdout
  | Some url ->
    Obs_loki.create ~net ~clock ~url
      ~label_names:[Obs_loki.stream_label_exn "team"] ()

let require_storage label = function
  | Ok value -> value
  | Error e  -> failwith (label ^ ": " ^ Pg_error.to_string e)

let require_kafka label = function
  | Ok value -> value
  | Error e  -> failwith (label ^ ": " ^ Kafka_service.error_to_string e)

let create_db_pool ~sw ~stdenv url =
  Pg_db.create_pool ~url ~sw ~stdenv () |> require_storage "db pool"

let apply_optional_migrations ~fs pool = function
  | None     -> ()
  | Some dir ->
    Migration.apply pool ~dir ~table:"venus_schema_migrations" ~fs
    |> require_storage "migrations"

let optional_db_pool ~sw ~stdenv ~fs postgres_url migrations_dir =
  Option.map
    (fun url ->
       let pool = create_db_pool ~sw ~stdenv url in
       apply_optional_migrations ~fs pool migrations_dir;
       pool)
    postgres_url

let () =
  let loki_url        = env_nonempty "LOKI_URL" in
  let postgres_url    = env_nonempty "POSTGRES_URL" in
  let migrations_dir  = env_nonempty "MIGRATIONS_DIR" in
  let kafka_config    = Kafka_service.config_of_env () |> require_kafka "kafka config" in

  Eio_main.run @@ fun env ->

  let prom_backend, _render = Obs_prometheus.create () in
  let log_backend = optional_log_backend ~net:env#net ~clock:env#clock loki_url in
  let backend = Obs_eio.compose log_backend prom_backend in
  let ot =
    Obs_eio.with_context
      (Obs_eio.create ~service:"notify-worker" ~mono_clock:env#mono_clock ~backend ())
      [("team", "comms")]
  in

  Eio.Switch.run @@ fun sw ->

  let db_pool =
    optional_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) ~fs:env#fs
      postgres_url migrations_dir
  in

  let module W = Notify_worker.Make(struct
    let pool = db_pool
    let ot   = ot
  end) in
  let module WR = Worker.Make(W) in
  WR.run ~env ~config:kafka_config ~ot ()
  |> Result.map_error Worker.run_error_to_string
  |> function Ok () -> () | Error msg -> failwith msg
