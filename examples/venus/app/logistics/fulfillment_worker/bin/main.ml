let () = Eio_main.run @@ fun env ->
  let config =
    match Kafka_service.config_of_env () with
    | Ok config -> config
    | Error e   -> failwith ("kafka config: " ^ e)
  in
  let module W = Worker.Make(Fulfillment_worker) in
  W.run ~env ~config ()
