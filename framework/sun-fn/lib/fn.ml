module type FN = sig
  val schedule : string
  val run : unit -> (unit, string) result
end

(* ── Signal handling ────────────────────────────────────────────────────── *)

(* Self-pipe trick: POSIX signal handler writes one byte to a non-blocking
   pipe; an Eio fiber awaits the read end and resolves the stop promise.
   This is async-signal-safe — no OCaml allocation in the signal handler. *)
let install_signal_handler ~sw resolver =
  let r, w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock w;
  let handle _ =
    (try ignore (Unix.single_write w (Bytes.make 1 '\x00') 0 1) with _ -> ())
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle handle);
  Sys.set_signal Sys.sigint  (Sys.Signal_handle handle);
  (* Daemon: switch cancels this fiber when the body returns normally (no signal
     received). If a signal fires first, the fiber completes before the switch
     exits, so the daemon distinction doesn't matter in that case. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Unix.close r; (try Unix.close w with _ -> ()))
      (fun () ->
        Eio_unix.await_readable r;
        let buf = Bytes.create 1 in
        (try ignore (Unix.read r buf 0 1) with _ -> ());
        (try Eio.Promise.resolve resolver () with _ -> ());
        `Stop_daemon))

(* ── Make functor ───────────────────────────────────────────────────────── *)

module Make (F : FN) = struct

  let run ~(env : < net       : _ Eio.Net.t
                  ; clock     : _ Eio.Time.clock
                  ; mono_clock: _ Eio.Time.Mono.t
                  ; .. >)
      ?pushgateway_url ?(job = F.schedule) ?backend () =
    let backend, renderer =
      match backend with
      | Some pair -> pair
      | None      -> Obs_prometheus.create ()
    in
    let ot = Obs.create ~service:job ~mono_clock:env#mono_clock ~backend in
    let invocations = Obs.register_counter ot
      ~name:"sun_fn_invocations_total"
      ~help:"Total function invocations by status"
      ~label_names:["status"] in
    let duration_h = Obs.register_histogram ot
      ~name:"sun_fn_duration_seconds"
      ~help:"Function run duration in seconds"
      ~label_names:[] in
    let t0 = Eio.Time.now env#clock in
    let stop, stop_r = Eio.Promise.create () in
    (* Fiber.first arms return a typed outcome only — no telemetry inside *)
    let outcome =
      Eio.Switch.run (fun sw ->
        install_signal_handler ~sw stop_r;
        Eio.Fiber.first
          (fun () -> `Completed (F.run ()))
          (fun () -> Eio.Promise.await stop; `Signalled))
    in
    let dt = Eio.Time.now env#clock -. t0 in
    duration_h dt;
    (match outcome with
     | `Completed (Ok ())   -> invocations ~labels:[("status","ok")]        1
     | `Completed (Error _) -> invocations ~labels:[("status","error")]     1
     | `Signalled           -> invocations ~labels:[("status","cancelled")] 1);
    (* Push errors are always swallowed — push never blocks exit *)
    (match pushgateway_url with
     | None -> ()
     | Some url ->
       (try
          (match Obs_prometheus.push ~net:env#net ~clock:env#clock ~url ~job renderer with
           | Ok ()    -> ()
           | Error msg -> Printf.eprintf "sun-fn: push failed: %s\n%!" msg)
        with exn ->
          Printf.eprintf "sun-fn: push exception: %s\n%!" (Printexc.to_string exn)));
    match outcome with
    | `Completed (Ok ())     -> ()
    | `Completed (Error msg) -> raise (Failure msg)
    | `Signalled             -> exit 130

end
