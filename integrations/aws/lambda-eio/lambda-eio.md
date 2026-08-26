# lambda-eio

Layer 4 of the AWS integration plan in `aws-audit.md`. The AWS Lambda Runtime API
long-poll loop, plus event-envelope parsing helpers for common trigger shapes.
**No dependency on `aws-eio`** — the Runtime API is a local, unsigned HTTP sidecar
(`AWS_LAMBDA_RUNTIME_API` points at a loopback address the Lambda execution
environment itself provides), not a signed AWS API call, so this uses `Cohttp_eio.Client`
directly (matching `obs-loki-eio`/`obs-prometheus-eio`'s own precedent for plain,
non-SigV4 HTTP — there is no wire-byte-encoding concern here the way there is for
`aws-eio`'s signed requests).

## Overview

Every Lambda execution environment sets `AWS_LAMBDA_RUNTIME_API` to a `host:port`
implementing the [Runtime API](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html):

1. `GET {base}/invocation/next` — blocks (a real long-poll: this can take minutes) until
   the next event arrives. Response headers carry `Lambda-Runtime-Aws-Request-Id`,
   `Lambda-Runtime-Deadline-Ms`, `Lambda-Runtime-Invoked-Function-Arn`; body is the raw
   JSON event payload.
2. Handler runs.
3. `POST {base}/invocation/{request_id}/response` on success, or
   `POST {base}/invocation/{request_id}/error` on failure — the process then loops back
   to step 1. A Lambda execution environment is reused across many invocations while
   "warm"; this loop runs for the process's entire lifetime, not once.
4. `POST {base}/init/error` instead, if initialization itself fails before the loop
   ever starts.

## Package Structure

```
lambda-eio/
  lib/
    lambda_runtime.ml/.mli  -- the invoke-next/respond/error loop
    lambda_event.ml/.mli    -- S3/SQS/DynamoDB-Streams event envelope parsing
    dune
  test/
    test_lambda_event.ml       -- event envelope parsing against real AWS example payloads
    test_lambda_runtime.ml     -- protocol correctness against a local mock Runtime API
                                  server (plain HTTP — no TLS/SNI blocker here, unlike
                                  s3-eio/dynamo-eio's aws-eio-backed tests)
    dune
  lambda-eio.md
```

## `Lambda_runtime`

```ocaml
type invocation = {
  request_id : string;
  deadline_ms : int64;
  invoked_function_arn : string;
  trace_id : string option;
  payload : string;  (** raw JSON event body — {!Lambda_event} parses common shapes *)
}

val runtime_api_base : unit -> (string, string) result
(** Reads [AWS_LAMBDA_RUNTIME_API]; [Error] if unset — calling this outside a real
    Lambda execution environment (or a local Runtime Interface Emulator) is a
    configuration error, not something to default around. *)

val next_invocation : net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string -> (invocation, string) result
val respond : net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string -> request_id:string -> body:string -> (unit, string) result
val respond_error :
  net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string -> request_id:string ->
  error_message:string -> error_type:string -> (unit, string) result
val init_error :
  net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string ->
  error_message:string -> error_type:string -> (unit, string) result

val run_loop :
  net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string ->
  handler:(invocation -> (string, string) result) -> unit
(** Loops forever: [next_invocation], run [handler], [respond]/[respond_error].
    A handler exception is caught and reported via [respond_error] rather than
    crashing the loop — one bad invocation must not kill the whole warm
    execution environment for every future invocation. *)
```

## `Lambda_event`

Real AWS event envelope shapes, parsed leniently (extra fields ignored, matching every
other `*_of_json` in this codebase's AWS integrations):

```ocaml
type s3_record = { bucket : string; key : string; event_name : string }
val s3_records_of_json : Yojson.Safe.t -> (s3_record list, string) result

type sqs_record = { message_id : string; body : string }
val sqs_records_of_json : Yojson.Safe.t -> (sqs_record list, string) result

type dynamodb_stream_record = {
  event_name : string;
  keys : Yojson.Safe.t;
  new_image : Yojson.Safe.t option;
  old_image : Yojson.Safe.t option;
}
val dynamodb_stream_records_of_json : Yojson.Safe.t -> (dynamodb_stream_record list, string) result
```

## Sun-specific glue (not in this package — stays in `framework/sun-fn/`)

`-fn` only for v1 — Lambda fronting `-svc` over API Gateway is a different integration
point (request/response cycle, not "run once and exit") and out of scope. `sun-fn`'s
`FN` module type
gains a `trigger` variant:

```ocaml
type trigger = Cron of string | Lambda

module type FN = sig
  val trigger : trigger  (* was: val schedule : string *)
  val run : unit -> (unit, string) result
end
```

`Make(F).run` dispatches on `F.trigger`: `Cron _` keeps the exact current behavior (run
once, record metrics, push, exit). `Lambda` uses `Lambda_runtime.run_loop`, calling
`F.run ()` once per invocation — v1 does not thread the event payload into `F.run`
itself (a Lambda-triggered `-fn` is functionally a cron job hosted on Lambda instead of
a k8s CronJob, not a general event-processing function; see `Lambda_event` above for
callers who want the payload parsed, which `-fn`'s v1 scope does not need). Metrics
record per-invocation instead of once-per-process-exit, and the process never calls
`exit` on success (a Lambda execution environment expects the process to keep running
and loop back to `next_invocation`).

## Out of Scope (v1)

- Threading the event payload into `F.run` for a Lambda-triggered `sun-fn` — v1 treats
  the event as opaque, matching `-fn`'s existing "run and report status" contract.
- Lambda fronting `-svc` (API Gateway integration) — a different, real integration
  point, deferred.
- Streaming responses, Lambda extensions API, provisioned-concurrency init hooks.
- Any event shape beyond S3/SQS/DynamoDB Streams (e.g. Kinesis, EventBridge, Cognito
  triggers) — add as needed, not speculatively.
