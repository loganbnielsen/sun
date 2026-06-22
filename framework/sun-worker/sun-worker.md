# sun-worker — Worker Primitive

## What it is

`sun-worker` is the Kafka consumer primitive. A `-worker` is a long-running process that subscribes to a topic, processes each message, and emits per-message metrics automatically.

The abstraction is the handler — `handle : Message.t -> ack:(unit -> unit) -> trace_ctx:Obs_trace.t option -> (unit, string) result`. Sun handles the consumer lifecycle, schema registration, graceful shutdown, and observability wiring.

## Module type

```ocaml
module type WORKER = sig
  module Message : Kafka_service.MESSAGE
  val group_id : string
  val handle : Message.t -> ack:(unit -> unit) -> trace_ctx:Obs_trace.t option -> (unit, string) result
end
```

- `Message` — the event contract. Defines topic name, JSON schema, encode/decode.
- `group_id` — Kafka consumer group ID. Must be stable across restarts.
- `handle` — called once per decoded message. `trace_ctx` carries the upstream W3C `traceparent` header from the Kafka message — pass it as `?parent:trace_ctx` to `Obs.with_span` to link spans. Return `Ok ()` to continue, `Error msg` to retry (see retry strategy).

## Entrypoint

```ocaml
module Make (W : WORKER) : sig
  val run
    :  env:< net       : _ Eio.Net.t
           ; clock     : _ Eio.Time.clock
           ; mono_clock: _ Eio.Time.Mono.t
           ; .. >
    -> config:Kafka_service.config
    -> ?ot:Obs.t
    (** When provided, emits sun_worker_messages_total{status} and
        sun_worker_message_duration_seconds per message. *)
    -> ?on_ready:(unit -> unit)
    (** Called exactly once when the broker assigns partitions to this consumer.
        Use it to signal readiness to a test or health-check. *)
    -> ?stop:bool Atomic.t
    (** External stop flag. Set to true for graceful shutdown from outside the worker. *)
    -> ?max_messages:int
    (** Stop cleanly after this many successfully processed messages. Useful in tests. *)
    -> ?retry_strategy:retry_strategy
    (** How to handle Error results from W.handle. Defaults to In_memory default_retry. *)
    -> ?_consume_loop:
         (handler:(W.Message.t -> ack:(unit -> unit) -> trace_ctx:Obs_trace.t option -> Kafka_consumer.handler_result)
          -> unit -> unit)
    (** Test injection: replace the real per-partition consume loop with a stub. *)
    -> unit
    -> unit
end
```

`Make(W).run` owns the full lifecycle: `Kafka_service.create` → `register` → `consume_partitioned`. It returns when the stop flag is set, `max_messages` is reached, `W.handle` fails beyond the retry budget, or a shutdown signal is received (SIGTERM or SIGINT).

## Retry strategy

```ocaml
type retry_policy = {
  base_delay_s : float;   (* Initial backoff in seconds. Doubles on each consecutive failure. *)
  max_delay_s  : float;   (* Backoff cap. Default: 600.0 (10 minutes). *)
  max_attempts : int;     (* Negative = retry indefinitely. Default: -1. *)
}

val default_retry : retry_policy
(* base_delay_s = 1.0, max_delay_s = 600.0, max_attempts = -1 *)

type retry_strategy =
  | In_memory    of retry_policy
    (* Exponential back-off sleep inside the partition fiber. Simple, zero infra.
       Vulnerable to rebalance preempting the sleep window. *)
  | Retry_topics of { max_attempts : int }
    (* On failure: publish raw bytes to <topic>-retry; commit original offset immediately.
       A background retry consumer delays until X-Sun-Retry-At then re-runs W.handle.
       After max_attempts failures the message is moved to <topic>-dlq. *)

val default_retry_strategy : retry_strategy
(* In_memory default_retry — in-process exponential backoff, infinite retries. *)
```

Pass `~retry_strategy` to `Make(W).run` to choose the failure-handling mode.

## Lifecycle

```
Make(W).run ~env ~config ?ot ?retry_strategy ()
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
       └─ Kafka_service.create → register → consume_partitioned
            per-partition fiber per message:
              if stop_flag → Stop         (graceful drain)
              else W.handle msg ~ack ~trace_ctx
                Ok ()   → metrics ok, Continue
                Error e → retry per strategy; after budget exhausted → Stop + raise
```

After `run` returns:
- If `W.handle` exhausted its retry budget → raises `Failure ("sun-worker: " ^ msg)`
- If `Kafka_service.create` failed → raises `Failure ("sun-worker: create failed: ...")`
- If `register` failed → raises `Failure ("sun-worker: register failed: ...")`
- On SIGTERM/SIGINT or `stop` flag → returns normally

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
| `sun_worker_messages_total` | counter | `status` | Messages processed (`ok`, `retry`, or `error`) |
| `sun_worker_message_duration_seconds` | histogram | — | Per-message processing latency |

Metrics are registered once at startup. Emitter functions are called in the handler closure on each message.

## Usage example

```ocaml
module BroadcastWorker = struct
  module Message = Events.Payments.Charged

  let group_id = "comms-broadcast-worker"

  let handle msg ~ack ~trace_ctx:_ =
    match Comms.send_push_notification msg with
    | Ok ()   -> ack (); Ok ()
    | Error e -> Error e
end

let () =
  Eio_main.run @@ fun env ->
    let backend, _render = Obs_prometheus.create () in
    let ot = Obs.create ~service:BroadcastWorker.group_id
               ~mono_clock:env#mono_clock ~backend in
    let config = Kafka_service.config_of_env () in
    Worker.Make(BroadcastWorker).run ~env ~config ~ot ()
```

## ack semantics

`ack ()` commits the Kafka offset for the current message. Call it after processing is complete — not before. If `W.handle` raises before calling `ack`, the message will be redelivered on restart.

The convention: call `ack` just before returning `Ok ()`. For at-least-once semantics this is correct. At-exactly-once is not supported in v1.

## Error handling

- `W.handle` returning `Error msg` triggers the retry strategy. After the retry budget is exhausted, the error is raised as `Failure` from `run`.
- Decode errors: default behavior from `Kafka_service.consume_partitioned` — logs to stderr, acks the message, continues. Override via `on_decode_error` by calling `Kafka_service.consume_partitioned` directly.
- All lifecycle errors (`create`, `register`, Kafka error) are raised as `Failure`.

## Test injection

`?_consume_loop` bypasses `Kafka_service.create/register/consume_partitioned` entirely, driving the wrapped handler with synthetic messages. Used in unit tests — not intended for production.

```ocaml
let fake_loop ~handler () =
  let _ = handler { id = "test-msg" } ~ack:(fun () -> ()) ~trace_ctx:None in
  ()

Worker.Make(W).run ~env ~config ~_consume_loop:fake_loop ()
```
