let () =
  let postgres_url = Sys.getenv_opt "POSTGRES_URL" in
  let loki_url     = Sys.getenv_opt "LOKI_URL" in
  let kafka_config = Kafka_service.config_of_env () in
  Eio_main.run @@ fun env ->
  let log_backend = match loki_url with
    | None     -> Obs.stdout
    | Some url ->
      Obs_loki.create ~net:env#net ~clock:env#clock ~url
        ~label_names:["service"; "team"] ()
  in
  let prom, _render = Obs_prometheus.create () in
  let ot =
    Obs.with_context
      (Obs.create ~service:"pluto-notify-worker" ~mono_clock:env#mono_clock
         ~backend:(Obs.compose log_backend prom))
      [("team", "comms")]
  in
  Eio.Switch.run @@ fun sw ->
  let pool = match postgres_url with
    | None     -> None
    | Some url ->
      (match Db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
       | Error _ -> None
       | Ok p    -> Some p)
  in
  let module W = Notify_worker.Make(struct
    let pool = pool
    let ot   = ot
  end) in
  let module WR = Worker.Make(W) in
  WR.run ~env ~config:kafka_config ~ot ()
