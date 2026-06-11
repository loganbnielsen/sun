# kafka-eio-producer — Design Document

## Overview

A modern OCaml Kafka producer library built on librdkafka and Eio. Part of a planned
two-library suite — producer and consumer are intentionally separate packages so users
can take only what they need.

Goals:
- Eio-native from day one (OCaml 5 effects-based concurrency)
- No exceptions as control flow — errors are values
- Type-safe, exhaustive error handling via variants
- librdkafka as the underlying transport (battle-tested protocol, C FFI)
- Modular enough to swap librdkafka for a pure OCaml implementation later

## Package Structure

```
kafka-eio-producer/
  lib/
    kafka_producer.ml   # public API
    kafka_producer.mli
  test/
    ...
```

`Kafka_raw` and `Kafka_error` are provided by `kafka-eio-core` and shared with
`kafka-eio-consumer`. The producer does not duplicate the FFI layer or C stubs.
See the core design doc for the full FFI surface, including the transactional API.

## Configuration

```ocaml
type delivery_mode =
  | At_least_once   (** default — idempotent producer, acks=all *)
  | At_most_once    (** fire and forget *)
  | Exactly_once of { transaction_id: string }  (** EOS, explicit opt-in *)

type config = {
  brokers       : string list;
  delivery_mode : delivery_mode;  (** default: At_least_once *)
  (* additional typed knobs as needed *)
}
```

Config values map to librdkafka string key/value pairs at initialization time. The
typed config ensures users can't pass invalid combinations and steers them toward safe
defaults.

## Producer Handle

```ocaml
type t  (* abstract — wraps kafka_handle + Eio resources *)

val create : config -> sw:Eio.Switch.t -> _ Eio.Time.clock -> (t, Kafka_error.t) result
val close  : t -> unit
```

## Producing Messages

Two variants — fire and forget vs. awaitable delivery receipt:

```ocaml
(** Enqueues message locally and returns immediately.
    No delivery confirmation.
    The trailing unit is required by OCaml's optional-argument erasure rules. *)
val produce
  :  t
  -> topic:string
  -> value:bytes
  -> ?key:bytes
  -> unit
  -> (unit, Kafka_error.t) result

(** Enqueues message and returns a promise that resolves
    when the broker acknowledges (or an error occurs).
    The trailing unit is required by OCaml's optional-argument erasure rules. *)
val produce_await
  :  t
  -> topic:string
  -> value:bytes
  -> ?key:bytes
  -> unit
  -> (unit, Kafka_error.t) result Eio.Promise.t

(** Wait for all enqueued messages to be delivered *)
val flush : t -> timeout_ms:int -> (unit, Kafka_error.t) result
```

## Transactional API

When `delivery_mode = Exactly_once`, the producer exposes a transaction bracket:

```ocaml
(** Run a function inside a Kafka transaction.
    Commits on Ok, aborts on Error or exception. *)
val with_transaction
  :  t
  -> ?consumer:Kafka_consumer_handle.t  (** bind consumer offsets atomically *)
  -> (unit -> (unit, Kafka_error.t) result)
  -> (unit, Kafka_error.t) result
```

Internally this calls `init_transactions` once at producer creation, then
`begin_transaction` / `commit_transaction` / `abort_transaction` around the
user-supplied function. When `~consumer` is provided, it calls
`send_offsets_to_transaction` before committing to atomically bind the consumer
offset advance to the transaction. See the core design doc for the full semantics.

## Delivery Receipt Implementation (Internal)

`produce_await` works by attaching an Eio promise resolver to each message via
librdkafka's `msg_opaque` void pointer:

```
produce_await
  -> create Eio promise + resolver
  -> store resolver pointer in msg_opaque
  -> call rd_kafka_produce
  -> return promise to caller

delivery callback fires (librdkafka thread)
  -> fish resolver out of msg_opaque
  -> resolve promise with Ok () or Error err
  -> caller's fiber unblocks
```

This is the core interesting engineering problem of the producer — safely passing an
OCaml value (the resolver) through a C void pointer and back.

## Example Usage

```ocaml
let () =
  Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
      let cfg = {
        brokers = ["localhost:9092"];
        delivery_mode = At_least_once;
        linger_ms = None;
      } in
      match Kafka_producer.create cfg ~sw env#clock with
      | Error e ->
        Printf.printf "Failed to create producer: %s\n" (Kafka_error.to_string e)
      | Ok producer ->
        (* fire and forget *)
        let _ = Kafka_producer.produce producer ~topic:"events" ~value:(Bytes.of_string "hello") () in

        (* await acknowledgment *)
        let receipt = Kafka_producer.produce_await producer ~topic:"events" ~value:(Bytes.of_string "hello") () in
        (match Eio.Promise.await receipt with
        | Ok ()   -> print_endline "delivered"
        | Error e -> Printf.printf "error: %s\n" (Kafka_error.to_string e))
```

## Future: Lwt Compatibility Shim

A thin `kafka-eio-producer-lwt` package will wrap the Eio API for use in Lwt
codebases via the eio-lwt bridge. Not in scope for v1.

## Future: Pure OCaml Transport

The `Kafka_raw` FFI layer in core is intentionally isolated behind an interface. A
future `kafka-eio-producer-native` could implement the same interface in pure OCaml
using Eio TCP, removing the librdkafka C dependency entirely. The public API would
remain unchanged.

## Out of Scope (v1)

- Schema Registry integration
- Admin API (topic creation, etc.)
- Lwt shim
