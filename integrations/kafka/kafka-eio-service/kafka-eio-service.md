# kafka-eio-service — Design Document

## Overview

High-level service layer for the Sun Kafka stack. Sits on top of `kafka-eio-producer`
and `kafka-eio-consumer` and adds:

- **Typed message contracts** — each topic has an OCaml type with encode/decode
- **Schema registry** — schemas are registered with Redpanda's built-in schema registry
  on startup; producers can't publish messages with breaking schema changes
- **Topic auto-provisioning** — topics are created via the Redpanda admin API on startup
  if they don't exist
- **Confluent wire format** — every message is framed with a magic byte and schema ID
  so any Confluent-compatible consumer can decode it
- **Batched delivery** — `linger_ms` (default 50ms) batches outbound messages for
  throughput without adding application complexity

## Package Structure

```
kafka-eio-service/
  lib/
    kafka_service.ml   # full implementation + internal HTTP client
    kafka_service.mli  # public API
  test/
    test_kafka_service.ml
```

All HTTP client, schema registry, and admin API logic lives inside `kafka_service.ml`
as private helpers. No extra packages beyond `yojson` and the existing Eio ecosystem.

## Message Contract

Users define a module satisfying `MESSAGE` for each topic they own:

```ocaml
module PaymentEvent : Kafka_service.MESSAGE = struct
  type t = {
    payment_id : string;
    amount_cents : int;
    currency : string;
  }

  let topic_name = "payments"

  let schema = {|{
    "type": "object",
    "properties": {
      "payment_id":    { "type": "string" },
      "amount_cents":  { "type": "integer" },
      "currency":      { "type": "string" }
    },
    "required": ["payment_id", "amount_cents", "currency"]
  }|}

  let encode t = `Assoc [
    ("payment_id",    `String t.payment_id);
    ("amount_cents",  `Int    t.amount_cents);
    ("currency",      `String t.currency);
  ]

  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "payment_id" fields,
             List.assoc_opt "amount_cents" fields,
             List.assoc_opt "currency" fields with
       | Some (`String payment_id), Some (`Int amount_cents), Some (`String currency) ->
         Ok { payment_id; amount_cents; currency }
       | _ -> Error "missing required fields")
    | _ -> Error "expected object"
end
```

## Configuration

```ocaml
type config = {
  brokers             : string list;
  schema_registry_url : string;  (* "http://localhost:8081" *)
  linger_ms           : int;     (* batch window; 50ms recommended *)
  partitions          : int;     (* partition count for new topics; 3 is typical *)
}

(* Note: topic auto-provisioning via the Redpanda admin API is planned for v2.
   In v1, topics must be created externally (e.g. platform/local/scripts/create-topics.sh).
   register/2 registers the schema but does not create the topic. *)
```

## Public API

```ocaml
(** Create a service handle. Starts the underlying producer with linger_ms batching. *)
val create : config -> sw:Eio.Switch.t -> _ Eio.Time.clock -> (t, string) result

(** Provision the topic and register its schema. Returns a typed handle.
    Call once per message type at startup. *)
val register : t -> net:_ Eio.Net.t -> (module MESSAGE with type t = 'a) -> ('a topic, string) result

(** Publish a typed message. Always awaits broker acknowledgement. *)
val publish : t -> 'a topic -> 'a -> (unit, Kafka_error.t) result Eio.Promise.t

(** Subscribe and process messages. ack () commits the offset.
    Returns when handler returns Error. *)
val consume
  :  t -> 'a topic -> group_id:string -> sw:Eio.Switch.t
  -> handler:('a -> ack:(unit -> unit) -> (unit, Kafka_error.t) result)
  -> (unit, Kafka_error.t) result
```

## Wire Format

Every message on the wire uses the Confluent framing:

```
+--------+-------------------+-----------------+
| 0x00   | schema_id (4 B BE)| JSON payload    |
| magic  |                   |                 |
+--------+-------------------+-----------------+
```

This means any Confluent-compatible consumer (other languages, Kafka Streams, etc.)
can decode messages published by Sun services without Sun-specific tooling.

## Example: Payments Producer

```ocaml
let () =
  Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
      let cfg : Kafka_service.config = {
        brokers             = ["localhost:9092"];
        schema_registry_url = "http://localhost:8081";
        linger_ms           = 50;
        partitions          = 3;
      } in
      match Kafka_service.create cfg ~sw env#clock with
      | Error e -> failwith e
      | Ok svc ->
        match Kafka_service.register svc ~net:env#net (module PaymentEvent) with
        | Error e -> failwith e
        | Ok topic ->
          let p = Kafka_service.publish svc topic
            { payment_id = "pay-001"; amount_cents = 9900; currency = "USD" }
          in
          match Eio.Promise.await p with
          | Ok ()   -> print_endline "published"
          | Error e -> Printf.eprintf "error: %s\n" (Kafka_error.to_string e)
```

## Example: Audit Consumer

```ocaml
Kafka_service.consume svc topic ~group_id:"audit-svc" ~sw
  ~handler:(fun event ~ack ->
    record_audit_log event;
    ack ();
    Ok ()
  )
```

Multiple services (`audit-svc`, `financials-svc`) can consume the same `payments`
topic independently using different `group_id` values. Each gets its own offset
cursor — they don't interfere with each other.

## Out of Scope (v1)

- Schema evolution / compatibility enforcement (add `compatibility` setting to schema registry)
- Consumer group lag monitoring
- Dead letter queue for decode failures (currently logged and skipped)
- Batch consume API
- Key encoding (currently keys are not schema-framed)
