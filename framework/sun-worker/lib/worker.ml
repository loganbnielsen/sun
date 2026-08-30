module type WORKER = sig
  module Message : Kafka_service.MESSAGE
  val group_id : string
  val handle : Message.t -> trace_ctx:Obs_trace.t option -> (unit, string) result
end

type retry_policy = Kafka.Consumer.retry_policy = {
  base_delay_s : float;
  max_delay_s  : float;
  max_attempts : int;
}

type retry_strategy = Kafka_service.retry_strategy =
  | In_memory    of retry_policy
  | Retry_topics of { max_attempts : int }

type run_error =
  [ `Create   of string
  | `Register of string
  | `Consume  of Kafka_service.consume_partitioned_error
  ]

let consume_error_to_string = function
  | Kafka_service.Consumer_error ke ->
    Kafka.Error.to_string ke
  | Kafka_service.Partition_errors errs ->
    errs
    |> List.map (fun (p, e) -> Printf.sprintf "partition %ld: %s" p (Kafka.Error.to_string e))
    |> String.concat "; "

let run_error_to_string = function
  | `Create msg   -> "sun-worker: create failed: " ^ msg
  | `Register msg -> "sun-worker: register failed: " ^ msg
  | `Consume e ->
    match e with
    | Kafka_service.Consumer_error _ ->
      "sun-worker: consume error: " ^ consume_error_to_string e
    | Kafka_service.Partition_errors errs ->
      "sun-worker: consume error (" ^ string_of_int (List.length errs) ^
      " partition(s)): " ^ consume_error_to_string e

(* ── Signal handling ────────────────────────────────────────────────────── *)

(* Self-pipe: signal handler writes one byte; an Eio fiber reads it and sets
   the stop flag, which the consumer checks at each message boundary so the
   in-flight message finishes before shutdown. *)
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
      ?(retry_strategy = Kafka_service.default_retry_strategy) ?test_consume_loop () =
    let msg_count, msg_duration =
      match ot with
      | None -> (None, None)
      | Some o ->
        let c, h =
          Obs_eio.register_counter_and_histogram o
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
    let result = Eio.Switch.run (fun sw ->
        install_signal_handler ~sw stop_flag;
        let handler msg ~ack ~trace_ctx =
          let limit_reached = match remaining with
            | Some r -> !r <= 0
            | None   -> false
          in
          if Atomic.get stop_flag || limit_reached then
            Kafka.Consumer.Stop
          else begin
            let t0 = Eio.Time.now env#clock in
            match W.handle msg ~trace_ctx with
            | Error _ ->
              (match msg_count with
               | Some c -> c ~labels:[("status","error")] 1
               | None   -> ());
              (* Signal consume_partitioned to retry with backoff.
                 For the test_consume_loop test path this propagates as a Failure. *)
              Kafka.Consumer.Error Kafka.Error.Application
            | Ok () ->
              let dt = Eio.Time.now env#clock -. t0 in
              (match msg_duration with Some h -> h dt | None -> ());
              let advance () =
                match remaining with
                | None -> Kafka.Consumer.Continue
                | Some r ->
                  decr r;
                  if !r <= 0 then Kafka.Consumer.Stop else Kafka.Consumer.Continue
              in
              (* Ack only after the handler succeeds, so a side effect is never
                 acked before it happens. An ack failure is a commit failure,
                 not a processing failure — retrying would risk a duplicate —
                 so it's only escalated to Kafka.Consumer.Error when fatal. *)
              match ack () with
              | Ok () ->
                (match msg_count with
                 | Some c -> c ~labels:[("status","ok")] 1
                 | None   -> ());
                advance ()
              | Error e ->
                (match msg_count with
                 | Some c -> c ~labels:[("status","ack_failed")] 1
                 | None   -> ());
                (match ot with
                 | None -> ()
                 | Some o ->
                   Obs_eio.log_standalone o (if Kafka.Error.is_fatal e then Obs_eio.Error else Obs_eio.Warn)
                     ~fields:[("error", Kafka.Error.to_string e)]
                     (if Kafka.Error.is_fatal e
                      then "sun-worker: fatal ack failure, stopping consumer"
                      else "sun-worker: ack failed, offset not committed; \
                            message eligible for redelivery"));
                if Kafka.Error.is_fatal e
                then Kafka.Consumer.Error e
                else advance ()
          end
        in
        let ( let* ) = Result.bind in
        (match test_consume_loop with
         | Some f ->
           (* test injection: test_consume_loop drives handler directly, no retry *)
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
    ) in
    (match result with
     | Error (`Consume (Kafka_service.Partition_errors errs)) ->
       (match ot with
        | None -> ()
        | Some o ->
          List.iter (fun (partition, e) ->
            Obs_eio.log_standalone o Obs_eio.Error
              ~fields:[("partition", Int32.to_string partition); ("error", Kafka.Error.to_string e)]
              "sun-worker: partition exhausted its retry budget"
          ) errs)
     | _ -> ());
    result

end
