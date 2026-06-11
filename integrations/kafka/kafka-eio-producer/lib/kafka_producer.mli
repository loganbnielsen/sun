(** Eio-native Kafka producer built on kafka-eio-core. *)

type delivery_mode =
  | At_least_once
  | At_most_once
  | Exactly_once of { transaction_id : string }

type config = {
  brokers       : string list;
  delivery_mode : delivery_mode;
  linger_ms     : int option;          (** batch window; None = librdkafka default (5 ms) *)
  security      : Kafka_security.t;    (** transport security; use [Kafka_security.default] for plaintext dev *)
}

type t

(** [create cfg ~sw] creates a producer and starts delivery and poll fibers
    in [sw]. When [sw] is cancelled the fibers stop and the producer is closed. *)
val create : config -> sw:Eio.Switch.t -> (t, Kafka_error.t) result

val close : t -> unit

(** Expose the underlying librdkafka handle for admin operations
    (e.g. [Kafka_raw.create_topic]). Internal use only. *)
val raw_handle : t -> Kafka_raw.kafka_handle

(** Enqueue a message and return immediately. No delivery confirmation.
    The trailing [unit] is required by OCaml's optional-argument erasure rules. *)
val produce
  :  t
  -> topic:string
  -> value:bytes
  -> ?key:bytes
  -> ?headers:(string * string) list
  -> unit
  -> (unit, Kafka_error.t) result

(** Enqueue a message and return a promise that resolves when the broker
    acknowledges delivery (or reports an error).
    The trailing [unit] is required by OCaml's optional-argument erasure rules. *)
val produce_await
  :  t
  -> topic:string
  -> value:bytes
  -> ?key:bytes
  -> ?headers:(string * string) list
  -> unit
  -> (unit, Kafka_error.t) result Eio.Promise.t

(** Block until all enqueued messages have been delivered. *)
val flush : t -> timeout_ms:int -> (unit, Kafka_error.t) result

(** Run [f] inside a Kafka transaction. Commits on [Ok], aborts on [Error]
    or exception. Requires [delivery_mode = Exactly_once]. *)
val with_transaction
  :  t
  -> ?consumer:Kafka_consumer_handle.t
  -> (unit -> (unit, Kafka_error.t) result)
  -> (unit, Kafka_error.t) result
