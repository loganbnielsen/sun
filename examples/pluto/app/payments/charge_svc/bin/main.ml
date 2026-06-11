let () =
  let postgres_url = Sys.getenv_opt "POSTGRES_URL" in
  let loki_url     = Sys.getenv_opt "LOKI_URL" in
  Eio_main.run @@ fun env ->
  let log_backend = match loki_url with
    | None     -> Obs.stdout
    | Some url ->
      Obs_loki.create ~net:env#net ~clock:env#clock ~url
        ~label_names:["service"; "team"] ()
  in
  let prom, render = Obs_prometheus.create () in
  let ot =
    Obs.with_context
      (Obs.create ~service:"pluto-charge-svc" ~mono_clock:env#mono_clock
         ~backend:(Obs.compose log_backend prom))
      [("team", "payments")]
  in
  Eio.Switch.run @@ fun sw ->
  let pool = match postgres_url with
    | None     -> None
    | Some url ->
      (match Db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
       | Error _ -> None
       | Ok p    -> Some p)
  in
  Service.run (Handler.routes pool) ~env ~ot ~metrics_renderer:render ()
