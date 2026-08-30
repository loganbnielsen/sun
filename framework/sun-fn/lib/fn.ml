type trigger = Cron of string | Lambda

module type FN = sig
  val trigger : trigger
  val run : unit -> (unit, string) result
end

(* ── Signal handling ────────────────────────────────────────────────────── *)

(* Self-pipe trick: signal handler writes one byte to a non-blocking pipe;
   an Eio fiber awaits the read end and resolves the stop promise. *)
let install_signal_handler ~sw resolver =
  let r, w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock w;
  let handle _ =
    (try ignore (Unix.single_write w (Bytes.make 1 '\x00') 0 1) with _ -> ())
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle handle);
  Sys.set_signal Sys.sigint  (Sys.Signal_handle handle);
  (* Daemon fiber: the switch cancels it once the body returns normally. *)
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

  let default_job = function
    | Cron sched -> sched
    | Lambda -> "lambda"

  let run ~(env : < net       : _ Eio.Net.t
                  ; clock     : _ Eio.Time.clock
                  ; mono_clock: _ Eio.Time.Mono.t
                  ; .. >)
      ?pushgateway_url ?job ?backend () =
    let job = Option.value job ~default:(default_job F.trigger) in
    let backend, renderer =
      match backend with
      | Some pair -> pair
      | None      -> Obs_prometheus.create ()
    in
    let ot = Obs_eio.create ~service:job ~mono_clock:env#mono_clock ~backend () in
    let invocations, duration_h =
      Obs_eio.register_counter_and_histogram ot
        ~counter_name:"sun_fn_invocations_total"
        ~counter_help:"Total function invocations by status"
        ~counter_labels:["status"]
        ~histogram_name:"sun_fn_duration_seconds"
        ~histogram_help:"Function run duration in seconds"
        ~histogram_labels:[]
    in
    (* Push errors are always swallowed — push never blocks exit (Cron) or
       the next loop iteration (Lambda). *)
    let push_metrics url =
      match
        (try Obs_prometheus.push ~net:env#net ~clock:env#clock ~url ~job renderer with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn -> Error (Printexc.to_string exn))
      with
      | Ok ()     -> ()
      | Error msg -> Printf.eprintf "sun-fn: push failed (swallowed): %s\n%!" msg
    in
    let record_and_push ~t0 outcome =
      let dt = Eio.Time.now env#clock -. t0 in
      duration_h dt;
      (match outcome with
       | `Completed (Ok ())   -> invocations ~labels:[("status","ok")]        1
       | `Completed (Error _) -> invocations ~labels:[("status","error")]     1
       | `Signalled           -> invocations ~labels:[("status","cancelled")] 1);
      Option.iter push_metrics pushgateway_url
    in
    match F.trigger with
    | Cron _ ->
      let stop, stop_r = Eio.Promise.create () in
      let t0 = Eio.Time.now env#clock in
      let outcome =
        Eio.Switch.run (fun sw ->
          install_signal_handler ~sw stop_r;
          Eio.Fiber.first
            (fun () -> `Completed (F.run ()))
            (fun () -> Eio.Promise.await stop; `Signalled))
      in
      record_and_push ~t0 outcome;
      (match outcome with
       | `Completed (Ok ())     -> ()
       | `Completed (Error msg) -> raise (Failure msg)
       | `Signalled             -> exit 130)
    | Lambda -> (
      match Lambda_runtime.runtime_api_base () with
      | Error msg -> raise (Failure ("sun-fn: " ^ msg))
      | Ok base ->
        let stop, stop_r = Eio.Promise.create () in
        Eio.Switch.run (fun sw ->
          install_signal_handler ~sw stop_r;
          let runtime = Lambda_runtime.create ~net:env#net ~sw ~base in
          Eio.Fiber.first
            (fun () ->
              Lambda_runtime.run_loop runtime ~clock:env#clock
                ~on_error:(fun msg ->
                  Obs_eio.log_standalone ot Obs_eio.Error ~fields:[("error", msg)]
                    "sun-fn: lambda-eio runtime loop error")
                ~handler:(fun (_ : Lambda_runtime.invocation) ->
                  let t0 = Eio.Time.now env#clock in
                  let result =
                    try F.run () with
                    | Eio.Cancel.Cancelled _ as exn -> raise exn
                    | exn -> Error (Printexc.to_string exn)
                  in
                  record_and_push ~t0 (`Completed result);
                  match result with
                  | Ok ()     -> Ok {|{"status":"ok"}|}
                  | Error msg -> Error msg) ())
            (fun () -> Eio.Promise.await stop))
        (* Fiber.first discards the losing fiber's Cancelled internally, so when
           stop resolves first this Switch.run completes normally — it ends the
           loop, not the process. *))

end
