(** Prometheus backend for obs-eio.
    Accumulates counter/gauge/histogram deltas in-process and renders them as
    Prometheus text exposition format on demand.

    Typical use — long-running worker or service:
    {[
      let (prom_backend, render) = Obs_prometheus.create () in
      let ot = Obs.create ~service:"payments-worker"
                 ~mono_clock:env#mono_clock ~backend:prom_backend in

      let msgs = Obs.register_counter ot
        ~name:"kafka_messages_processed_total"
        ~help:"Total Kafka messages processed"
        ~label_names:["topic"; "status"] in

      (* In handler: *)
      msgs ~labels:[("topic", "payments"); ("status", "ok")] 1;

      (* Expose /metrics — wire render() into your HTTP handler: *)
      let body = render () in
      ignore body
    ]} *)

val create : unit -> Obs.backend * (unit -> string)
(** [create ()] returns a backend and a renderer.
    Pass the backend to [Obs.create ~backend].
    Call the renderer to produce a Prometheus /metrics text body on demand.
    The backend is safe to call from multiple fibers and domains simultaneously. *)

val push
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string
     (** Pushgateway base URL, e.g. ["http://localhost:9091"] *)
  -> job:string
     (** Pushgateway job label, e.g. ["payments-worker"] *)
  -> (unit -> string)
     (** The renderer returned by [create] *)
  -> (unit, string) result
(** Push the current metric snapshot to a Prometheus Pushgateway.
    Returns [Ok ()] immediately if the renderer produces no output (no metrics emitted yet).
    For long-running services use the renderer + scrape endpoint instead. *)
