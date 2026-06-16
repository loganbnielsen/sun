module type FN = sig
  val schedule : string
  val run : unit -> (unit, string) result
end

(* ── Signal handling ────────────────────────────────────────────────────── *)

let install_signal_handler ~sw resolver =
  Sun_signal.install_promise_handler ~sw resolver

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
    let invocations, duration_h =
      Obs.register_counter_and_histogram ot
        ~counter_name:"sun_fn_invocations_total"
        ~counter_help:"Total function invocations by status"
        ~counter_labels:["status"]
        ~histogram_name:"sun_fn_duration_seconds"
        ~histogram_help:"Function run duration in seconds"
        ~histogram_labels:[]
    in
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
