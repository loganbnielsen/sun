type delivery_mode =
  | At_least_once
  | At_most_once
  | Exactly_once of { transaction_id : string }

type config = {
  brokers       : string list;
  delivery_mode : delivery_mode;
  linger_ms     : int option;
  security      : Kafka_security.t;
}

(* Unix.file_descr is an int under the hood on all Unix platforms. *)
external int_of_fd : Unix.file_descr -> int = "%identity"
external fd_of_int : int -> Unix.file_descr = "%identity"

type t = {
  handle       : Kafka_raw.kafka_handle;
  topic_cache  : (string, Kafka_raw.kafka_topic) Hashtbl.t;
  delivery_mode: delivery_mode;
  pipe_source  : Eio_unix.source_ty Eio.Std.r;
  pending      : (int64, (unit, Kafka_error.t) result Eio.Promise.u) Hashtbl.t;
  next_id      : int64 ref;
  mutex        : Mutex.t;
  closed       : bool Atomic.t;
  (* write end of the poll wake pipe; -1 if poll_fiber was not started.
     close t writes one byte here to unblock the daemon's single_read. *)
  wake_fd      : int Atomic.t;
  poll_exited  : unit Eio.Promise.t;
  poll_exit_r  : unit Eio.Promise.u;
}

let err i = Error (Kafka_error.of_int i)

let conf_of_config (cfg : config) : (Kafka_raw.kafka_conf, string) result =
  let (conf, set, first_err) =
    Kafka_security.make_base_conf ~brokers:cfg.brokers ~security:cfg.security in
  (match cfg.linger_ms with Some ms -> set "linger.ms" (string_of_int ms) | None -> ());
  (match cfg.delivery_mode with
   | At_most_once ->
     set "acks" "0"
   | At_least_once ->
     set "acks" "all";
     set "enable.idempotence" "true"
   | Exactly_once { transaction_id } ->
     set "acks" "all";
     set "enable.idempotence" "true";
     set "transactional.id" transaction_id);
  match !first_err with
  | Some msg -> Error msg
  | None     -> Ok conf

let get_or_create_topic t name =
  match Hashtbl.find_opt t.topic_cache name with
  | Some rkt -> rkt
  | None ->
    let rkt = Kafka_raw.topic_new t.handle name in
    Hashtbl.add t.topic_cache name rkt;
    rkt

(* Reads delivery receipts from the pipe one struct at a time.
   Eio.Flow.read_exact suspends via io_uring (IORING_OP_READV with a
   cancel hook) until the C delivery callback writes exactly one
   delivery_result_t to the pipe, then resumes the fiber instantly.
   No Unix.select, no arbitrary timeout, no drain loop — each iteration
   reads exactly sizeof(delivery_result_t) bytes and resolves the
   corresponding pending promise before looping back to wait again.
   buf is allocated once and reused; it is safe to mutate because
   parsing is strictly synchronous with no yields between read and use. *)
let delivery_fiber t sw =
  let sz  = Kafka_raw.delivery_sizeof () in
  let buf = Cstruct.create sz in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      if Atomic.get t.closed then `Stop_daemon
      else
        match Eio.Flow.read_exact t.pipe_source buf with
        | exception (Eio.Cancel.Cancelled _) -> `Stop_daemon
        | exception End_of_file -> `Stop_daemon
        | () ->
          let corr_id  = Cstruct.LE.get_uint64 buf 0 in
          let err_code = Int32.to_int (Cstruct.LE.get_uint32 buf 8) in
          let result   = if err_code = 0 then Ok () else err err_code in
          Mutex.lock t.mutex;
          (match Hashtbl.find_opt t.pending corr_id with
           | None -> ()
           | Some resolver ->
             Hashtbl.remove t.pending corr_id;
             Eio.Promise.resolve resolver result);
          Mutex.unlock t.mutex;
          loop ()
    in
    loop ())

(* Sleeps at 0% CPU on the wake_source read end.  librdkafka writes one byte
   to the matching write end whenever its main queue transitions from empty to
   non-empty (via enable_queue_events — edge-triggered).  On wake-up we drain
   all pending events with poll(rk,0) — which fires delivery callbacks that
   write receipts to the delivery pipe — then yield so the Eio scheduler can
   process io_uring completions from delivery_fiber and the HTTP calls.
   Two safety measures:
   - write end is set O_NONBLOCK so librdkafka's background thread never
     blocks if the pipe buffer fills up (writes fail silently; the drain loop
     handles all accumulated events regardless of how many wake bytes arrived).
   - a seed drain runs once before the loop to process events that landed in
     the queue between kafka_new and enable_queue_events, which would never
     trigger the edge notification. *)
let poll_fiber t sw =
  let (wake_source, wake_sink) = Eio_unix.pipe sw in
  let write_fd_int =
    Eio_unix.Fd.use_exn "kafka_queue_wake_fd"
      (Eio_unix.Resource.fd wake_sink) (fun fd ->
        Unix.set_nonblock fd;
        int_of_fd fd)
  in
  Atomic.set t.wake_fd write_fd_int;
  Kafka_raw.enable_queue_events t.handle write_fd_int;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let wake_buf = Cstruct.create 4096 in
    let rec drain_kafka () =
      let n = Kafka_raw.poll t.handle 0 in
      if n > 0 then drain_kafka ()
    in
    drain_kafka ();  (* seed: clear pre-registration events *)
    let rec loop () =
      if Atomic.get t.closed then ()
      else
        match Eio.Flow.single_read wake_source wake_buf with
        | exception (Eio.Cancel.Cancelled _) -> ()
        | exception End_of_file -> ()
        | _n ->
          drain_kafka ();
          Eio.Fiber.yield ();
          loop ()
    in
    (try loop () with Eio.Cancel.Cancelled _ -> ());
    Eio.Promise.resolve t.poll_exit_r ();
    `Stop_daemon)

let close t =
  if Atomic.compare_and_set t.closed false true then
    (* Eio.Cancel.protect ensures flush + destroy always run even when the
       enclosing fiber is cancelled mid-shutdown. Without this, librdkafka's
       background threads keep running (and sending to the wake/delivery pipe fds),
       which can corrupt unrelated Eio resources after fd recycling. *)
    Eio.Cancel.protect (fun () ->
      let wfd = Atomic.get t.wake_fd in
      if wfd >= 0 then begin
        Kafka_raw.disable_queue_events t.handle;
        let buf = Bytes.make 1 '\x01' in
        (try ignore (Unix.write (fd_of_int wfd) buf 0 1)
         with Unix.Unix_error (Unix.EPIPE, _, _) -> ()
            | Unix.Unix_error _ -> ());
        Eio.Promise.await t.poll_exited
      end;
      ignore (Kafka_raw.flush t.handle 5000);
      Kafka_raw.destroy t.handle)

let create (cfg : config) ~sw =
  let (pipe_source, write_sink) = Eio_unix.pipe sw in
  (* Extract the raw write-fd integer for the C delivery callback.
     write_sink is managed by sw; the fd stays open until sw ends,
     which is after close t runs (LIFO on_release ordering). *)
  let write_fd_int =
    Eio_unix.Fd.use_exn "kafka_write_fd"
      (Eio_unix.Resource.fd write_sink) int_of_fd
  in
  match conf_of_config cfg with
  | Error msg ->
    Printf.eprintf "kafka_producer: config error: %s\n%!" msg;
    Error Kafka_error.Application
  | Ok conf ->
  match Kafka_raw.kafka_new Kafka_raw.Producer conf write_fd_int with
  | Error _s -> Error Kafka_error.Transport
  | Ok handle ->
    let (poll_exited, poll_exit_r) = Eio.Promise.create () in
    let t = {
      handle;
      topic_cache  = Hashtbl.create 8;
      delivery_mode = cfg.delivery_mode;
      pipe_source;
      pending      = Hashtbl.create 64;
      next_id      = ref 1L;
      mutex        = Mutex.create ();
      closed       = Atomic.make false;
      wake_fd      = Atomic.make (-1);
      poll_exited;
      poll_exit_r;
    } in
    (match cfg.delivery_mode with
     | Exactly_once _ ->
       (match Kafka_raw.init_transactions handle 5000 with
        | Error i -> Error (Kafka_error.of_int i)
        | Ok () ->
          delivery_fiber t sw;
          Eio.Switch.on_release sw (fun () -> close t);
          Ok t)
     | _ ->
       delivery_fiber t sw;
       poll_fiber t sw;
       Eio.Switch.on_release sw (fun () -> close t);
       Ok t)

let produce t ~topic ~value ?(key = Bytes.empty) ?(headers = []) () =
  let key_opt = if Bytes.length key = 0 then None else Some key in
  let rc = match headers with
    | [] ->
      let rkt = get_or_create_topic t topic in
      Kafka_raw.produce rkt Int32.minus_one value key_opt 0L
    | _  ->
      Kafka_raw.produce_v t.handle topic Int32.minus_one value key_opt 0L headers
  in
  (match rc with Ok () -> Ok () | Error i -> err i)

let produce_await t ~topic ~value ?(key = Bytes.empty) ?(headers = []) () =
  let promise, resolver = Eio.Promise.create () in
  Mutex.lock t.mutex;
  let corr_id = !(t.next_id) in
  t.next_id := Int64.add corr_id 1L;
  Hashtbl.add t.pending corr_id resolver;
  Mutex.unlock t.mutex;
  let key_opt = if Bytes.length key = 0 then None else Some key in
  let rc = match headers with
    | [] ->
      let rkt = get_or_create_topic t topic in
      Kafka_raw.produce rkt Int32.minus_one value key_opt corr_id
    | _  ->
      Kafka_raw.produce_v t.handle topic Int32.minus_one value key_opt corr_id headers
  in
  (match rc with
   | Error i ->
     Mutex.lock t.mutex;
     Hashtbl.remove t.pending corr_id;
     Mutex.unlock t.mutex;
     Eio.Promise.resolve resolver (err i)
   | Ok () -> ());
  promise

let raw_handle t = t.handle

let flush t ~timeout_ms =
  match Kafka_raw.flush t.handle timeout_ms with
  | Ok ()   -> Ok ()
  | Error i -> err i

let with_transaction t ?consumer f =
  match t.delivery_mode with
  | Exactly_once _ ->
    (match Kafka_raw.begin_transaction t.handle with
     | Error i -> err i
     | Ok () ->
       (match f () with
        | Error _ as e ->
          ignore (Kafka_raw.abort_transaction t.handle 5000);
          e
        | Ok () ->
          (match consumer with
           | Some ch ->
             (match Kafka_raw.send_offsets_to_transaction
                      t.handle (Kafka_consumer_handle.to_raw ch) 5000 with
              | Error i -> Error (Kafka_error.of_int i)
              | Ok () ->
                Kafka_raw.commit_transaction t.handle 5000
                |> Result.map_error Kafka_error.of_int)
           | None ->
             Kafka_raw.commit_transaction t.handle 5000
             |> Result.map_error Kafka_error.of_int)))
  | _ -> Error Kafka_error.Not_implemented
