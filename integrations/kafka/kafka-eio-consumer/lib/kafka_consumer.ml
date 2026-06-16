type handler_result =
  | Continue
  | Stop
  | Error of Kafka_error.t

type offset_reset =
  | Earliest
  | Latest

type rebalance_event =
  | Partitions_assigned of partition list
  | Partitions_revoked  of partition list

and partition = {
  topic     : string;
  partition : int32;
  offset    : int64;
}

type config = {
  brokers      : string list;
  group_id     : string;
  topics       : string list;
  offset_reset : offset_reset;
  auto_commit  : bool;
  on_rebalance : (rebalance_event -> unit) option;
  security     : Kafka_security.t;
}

type message = {
  topic     : string;
  partition : int32;
  offset    : int64;
  key       : bytes option;
  value     : bytes;
  timestamp : int64 option;
  headers   : (string * string) list;
}

type t = {
  handle      : Kafka_raw.kafka_handle;
  config      : config;
  stream      : message Eio.Stream.t;
  closed      : bool Atomic.t;
  poll_exited : unit Eio.Promise.t;
  poll_exit_r : unit Eio.Promise.u;
}

let err i = Result.error (Kafka_error.of_int i)


let tuple_to_message (topic, partition, offset, key, value, timestamp, headers) =
  { topic; partition; offset; key; value; timestamp; headers }

(* consumer_poll releases the OCaml runtime lock at the C level, so calling
   it directly from a fiber is safe — the domain is not held during the
   100ms block, and Cancelled is delivered cleanly when the call returns. *)
let poll_fiber t sw ~on_ready =
  Eio.Fiber.fork ~sw (fun () ->
    let notified = ref false in
    let rec loop () =
      if Atomic.get t.closed then ()
      else
        (match Kafka_raw.consumer_poll t.handle 100 with
         | None ->
           if not !notified && Kafka_raw.assignment_count t.handle > 0 then begin
             notified := true; on_ready ()
           end;
           Eio.Fiber.yield (); loop ()
         | Some tup ->
           if not !notified then begin notified := true; on_ready () end;
           Eio.Stream.add t.stream (tuple_to_message tup);
           loop ())
    in
    (try loop () with Eio.Cancel.Cancelled _ -> ());
    Eio.Promise.resolve t.poll_exit_r ())

let close t =
  if Atomic.compare_and_set t.closed false true then
    (* Eio.Cancel.protect ensures consumer_close + destroy always run, even when
       the enclosing fiber is cancelled mid-shutdown. Without this, the librdkafka
       background threads keep heartbeating to the broker, holding the consumer group
       open and blocking any subsequent rebalance indefinitely.

       We drain the stream before awaiting poll_exited to break a potential
       deadlock: if close is called while the poll fiber is blocked in
       Eio.Stream.add (stream full, nobody consuming), the poll fiber can never
       see t.closed = true and exit on its own. Draining creates space, unblocks
       the add, and lets the poll fiber reach its t.closed check. *)
    Eio.Cancel.protect (fun () ->
      let rec drain_until_exited () =
        while not (Eio.Stream.is_empty t.stream) do
          ignore (Eio.Stream.take_nonblocking t.stream)
        done;
        if Eio.Promise.peek t.poll_exited = None then begin
          Eio.Fiber.yield ();
          drain_until_exited ()
        end
      in
      drain_until_exited ();
      Kafka_raw.consumer_close t.handle;
      Kafka_raw.destroy t.handle)

let create ?(on_ready = ignore) (cfg : config) ~sw =
  let conf, set, record_error, finalize = Kafka_conf_builder.make () in
  set "bootstrap.servers" (String.concat "," cfg.brokers);
  set "group.id" cfg.group_id;
  set "auto.offset.reset"
    (match cfg.offset_reset with Earliest -> "earliest" | Latest -> "latest");
  set "enable.auto.commit" (if cfg.auto_commit then "true" else "false");
  (* librdkafka 2.x changed the default assignment strategy to cooperative-sticky,
     which requires a rebalance_cb to drive the multi-round protocol.  Without one
     the rebalance never completes and the consumer never gets assigned partitions.
     Pinning to eager rebalancing (range,roundrobin) preserves the callback-free
     subscribe() → poll() → assignment_count > 0 invariant our poll_fiber relies on. *)
  set "partition.assignment.strategy" "range,roundrobin";
  (match Kafka_security.apply conf cfg.security with
   | Error s -> record_error s
   | Ok () -> ());
  match finalize () with
  | Error msg ->
    Printf.eprintf "kafka_consumer: config error: %s\n%!" msg;
    Result.error Kafka_error.Application
  | Ok conf ->
  match Kafka_raw.kafka_new Kafka_raw.Consumer conf (-1) with
  | Error _s -> Result.error Kafka_error.Transport
  | Ok rk_handle ->
    (match Kafka_raw.subscribe rk_handle cfg.topics with
     | Error _s -> Result.error Kafka_error.Invalid_arg
     | Ok () ->
       let (poll_exited, poll_exit_r) = Eio.Promise.create () in
       let t = {
         handle      = rk_handle;
         config      = cfg;
         stream      = Eio.Stream.create 256;
         closed      = Atomic.make false;
         poll_exited;
         poll_exit_r;
       } in
       poll_fiber t sw ~on_ready;
       Eio.Switch.on_release sw (fun () -> close t);
       Result.ok t)

let handle t = Kafka_consumer_handle.of_raw t.handle

let stream t = t.stream

let consume t ~handler =
  let rec loop () =
    let msg = Eio.Stream.take t.stream in
    let acked = ref false in
    let ack () =
      acked := true;
      ignore (Kafka_raw.commit_message
                t.handle msg.topic msg.partition msg.offset false)
    in
    let result = handler msg ~ack in
    (match result with
     | (Continue | Stop) when not !acked ->
       Printf.eprintf
         "sun-worker: handler returned without calling ack() — offset not committed \
          (topic=%s partition=%ld offset=%Ld)\n%!"
         msg.topic msg.partition msg.offset
     | _ -> ());
    match result with
    | Continue -> loop ()
    | Stop     -> Result.ok ()
    | Error e  -> Result.error e
  in
  loop ()

let poll t =
  match Kafka_raw.consumer_poll t.handle 0 with
  | None     -> Result.ok None
  | Some tup -> Result.ok (Some (tuple_to_message tup))

let commit t msg =
  match Kafka_raw.commit_message t.handle msg.topic msg.partition msg.offset false with
  | Ok ()   -> Result.ok ()
  | Error i -> err i

let commit_all t =
  (* Passing topic="" and partition=(-1) is our signal to the C stub to commit
     all assigned partitions; see ocaml_rd_kafka_commit_message for handling. *)
  match Kafka_raw.commit_message t.handle "" Int32.minus_one (-1L) false with
  | Ok ()   -> Result.ok ()
  | Error i -> err i

(* ── Per-partition fiber consumer with retry + pause/resume ──────────────── *)

type retry_policy = {
  base_delay_s : float;
  max_delay_s  : float;
  max_attempts : int;
}

let default_retry = {
  base_delay_s = 1.0;
  max_delay_s  = 600.0;
  max_attempts = -1;
}

(* [consume_partitioned t ~sw ~clock ?retry ?on_retry ~handler] routes each
   message to a per-partition fiber so retry backoff on one partition never
   blocks another.  During retry sleep the partition is paused at the
   librdkafka level so no new messages accumulate in the partition stream.
   An inner Eio.Switch.run ensures all partition fibers exit before returning. *)
let consume_partitioned t ~sw:_ ~clock ?(retry = default_retry)
    ?(on_retry = fun ~partition:_ ~attempt:_ ~delay_s:_ -> ())
    ~handler () =
  let stop    = Atomic.make false in
  let stop_p, stop_r = Eio.Promise.create () in
  let first_err : Kafka_error.t option ref = ref None in
  let streams
    : (int32, (message * (unit -> unit)) option Eio.Stream.t) Hashtbl.t =
    Hashtbl.create 4
  in
  let signal_stop () =
    if Atomic.compare_and_set stop false true then
      Eio.Promise.resolve stop_r ()
  in
  Eio.Switch.run (fun sw ->
    let get_or_create_stream partition =
      match Hashtbl.find_opt streams partition with
      | Some s -> s
      | None ->
        let stream = Eio.Stream.create max_int in
        Hashtbl.add streams partition stream;
        Eio.Fiber.fork ~sw (fun () ->
          let rec loop () =
            match Eio.Stream.take stream with
            | None -> ()
            | Some (msg, ack) ->
              if Atomic.get stop then loop ()
              else begin
                let acked = ref false in
                let tracked_ack () = acked := true; ack () in
                let rec attempt n =
                  match handler msg ~ack:tracked_ack with
                  | Continue ->
                    if not !acked then
                      Printf.eprintf
                        "sun-worker: handler returned Continue without ack() \
                         (topic=%s partition=%ld offset=%Ld)\n%!"
                        msg.topic msg.partition msg.offset;
                    loop ()
                  | Stop ->
                    if not !acked then
                      Printf.eprintf
                        "sun-worker: handler returned Stop without ack() \
                         (topic=%s partition=%ld offset=%Ld)\n%!"
                        msg.topic msg.partition msg.offset;
                    signal_stop ()
                  | Error e ->
                    let exhausted =
                      retry.max_attempts >= 0 && n >= retry.max_attempts
                    in
                    if exhausted then begin
                      Printf.eprintf
                        "sun-worker: exhausted %d attempt(s) for \
                         topic=%s partition=%ld offset=%Ld\n%!"
                        (n + 1) msg.topic msg.partition msg.offset;
                      first_err := Some e;
                      signal_stop ()
                    end else begin
                      let delay =
                        Float.min
                          (retry.base_delay_s *. (2. ** Float.of_int n))
                          retry.max_delay_s
                      in
                      Printf.eprintf
                        "sun-worker: attempt %d failed, retrying in %.0fs \
                         (topic=%s partition=%ld offset=%Ld)\n%!"
                        (n + 1) delay msg.topic msg.partition msg.offset;
                      on_retry ~partition:msg.partition ~attempt:n ~delay_s:delay;
                      Kafka_raw.pause_partition t.handle msg.topic msg.partition;
                      let interrupted =
                        Eio.Fiber.first
                          (fun () -> Eio.Time.sleep clock delay; false)
                          (fun () -> Eio.Promise.await stop_p; true)
                      in
                      Kafka_raw.resume_partition t.handle msg.topic msg.partition;
                      if not interrupted then attempt (n + 1)
                      else ()  (* stop_p fired: exit this partition fiber *)
                    end
                in
                attempt 0
              end
          in
          loop ()
        );
        stream
    in
    let rec routing_loop () =
      if Atomic.get stop then ()
      else begin
        let msg_opt =
          match Eio.Stream.take_nonblocking t.stream with
          | Some _ as m -> m
          | None ->
            Eio.Fiber.first
              (fun () -> Some (Eio.Stream.take t.stream))
              (fun () -> Eio.Promise.await stop_p; None)
        in
        match msg_opt with
        | None -> ()
        | Some msg ->
          let ack () =
            ignore (Kafka_raw.commit_message
                      t.handle msg.topic msg.partition msg.offset false)
          in
          Eio.Stream.add (get_or_create_stream msg.partition) (Some (msg, ack));
          routing_loop ()
      end
    in
    routing_loop ();
    Hashtbl.iter (fun _ s -> Eio.Stream.add s None) streams
  );
  match !first_err with
  | Some e -> Result.error e
  | None   -> Result.ok ()
