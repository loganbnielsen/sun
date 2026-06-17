let () =
  let loki_url        = Sys.getenv_opt "LOKI_URL" in
  let postgres_url    = Sys.getenv_opt "POSTGRES_URL" in
  let kafka_config    = Kafka_service.config_of_env () in

  Eio_main.run @@ fun env ->

  let prom_backend, _render = Obs_prometheus.create () in
  let log_backend = match loki_url with
    | None     -> Obs.stdout
    | Some url ->
      Obs_loki.create ~net:env#net ~clock:env#clock ~url
        ~label_names:["service"; "team"] ()
  in
  let backend = Obs.compose log_backend prom_backend in
  let ot =
    Obs.with_context
      (Obs.create ~service:"notify-worker" ~mono_clock:env#mono_clock ~backend)
      [("team", "comms")]
  in

  Eio.Switch.run @@ fun sw ->

  let migrations_dir = Sys.getenv_opt "MIGRATIONS_DIR" in
  let db_pool = match postgres_url with
    | None     -> None
    | Some url ->
      (match Db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
       | Error e -> failwith ("db pool: " ^ Storage_error.to_string e)
       | Ok pool ->
         (match migrations_dir with
          | None     -> Some pool
          | Some dir ->
            (match Migration.apply pool ~dir ~table:"venus_schema_migrations" with
             | Error e -> failwith ("migrations: " ^ Storage_error.to_string e)
             | Ok ()   -> Some pool)))
  in

  let module W = Notify_worker.Make(struct
    let pool = db_pool
    let ot   = ot
  end) in
  let module WR = Worker.Make(W) in
  WR.run ~env ~config:kafka_config ~ot ()
