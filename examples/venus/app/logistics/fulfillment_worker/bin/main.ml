let () = Eio_main.run @@ fun env ->
  let config =
    match Kafka_service.config_of_env () with
    | Ok config -> config
    | Error e   -> failwith ("kafka config: " ^ Kafka_service.error_to_string e)
  in
  let backend, render = Obs_prometheus.create () in
  let ot = Obs_eio.create ~service:"venus-logistics-fulfillment-worker"
             ~mono_clock:env#mono_clock ~backend () in
  let module W = Worker.Make(Fulfillment_worker) in
  W.run ~env ~config ~ot ~metrics_renderer:render ()
  |> Result.map_error Worker.run_error_to_string
  |> function Ok () -> () | Error msg -> failwith msg
