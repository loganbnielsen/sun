# dynamo-eio

Layer 3 of the AWS integration plan in `aws-audit.md` — "the ElectroDB-replacement
layer." A DynamoDB client on `aws-eio`, with a typed indexing layer as its actual reason
to exist (not just a raw API binding).

## Overview

DynamoDB's wire protocol is JSON over a single fixed regional endpoint
(`dynamodb.<region>.amazonaws.com`), simpler in that respect than S3's XML/virtual-hosting
concerns. The hard part is the *data model*: composite partition/sort keys, secondary
indexes, and multiple entity types sharing one physical table. ElectroDB (the TypeScript
library this layer replaces) solves this with runtime-templated key strings
(`` `USER#${id}` ``) — a missing or reordered parameter is a runtime bug, sometimes silent
(wrong partition, not an error), and querying an index with the wrong key shape is a
runtime failure, not a compile error.

`dynamo-eio` fixes this with one module per index, each carrying its own nominally
distinct `pk`/`sk` types, generating its own typed `get`/`query` via a functor — the same
shape as `pg-eio`'s `Table.Make(SCHEMA)`, applied once per index instead of once per
table. Passing one index's key to another index's functions is a **type error**, not a
runtime bug.

## Package Structure

```
dynamo-eio/
  lib/
    dynamo_error.ml/.mli   -- error type extending Aws_error.t
    dynamo_value.ml/.mli   -- attribute_value type + JSON codec
    dynamo_client.ml/.mli  -- raw PutItem/GetItem/DeleteItem/Query
    dynamo_table.ml/.mli   -- Table.Index(I)/Table.Entity(E) functors
    dune
  test/
    test_dynamo_value.ml            -- attribute_value <-> JSON round trips
    test_dynamo_error.ml            -- of_response classification
    test_dynamo_client.ml           -- item encoding + response interpretation (pure)
    test_dynamo_table.ml            -- Index/Entity functor behavior
    negative_index_mismatch.ml.txt  -- the negative-compilation check (see its own
                                        header — named .txt so dune never compiles it;
                                        not wired into an automated rule, verified by
                                        hand, re-verify by hand if Index's signature
                                        ever changes)
    test_dynamo_live.ml             -- gated by DYNAMO_EIO_LIVE=1, real table required
    dune
  dynamo-eio.md
```

## v1 Scope

`put_item`, `get_item`, `delete_item`, `query` (single page — no `LastEvaluatedKey`
pagination) on the raw `Dynamo_client`, plus `Table.Index`/`Table.Entity` on top. See
"Out of Scope" for what v1 deliberately does not cover.

## Wire protocol

Every request: `POST /` to `dynamodb.<region>.amazonaws.com`, `Content-Type:
application/x-amz-json-1.0`, `X-Amz-Target: DynamoDB_20120810.<Action>` (e.g.
`DynamoDB_20120810.PutItem`), JSON body. SigV4 `service = "dynamodb"`,
`normalize_path = true` (DynamoDB has no S3-style path-normalization exception — the
path is always `/` anyway). Throttling (`ProvisionedThroughputExceededException`) and 5xx
retries are already handled by `aws-eio`'s `signed_request` (`is_retryable_response`
already checks the JSON-body `__type` field this raises under — no new retry logic
needed here).

Errors: a non-2xx response is a JSON body `{"__type": "...#SomeException", "message":
"..."}`. `Dynamo_error.of_response` classifies `ConditionalCheckFailedException` and
`ResourceNotFoundException` as their own cases (common enough to deserve one); anything
else parseable becomes `Service_error`; anything unparseable becomes
`Unparseable_error_response`.

## `Dynamo_value.t` — DynamoDB's attribute-value encoding

```ocaml
type t =
  | S of string
  | N of string  (** DynamoDB numbers are wire-encoded as decimal strings, not JSON
                     numbers, specifically to avoid precision loss on large integers —
                     encoding a real OCaml int/float is the caller's job. *)
  | B of string  (** Raw bytes; base64-encoded only at the JSON boundary. *)
  | Bool of bool
  | Null
  | Ss of string list
  | Ns of string list
  | Bs of string list
  | L of t list
  | M of (string * t) list

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
```

## `Dynamo_client` — raw operations

```ocaml
type config = { table : string; region : string; credentials : Aws_credentials.t }
type item = (string * Dynamo_value.t) list

val put_item : net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> item:item -> (unit, Dynamo_error.t) result
val get_item : net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:item -> (item option, Dynamo_error.t) result
val delete_item : net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config -> key:item -> (unit, Dynamo_error.t) result

val query :
  net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> config ->
  ?index_name:string ->
  key_condition_expression:string ->
  expression_attribute_values:item ->
  (item list, Dynamo_error.t) result
(** Single page only — v1 does not read [LastEvaluatedKey]. A query whose real result
    set exceeds DynamoDB's 1MB-per-page limit silently returns only the first page; see
    "Out of Scope". *)
```

## `Dynamo_table` — the typed indexing layer

```ocaml
module type INDEX = sig
  type pk
  type sk

  val index_name : string option  (** [None] = the table's primary index. *)
  val format_pk : pk -> string
  val format_sk : sk -> string
  val pk_attribute : string  (** the index's partition-key attribute name *)
  val sk_attribute : string  (** the index's sort-key attribute name *)
end

module Index (I : INDEX) : sig
  val get :
    net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> Dynamo_client.config ->
    pk:I.pk -> sk:I.sk -> (Dynamo_client.item option, Dynamo_error.t) result

  val query :
    net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> Dynamo_client.config ->
    pk:I.pk -> unit -> (Dynamo_client.item list, Dynamo_error.t) result
  (** Queries every item under [pk] on this index — the [sk] is deliberately not
      a parameter here; a query that needs a sort-key condition beyond "starts
      with this partition" is real, deferred scope (see "Out of Scope"). *)
end

module type ENTITY = sig
  val name : string  (** stamped into the reserved discriminator attribute on
                          every put, and checked on every decode. *)
end

module Entity (E : ENTITY) : sig
  val discriminator_attribute : string  (** ["__dynamo_eio_entity__"] *)

  val stamp : Dynamo_client.item -> Dynamo_client.item
  (** Adds the discriminator attribute — call before [Dynamo_client.put_item]. *)

  val check : Dynamo_client.item -> (Dynamo_client.item, Dynamo_error.t) result
  (** [Error (Wrong_entity got)] if the stamped name doesn't match [E.name] (or
      is missing) — call after [Dynamo_client.get_item]/[query] before treating
      the item as this entity's shape. *)
end
```

The two functors compose independently — `Index` handles key-shape safety, `Entity`
handles cross-entity-type discrimination on a shared table. A caller who wants both
applies `Entity(E).stamp` before `Index(I).get`'s underlying put, and `Entity(E).check`
on what `Index(I).get`/`query` return.

**The one test that has to be a compile-time check, not a runtime assertion:** passing
`User_by_email`'s `` `Email `` key to `Index(User_primary)`'s functions must fail to
*compile* — `[ \`Org of string ]` and `[ \`Email of string ]` don't unify. This is the
entire point of the design; a runtime test would only prove the design accidentally
degraded to ElectroDB's own weaker guarantee.

## Example Usage

```ocaml
module User_primary = struct
  type pk = [ `Org of string ]
  type sk = [ `User of string ]
  let index_name = None
  let format_pk (`Org id) = "ORG#" ^ id
  let format_sk (`User id) = "USER#" ^ id
  let pk_attribute = "PK"
  let sk_attribute = "SK"
end

module Users = Dynamo_table.Index (User_primary)
module User_entity = Dynamo_table.Entity (struct let name = "user" end)

let config = { Dynamo_client.table = "app"; region = "us-east-1"; credentials }

(* let _ = Users.get ~net ~clock config ~pk:(`Email "x") ~sk:(`User "y")
   -- does not compile: `Email is User_by_email's pk type, not User_primary's *)
```

## Out of Scope (v1)

- **Update expressions** (`SET`/`REMOVE`/`ADD` attribute-path syntax) — `put_item`
  (full-item replace) covers v1, matching `pg-eio`'s own deferral of upsert helpers.
- **Conditional writes / optimistic locking** (`ConditionExpression`) — real,
  deferred v2 scope, not a thin passthrough bolted onto v1's `put_item`.
- **Pagination** (`LastEvaluatedKey`) — needs a typed cursor to avoid ElectroDB's own
  pagination footgun (a cursor silently valid for the wrong index/query); real design
  work, not done here. `query` in v1 always returns exactly one page.
- **`Index.query`'s sort-key conditions** (`begins_with`, `between`, comparisons beyond
  "all items under this partition") — v1's `query` only takes a partition key.
- **Batch operations** (`BatchGetItem`/`BatchWriteItem`) — different request/response
  shape (multiple items per call), not a small extension of the single-item operations.
- **Transactions** (`TransactWriteItems`) — real, separate scope.
