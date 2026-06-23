module type WORKER = sig
  module Message : Kafka_service.MESSAGE

  val group_id : string
  (** Consumer group ID. Use a stable, service-scoped name, e.g. ["payments-broadcast-worker"]. *)

  val handle : Message.t -> ack:(unit -> unit) -> trace_ctx:Obs_trace.t option -> (unit, string) result
  (** Called once per successfully decoded message. Call [ack ()] after processing
      completes to commit the offset. [trace_ctx] carries the upstream [traceparent]
      header — pass it as [?parent:trace_ctx] to [Obs.with_span] to link spans.

      Return [Error msg] to signal a retryable failure. The worker retries the same
      message using the [retry] policy passed to [Make(W).run]. Once [max_attempts]
      is exhausted (if non-negative), the worker stops and raises [Failure msg]. *)
end

type retry_policy = Kafka_consumer.retry_policy = {
  base_delay_s : float;
  (** Initial backoff in seconds. Doubles on each consecutive failure. *)
  max_delay_s  : float;
  (** Backoff is capped at this value. Default: [600.0] (10 minutes). *)
  max_attempts : int;
  (** Maximum number of attempts before the worker stops. Negative = retry
      indefinitely. Default: [-1]. *)
}

(** How the worker should handle transient failures from [W.handle].

    - [In_memory retry] (default) — exponential back-off sleep in the
      partition fiber.  Backoff survives in-process but is lost on rebalance.

    - [Retry_topics { max_attempts }] — the raw message bytes are published
      to [<topic>-retry] and the original offset is committed immediately.
      A background retry consumer (group [<group_id>-sun-retry]) delays until
      the scheduled [X-Sun-Retry-At] timestamp, then re-runs [W.handle].
      After [max_attempts] total failures the message is moved to [<topic>-dlq].
      Both topics are auto-provisioned on startup. *)
type retry_strategy = Kafka_service.retry_strategy =
  | In_memory    of retry_policy
  | Retry_topics of { max_attempts : int }

module Make (W : WORKER) : sig
  val run
    :  env:< net       : _ Eio.Net.t
           ; clock     : _ Eio.Time.clock
           ; mono_clock: _ Eio.Time.Mono.t
           ; .. >
    -> config:Kafka_service.config
    -> ?ot:Obs.t
    (** Observability handle. When provided, [sun_worker_messages_total{status}]
        (labels: [ok], [retry], [error]) and
        [sun_worker_message_duration_seconds] are emitted per message. *)
    -> ?on_ready:(unit -> unit)
    (** Called exactly once when the broker assigns partitions to this consumer. *)
    -> ?stop:bool Atomic.t
    (** External stop flag. Set to [true] for graceful shutdown. *)
    -> ?max_messages:int
    (** Stop cleanly after this many successfully processed messages. *)
    -> ?retry_strategy:retry_strategy
    (** Failure strategy for [Error] results from [W.handle]. Defaults to
        [In_memory default_retry]. See [retry_strategy] for the two modes. *)
    -> ?_consume_loop:
         (handler:(W.Message.t -> ack:(unit -> unit) -> trace_ctx:Obs_trace.t option -> Kafka_consumer.handler_result)
          -> unit -> unit)
    (** Test injection: replace the real per-partition consume loop with a stub.
        The stub receives the handler directly; retry logic is not applied. *)
    -> unit
    -> unit
end
