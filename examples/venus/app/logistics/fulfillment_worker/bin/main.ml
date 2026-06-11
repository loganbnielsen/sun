let () = Eio_main.run @@ fun env ->
  let config = Kafka_service.config_of_env () in
  let module W = Worker.Make(Fulfillment_worker) in
  W.run ~env ~config ()
