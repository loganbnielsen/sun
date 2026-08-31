let env_nonempty name =
  match Sys.getenv_opt name with
  | Some value when value <> "" -> Some value
  | _ -> None

let optional_log_backend ~net ~clock = function
  | None     -> Obs_eio.stdout
  | Some url ->
    Obs_loki.create ~net ~clock ~url
      ~label_names:[Obs_loki.stream_label_exn "team"] ()

let require_db_pool ~sw ~stdenv postgres_url =
  let url =
    match postgres_url with
    | Some url -> url
    | None -> failwith "db pool: POSTGRES_URL is required"
  in
  match Pg_db.create_pool ~url ~sw ~stdenv () with
  | Ok pool -> pool
  | Error e -> failwith ("db pool: " ^ Pg_error.to_string e)

let () =
  let postgres_url = env_nonempty "POSTGRES_URL" in
  let loki_url     = env_nonempty "LOKI_URL" in
  Eio_main.run @@ fun env ->
  let log_backend = optional_log_backend ~net:env#net ~clock:env#clock loki_url in
  let prom, render = Obs_prometheus.create () in
  let ot =
    Obs_eio.with_context
      (Obs_eio.create ~service:"pluto-charge-svc" ~mono_clock:env#mono_clock
         ~backend:(Obs_eio.compose log_backend prom) ())
      [("team", "payments")]
  in
  Eio.Switch.run @@ fun sw ->
  let pool = require_db_pool ~sw ~stdenv:(env :> Caqti_eio.stdenv) postgres_url in
  Service.run (Handler.routes pool) ~env ~ot ~metrics_renderer:render ()
  |> Result.map_error Service.run_error_to_string
  |> function Ok () -> () | Error e -> failwith e
