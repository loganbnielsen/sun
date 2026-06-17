(** Unsafe FFI bindings to librdkafka. Internal to kafka-eio-core.
    Users interact with Kafka_producer and Kafka_consumer, not this module. *)

type kafka_handle
type kafka_conf
type kafka_topic
type kafka_type = Producer | Consumer

val conf_new : unit -> kafka_conf
val conf_set : kafka_conf -> string -> string -> (unit, string) result

(** [kafka_new typ conf write_fd] creates a kafka handle. For Producer handles,
    [write_fd] is the write end of a pipe used for delivery notifications.
    Pass [(-1)] for Consumer handles (delivery callback not installed). *)
val kafka_new : kafka_type -> kafka_conf -> int -> (kafka_handle, string) result

val topic_new : kafka_handle -> string -> kafka_topic

(** [produce topic partition value key_opt correlation_id]
    Enqueues a message. [correlation_id = 0L] means fire-and-forget.
    Non-zero correlation ids are written back to the delivery pipe on ack. *)
val produce
  :  kafka_topic
  -> int32
  -> bytes
  -> bytes option
  -> int64
  -> (unit, int) result

(** [enable_queue_events handle write_fd] registers [write_fd] with the
    librdkafka main queue.  One byte is written to [write_fd] whenever the
    queue transitions from empty to non-empty.  Call [poll handle 0] after
    waking on the matching read end to drain all pending events. *)
val enable_queue_events : kafka_handle -> int -> unit

(** [disable_queue_events handle] clears the io-event callback registered by
    [enable_queue_events].  Call during producer shutdown before closing the
    pipe so librdkafka cannot write to a recycled file descriptor. *)
val disable_queue_events : kafka_handle -> unit

val poll    : kafka_handle -> int -> int
val flush   : kafka_handle -> int -> (unit, int) result

(** [destroy handle] flushes with 0ms timeout, nulls the internal pointer, and
    calls rd_kafka_destroy with the OCaml domain lock released. After this call
    the GC finalizer for [handle] becomes a no-op — double-destroy is impossible. *)
val destroy : kafka_handle -> unit
val err2str : int -> string

(** Consumer-specific *)
val subscribe         : kafka_handle -> string list -> (unit, string) result
val consumer_poll     : kafka_handle -> int -> (string * int32 * int64 * bytes option * bytes * int64 option * (string * string) list) option

(** [produce_v handle topic_name partition value key_opt correlation_id headers]
    Enqueues a message using rd_kafka_producev, supporting Kafka message headers.
    [headers] is transferred to librdkafka on success. [correlation_id = 0L] means
    fire-and-forget. Use when header propagation (e.g. traceparent) is needed. *)
val produce_v
  :  kafka_handle
  -> string                    (* topic name *)
  -> int32                     (* partition; -1 = auto *)
  -> bytes                     (* value *)
  -> bytes option              (* key *)
  -> int64                     (* correlation id *)
  -> (string * string) list    (* headers *)
  -> (unit, int) result
val consumer_close    : kafka_handle -> unit

(** Returns the number of partitions currently assigned to this consumer.
    Fast local query — does not block or call the broker. *)
val assignment_count  : kafka_handle -> int

(** [create_topic handle ~topic_name ~partitions ~replication_factor]
    creates a topic via librdkafka's admin API on an existing handle.
    Releases the OCaml domain lock while awaiting the broker response.
    Returns 0 on success; treats TOPIC_ALREADY_EXISTS as success.
    Returns a non-zero librdkafka error code on failure. *)
val create_topic : kafka_handle -> topic_name:string -> partitions:int -> replication_factor:int -> int
val commit_message : kafka_handle -> topic:string -> partition:int32 -> offset:int64 -> async:bool -> (unit, int) result

(** Delivery pipe *)
val pipe_create     : unit -> int * int
val delivery_sizeof : unit -> int
val read_delivery   : int -> int64 * int

(** Transactional API *)
val init_transactions          : kafka_handle -> int -> (unit, int) result
val begin_transaction          : kafka_handle -> (unit, int) result
val commit_transaction         : kafka_handle -> int -> (unit, int) result
val abort_transaction          : kafka_handle -> int -> (unit, int) result
val send_offsets_to_transaction : kafka_handle -> kafka_handle -> int -> (unit, int) result

(** [pause_partition handle topic partition] pauses delivery for one partition.
    Local operation — no broker round-trip. Safe to call from any fiber. *)
val pause_partition  : kafka_handle -> string -> int32 -> unit

(** [resume_partition handle topic partition] resumes delivery for one partition. *)
val resume_partition : kafka_handle -> string -> int32 -> unit
