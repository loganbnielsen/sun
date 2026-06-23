module type WORKER = sig
  module Message : Kafka_service.MESSAGE
  val group_id : string
  val handle : Message.t -> ack:(unit -> unit) -> trace_ctx:Obs_trace.t option -> (unit, string) result
end

type retry_policy = Kafka_consumer.retry_policy = {
  base_delay_s : float;
  max_delay_s  : float;
  max_attempts : int;
}

type retry_strategy = Kafka_service.retry_strategy =
  | In_memory    of retry_policy
  | Retry_topics of { max_attempts : int }

(* ── Signal handling ────────────────────────────────────────────────────── *)

(* Self-pipe: signal handler writes one byte; an Eio fiber reads it and sets
   the atomic stop flag. The consumer checks the flag on each message boundary
   and returns Stop, allowing the current message to finish before shutting down. *)
let install_signal_handler ~sw stop_flag =
  let r, w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock w;
  let handle _ =
    (try ignore (Unix.single_write w (Bytes.make 1 '\x00') 0 1) with _ -> ())
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle handle);
  Sys.set_signal Sys.sigint  (Sys.Signal_handle handle);
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Unix.close r; (try Unix.close w with _ -> ()))
      (fun () ->
        Eio_unix.await_readable r;
        let buf = Bytes.create 1 in
        (try ignore (Unix.read r buf 0 1) with _ -> ());
        Atomic.set stop_flag true;
        `Stop_daemon))

(* ── Make functor ───────────────────────────────────────────────────────── *)

module Make (W : WORKER) = struct

  let run ~(env : < net       : _ Eio.Net.t
                  ; clock     : _ Eio.Time.clock
                  ; mono_clock: _ Eio.Time.Mono.t
                  ; .. >)
      ~config ?ot ?on_ready ?stop ?max_messages
      ?(retry_strategy = Kafka_service.default_retry_strategy) ?_consume_loop () =
    let msg_count, msg_duration =
      match ot with
      | None -> (None, None)
      | Some o ->
        let c, h =
          Obs.register_counter_and_histogram o
            ~counter_name:"sun_worker_messages_total"
            ~counter_help:"Total messages processed by status"
            ~counter_labels:["status"]
            ~histogram_name:"sun_worker_message_duration_seconds"
            ~histogram_help:"Message processing latency in seconds"
            ~histogram_labels:[]
        in
        (Some c, Some h)
    in
    let stop_flag = match stop with Some f -> f | None -> Atomic.make false in
    let remaining = match max_messages with Some n -> Some (ref n) | None -> None in
    let on_retry ~partition:_ ~attempt:_ ~delay_s:_ =
      match msg_count with
      | Some c -> c ~labels:[("status","retry")] 1
      | None   -> ()
    in
    let result =
      Eio.Switch.run (fun sw ->
        install_signal_handler ~sw stop_flag;
        let handler msg ~ack ~trace_ctx =
          let limit_reached = match remaining with
            | Some r -> !r <= 0
            | None   -> false
          in
          if Atomic.get stop_flag || limit_reached then
            Kafka_consumer.Stop
          else begin
            let t0 = Eio.Time.now env#clock in
            match W.handle msg ~ack ~trace_ctx with
            | Ok () ->
              let dt = Eio.Time.now env#clock -. t0 in
              (match msg_duration with Some h -> h dt | None -> ());
              (match msg_count with
               | Some c -> c ~labels:[("status","ok")] 1
               | None   -> ());
              (match remaining with
               | None -> Kafka_consumer.Continue
               | Some r ->
                 decr r;
                 if !r <= 0 then Kafka_consumer.Stop else Kafka_consumer.Continue)
            | Error _ ->
              (match msg_count with
               | Some c -> c ~labels:[("status","error")] 1
               | None   -> ());
              (* Signal consume_partitioned to retry with backoff.
                 For the _consume_loop test path this propagates as a Failure. *)
              Kafka_consumer.Error Kafka_error.Application
          end
        in
        let ( let* ) = Result.bind in
        (match _consume_loop with
         | Some f ->
           (* test injection: _consume_loop drives handler directly, no retry *)
           f ~handler (); Ok ()
         | None ->
           let* svc = Kafka_service.create config ~sw
             |> Result.map_error (fun msg -> `Create msg) in
           let* topic = Kafka_service.register svc
               ~net:env#net ~clock:env#clock (module W.Message)
             |> Result.map_error (fun msg -> `Register msg) in
           Kafka_service.consume_partitioned svc topic
               ~group_id:W.group_id ~sw ~clock:env#clock
               ?on_ready ~retry_strategy ~on_retry ?ot ~handler ()
             |> Result.map_error (fun ke -> `Consume ke))
      )
    in
    match result with
    | Ok ()                 -> ()
    | Error (`Create msg)   -> raise (Failure ("sun-worker: create failed: " ^ msg))
    | Error (`Register msg) -> raise (Failure ("sun-worker: register failed: " ^ msg))
    | Error (`Consume ke)   ->
      raise (Failure ("sun-worker: consume error: " ^ Kafka_error.to_string ke))

end
