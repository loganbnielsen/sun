# kafka-eio-consumer — Design Document

## Overview

A modern OCaml Kafka consumer library built on librdkafka and Eio. Companion package
to `kafka-eio-producer` — intentionally separate so users can take only what they need.

Goals:
- Eio-native stream-based API — consumption feels like processing a sequence
- Consumer group support out of the box
- Explicit offset management with safe defaults (at-least-once)
- Exactly-once via transactional API in coordination with `kafka-eio-producer`
- librdkafka as the underlying transport
- Modular enough to swap for pure OCaml transport later

## Package Structure

```
kafka-eio-consumer/
  lib/
    kafka_consumer.ml     # public API
    kafka_consumer.mli
  test/
    ...
```

`Kafka_raw` and `Kafka_error` are provided by `kafka-eio-core` and shared with
`kafka-eio-producer`. The consumer does not duplicate the FFI layer or C stubs.
See the core design doc for the full FFI surface.

## Message Type

Defined by the Kafka protocol and exposed by librdkafka's `rd_kafka_message_t`.
The OCaml type is a clean projection:

```ocaml
type message = {
  topic     : string;
  partition : int32;
  offset    : int64;
  key       : bytes option;
  value     : bytes;
  timestamp : int64 option;
  headers   : (string * bytes) list;  (* Kafka 0.11+ *)
}
```

Headers are the Kafka-native metadata mechanism — arbitrary key/value pairs attached
to a message at produce time. Timestamp comes from a separate librdkafka call
(`rd_kafka_message_timestamp`) and is optional since older brokers may not provide it.

## Configuration

```ocaml
type offset_reset =
  | Earliest   (** start from beginning of partition on first read *)
  | Latest     (** start from end — only new messages *)

type rebalance_event =
  | Partitions_assigned of partition list
  | Partitions_revoked  of partition list

and partition = {
  topic     : string;
  partition : int32;
  offset    : int64;
}

type config = {
  brokers      : string list;
  group_id     : string;                              (** required for consumer group coordination *)
  topics       : string list;
  offset_reset : offset_reset;                        (** default: Latest *)
  auto_commit  : bool;                                (** default: false — prefer explicit ack *)
  on_rebalance : (rebalance_event -> unit) option;    (** default: None *)
}
```

`group_id` is required rather than optional — consumer groups are the standard
production pattern. Users who want manual partition assignment can set a unique
`group_id` per instance.

Most users won't need `on_rebalance`. It exists for cases where you need to flush
state or pause processing before partitions are revoked — common in stateful stream
processing.

## Consumer Handle

```ocaml
type t  (* abstract — wraps kafka_handle + Eio resources *)

val create : config -> sw:Eio.Switch.t -> (t, Kafka_error.t) result
val close  : t -> unit
```

## Core Consumption API

### High-Level: Stream

The primary API. Returns an Eio stream that yields messages as they arrive.
The library drives the poll loop internally.

```ocaml
(** Returns a stream of incoming messages. Runs the librdkafka poll loop
    in a background fiber. Backpressure is handled via Eio.Stream capacity. *)
val stream : t -> message Eio.Stream.t
```

Usage:

```ocaml
let stream = Kafka_consumer.stream consumer in
let rec loop () =
  let msg = Eio.Stream.take stream in
  process msg;
  loop ()
in
loop ()
```

### Low-Level: Poll

For users who want manual control of the poll loop:

```ocaml
(** Poll for a single message. Returns None on timeout. *)
val poll : t -> timeout_ms:int -> (message option, Kafka_error.t) result
```

## Offset Management

### Explicit Ack (recommended)

The handler receives an `ack` function alongside the message. Calling `ack ()` commits
the offset. Users decide when they're ready — after receive, after processing, after
a downstream write, etc.

```ocaml
(** Process messages from the stream. The handler receives each message
    and an ack function. Call ack () when the message is fully processed.
    Commits offset only after ack is called. *)
val consume
  :  t
  -> handler:(message -> ack:(unit -> unit) -> (unit, Kafka_error.t) result)
  -> (unit, Kafka_error.t) result
```

The standard at-least-once pattern:

```ocaml
Kafka_consumer.consume consumer ~handler:(fun msg ~ack ->
  let* () = write_to_database msg.value in
  ack ();   (* only advance offset after successful DB write *)
  Ok ()
)
```

### Auto-Commit

Available when `auto_commit = true` in config. librdkafka commits periodically in the
background. Simpler but risks message loss on crash — offset may advance before
processing completes.

### Manual Commit

For power users who need fine-grained control outside the `consume` abstraction:

```ocaml
(** Commit offset for a specific message explicitly *)
val commit : t -> message -> (unit, Kafka_error.t) result

(** Commit all currently assigned partition offsets *)
val commit_all : t -> (unit, Kafka_error.t) result
```

## Transactions (Exactly Once)

Exactly-once processing requires coordination between consumer and producer — the
consumer offset advance is tied atomically to the producer transaction. This is
handled on the producer side via `Kafka_producer.with_transaction ~consumer`.

From the consumer's perspective, no special API is needed. The consumer handle is
passed to the producer's `with_transaction` call, which internally calls
`send_offsets_to_transaction` before committing:

```ocaml
(* Consume-transform-produce, exactly once *)
Kafka_producer.with_transaction producer ~consumer @@ fun () ->
  let* msg = Kafka_consumer.poll consumer ~timeout:1.0 in
  match msg with
  | None -> Ok ()
  | Some m ->
    let transformed = transform m.value in
    Kafka_producer.produce_await producer ~topic:"output" ~value:transformed
```

The consumer offset only advances if the transaction commits. If the process crashes
mid-transaction, the broker aborts it and the message is replayed.

**Note:** Transactions require `auto_commit = false` in the consumer config. `create`
returns an error if `auto_commit = true` and the consumer is passed to a transactional
producer.

## Example: Full Consumer

```ocaml
let () =
  Eio_main.run @@ fun env ->
    let cfg = {
      brokers      = ["localhost:9092"];
      group_id     = "my-service";
      topics       = ["events"];
      offset_reset = Latest;
      auto_commit  = false;
      on_rebalance = None;
    } in
    Eio.Switch.run @@ fun sw ->
    match Kafka_consumer.create cfg ~sw with
    | Error e ->
      Printf.printf "Failed: %s\n" (Kafka_error.to_string e)
    | Ok consumer ->
      Kafka_consumer.consume consumer ~handler:(fun msg ~ack ->
        Printf.printf "Got: %s\n" (Bytes.to_string msg.value);
        ack ();
        Ok ()
      )
```

## Future: Lwt Compatibility Shim

A thin `kafka-eio-consumer-lwt` package will wrap the Eio API for Lwt codebases
via the eio-lwt bridge. Not in scope for v1.

## Future: Pure OCaml Transport

Same as the producer — `Kafka_raw` in core is isolated behind an interface. A future
`kafka-eio-consumer-native` could replace librdkafka with a pure OCaml Eio TCP
implementation. The public API would remain unchanged.

## Out of Scope (v1)

- Schema Registry integration
- Admin API
- Lwt shim
- Seek / manual partition assignment API (beyond `group_id` workaround)
