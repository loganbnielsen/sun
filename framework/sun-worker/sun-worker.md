# sun-worker — Worker Primitive

## What it is

`sun-worker` is the Kafka consumer primitive. A `-worker` is a long-running process that subscribes to a topic, processes each message, and emits per-message metrics automatically.

The abstraction is the handler — `handle : Message.t -> ack:(unit -> unit) -> (unit, string) result`. Sun handles the consumer lifecycle, schema registration, graceful shutdown, and observability wiring.

## Module type

```ocaml
module type WORKER = sig
  module Message : Kafka_service.MESSAGE
  val group_id : string
  val handle : Message.t -> ack:(unit -> unit) -> (unit, string) result
end
```

- `Message` — the event contract. Defines topic name, JSON schema, encode/decode.
- `group_id` — Kafka consumer group ID. Must be stable across restarts.
- `handle` — called once per decoded message. Return `Ok ()` to continue, `Error msg` to stop.

## Entrypoint

```ocaml
module Make (W : WORKER) : sig
  val run
    :  env:< net : _ Eio.Net.t; clock : _ Eio.Time.clock;
             mono_clock : _ Eio.Time.Mono.t; .. >
    -> config:Kafka_service.config
    -> ?ot:Obs.t
    -> unit -> unit
end
```

`Make(W).run` owns the full lifecycle: `Kafka_service.create` → `register` → `consume`. It returns when `W.handle` returns `Error` or when a shutdown signal is received (SIGTERM or SIGINT).

## Lifecycle

```
Make(W).run ~env ~config ?ot ()
  │
  ├─ Register metrics if ot provided
  │    sun_worker_messages_total{status}        [counter]
  │    sun_worker_message_duration_seconds      [histogram]
  │
  ├─ Atomic stop_flag = false
  │
  └─ Switch.run (outer)
       ├─ fork_daemon: signal handler → stop_flag := true  (self-pipe)
       │
       └─ Kafka_service.create → register → consume
            handler per message:
              if stop_flag → Stop        (graceful drain)
              else W.handle msg ~ack
                Ok ()   → metrics ok, Continue
                Error e → metrics error, capture e, Stop
```

After `consume` returns:
- If `W.handle` returned `Error msg` → raise `Failure ("sun-worker: " ^ msg)`
- If `Kafka_service.create` failed → raise `Failure ("sun-worker: create failed: ...")`
- If `register` failed → raise `Failure ("sun-worker: register failed: ...")`
- On SIGTERM/SIGINT → returns normally (stop_flag stops consume on the next message boundary)

## Signal handling

Self-pipe trick (same pattern as `sun-svc` and `sun-fn`):
1. `Unix.pipe ~cloexec:true` + `Unix.set_nonblock w`
2. `SIGTERM`/`SIGINT` handler: `Unix.single_write w "\x00"` (async-signal-safe)
3. `Fiber.fork_daemon ~sw`: `Eio_unix.await_readable r` → set `stop_flag := true`

Using `Atomic.t` rather than a promise: the stop flag is checked in the message handler, so the consumer finishes the current message before stopping (graceful drain). A promise + cancellation would abort mid-message.

## Metrics

When `?ot` is provided:

| Metric | Type | Labels | Description |
|---|---|---|---|
| `sun_worker_messages_total` | counter | `status` | Messages processed (`ok` or `error`) |
| `sun_worker_message_duration_seconds` | histogram | — | Per-message processing latency |

Metrics are registered once at startup. Emitter functions are called in the handler closure on each message.

## Usage example

```ocaml
module BroadcastWorker = struct
  module Message = Events.Payments.Charged

  let group_id = "comms-broadcast-worker"

  let handle msg ~ack =
    match Comms.send_push_notification msg with
    | Ok ()   -> ack (); Ok ()
    | Error e -> Error e
end

let () =
  Eio_main.run @@ fun env ->
    let backend, render = Obs_prometheus.create () in
    let ot = Obs.create ~service:BroadcastWorker.group_id
               ~mono_clock:env#mono_clock ~backend in
    Worker.Make(BroadcastWorker).run ~env ~config ~ot ()
```

## ack semantics

`ack ()` commits the Kafka offset for the current message. Call it after processing is complete — not before. If `W.handle` raises before calling `ack`, the message will be redelivered on restart.

The convention: call `ack` just before returning `Ok ()`. For at-least-once semantics this is correct. At-exactly-once is not supported in v1.

## Error handling

- `W.handle` returning `Error msg` stops the worker immediately (via `handler_error` ref → `Stop`). The error is raised as `Failure` from `run`.
- Decode errors: default behavior from `Kafka_service.consume` — logs to stderr, acks the message, continues. Override via `on_decode_error` by calling `Kafka_service.consume` directly.
- All lifecycle errors (`create`, `register`, `consume` Kafka error) are raised as `Failure`.

## Test injection

`?_consume_loop` bypasses `Kafka_service.create/register/consume` entirely, driving the wrapped handler with synthetic messages. Used in unit tests — not intended for production.

```ocaml
let fake_loop ~handler () =
  let _ = handler { id = "test-msg" } ~ack:(fun () -> ()) in
  ()

Worker.Make(W).run ~env ~config ~_consume_loop:fake_loop ()
```
