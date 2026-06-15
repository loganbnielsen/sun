(** Eio-native Kafka consumer built on kafka-eio-core. *)

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
  brokers               : string list;
  group_id              : string;
  topics                : string list;
  offset_reset          : offset_reset;
  auto_commit           : bool;
  on_rebalance          : (rebalance_event -> unit) option;
  security              : Kafka_security.t;
  (** Transport security; use [Kafka_security.default] for plaintext dev. *)
  partition_queue_depth : int;
  (** Maximum messages buffered per partition in [consume_partitioned].
      When the queue is full the routing loop blocks, applying backpressure
      to the librdkafka fetch path.  Default: 64. *)
  obs                   : Obs.t option;
  (** Optional observability handle.  When present, a gauge
      [kafka_partition_queue_depth] is emitted on each enqueue.  Pass [None]
      to disable metrics without any runtime overhead. *)
}

type message = {
  topic     : string;
  partition : int32;
  offset    : int64;
  key       : bytes option;
  value     : bytes;
  timestamp : int64 option;
  headers   : (string * string) list;  (** Kafka message headers, e.g. [("traceparent", "00-...")] *)
}

type t

(** [create ?on_ready cfg ~sw] creates a consumer, subscribes to configured
    topics, and starts a poll fiber in [sw]. [on_ready] is called exactly once
    when the broker assigns partitions to this consumer — use it to signal
    readiness instead of sleeping for a fixed rebalance timeout. *)
val create : ?on_ready:(unit -> unit) -> config -> sw:Eio.Switch.t -> (t, Kafka_error.t) result

val close : t -> unit

(** Expose the underlying handle for use with transactional producers. *)
val handle : t -> Kafka_consumer_handle.t

(** Returns an Eio stream that yields messages as they arrive.
    Backpressure is applied via stream capacity. *)
val stream : t -> message Eio.Stream.t

(** Process messages in a loop. [ack ()] commits the offset for the current
    message. Returns [Ok ()] when [handler] returns [Stop], [Error e] when
    [handler] returns [Error e]. *)
val consume
  :  t
  -> handler:(message -> ack:(unit -> unit) -> handler_result)
  -> (unit, Kafka_error.t) result

(** Non-blocking check for one message. Returns [None] immediately if the
    queue is empty. Use [stream] for blocking, backpressure-aware delivery. *)
val poll : t -> (message option, Kafka_error.t) result

(** Commit offset for a specific message (synchronous). *)
val commit : t -> message -> (unit, Kafka_error.t) result

(** Commit all currently assigned partition offsets (synchronous). *)
val commit_all : t -> (unit, Kafka_error.t) result

(** Retry policy for [consume_partitioned]. *)
type retry_policy = {
  base_delay_s : float;
  (** Initial backoff in seconds; doubles on each consecutive failure. *)
  max_delay_s  : float;
  (** Backoff cap. Default: [600.0] (10 minutes). *)
  max_attempts : int;
  (** Maximum attempts. Negative = retry indefinitely. Default: [-1]. *)
}

val default_retry : retry_policy

(** [consume_partitioned t ~sw ~clock ?retry ?on_retry ~handler] is like
    [consume] but routes each message to a dedicated per-partition fiber.
    A partition's retry sleep blocks only that partition; other partitions
    continue unaffected.  During retry sleep the partition is paused at
    the librdkafka level so no messages accumulate in its stream buffer.

    [on_retry ~partition ~attempt ~delay_s] is called just before each
    retry sleep — use it to increment metrics counters.

    The function blocks until the consumer is stopped (handler returns [Stop]
    or retries are exhausted), then returns. All partition fibers are joined
    before returning, so the consumer handle is safe to close immediately after. *)
val consume_partitioned
  :  t
  -> sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> ?retry:retry_policy
  -> ?on_retry:(partition:int32 -> attempt:int -> delay_s:float -> unit)
  -> handler:(message -> ack:(unit -> unit) -> handler_result)
  -> unit
  -> (unit, Kafka_error.t) result
