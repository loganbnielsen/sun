let setup_pipe () =
  let r, w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock w;
  let handle _ =
    (try ignore (Unix.single_write w (Bytes.make 1 '\x00') 0 1) with _ -> ())
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle handle);
  Sys.set_signal Sys.sigint  (Sys.Signal_handle handle);
  (r, w)

let await_signal r w =
  Fun.protect
    ~finally:(fun () -> Unix.close r; (try Unix.close w with _ -> ()))
    (fun () ->
      Eio_unix.await_readable r;
      let buf = Bytes.create 1 in
      (try ignore (Unix.read r buf 0 1) with _ -> ()))

(* Uses fork_daemon so the enclosing switch can close normally (e.g. after the
   server stops) without waiting for the signal fiber to drain. Fun.protect
   guarantees the pipe is closed whether the fiber exits or is cancelled. *)
let install_promise_handler ~sw resolver =
  let r, w = setup_pipe () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    await_signal r w;
    (try Eio.Promise.resolve resolver () with _ -> ());
    `Stop_daemon)

let install_atomic_handler ~sw stop_flag =
  let r, w = setup_pipe () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    await_signal r w;
    Atomic.set stop_flag true;
    `Stop_daemon)
