# sun-storage

PostgreSQL storage layer for Sun services. Typed queries, connection pooling, a built-in migration runner, and a table functor — no raw SQL or manual connection management required.

---

## Package Structure

```
integrations/storage/sun-storage/
  lib/
    storage_error.ml/.mli   ← typed error ADT
    db.ml/.mli              ← pool, exec/find/collect/transaction
    migration.ml/.mli       ← apply/status/rollback, tracking table management
    table.ml/.mli           ← Table.Make(SCHEMA) functor
    dune
  test/
    test_storage.ml         ← 8 tests (2 unit + 6 integration)
    dune
```

---

## Public API

### `Storage_error`

```ocaml
type t =
  | Connection_failed of string
  | Query_error       of string
  | Not_found
  | Constraint_violation of string
  | Migration_error   of string

val to_string : t -> string
```

### `Db`

```ocaml
module Type    = Caqti_type
module Request = Caqti_request

type pool

val create_pool
  :  url:string
  -> ?pool_size:int
  -> sw:Eio.Switch.t
  -> stdenv:Caqti_eio.stdenv
  -> unit
  -> (pool, Storage_error.t) result

val exec     : pool -> ('p, unit,  [< `Zero])              Caqti_request.t -> 'p -> (unit,    Storage_error.t) result
val find     : pool -> ('p, 'r,    [< `Zero | `One])       Caqti_request.t -> 'p -> ('r option, Storage_error.t) result
val collect  : pool -> ('p, 'r,    [< `Zero | `One | `Many]) Caqti_request.t -> 'p -> ('r list, Storage_error.t) result
val transaction : pool -> (pool -> ('a, Storage_error.t) result) -> ('a, Storage_error.t) result
```

**Usage pattern:**

```ocaml
let insert_q =
  Caqti_request.Infix.(Caqti_type.(t2 int string) ->. Caqti_type.unit)
    "INSERT INTO users (id, name) VALUES (?, ?)"

let find_q =
  Caqti_request.Infix.(Caqti_type.int ->? Caqti_type.string)
    "SELECT name FROM users WHERE id = ?"

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Db.create_pool ~url:"postgresql://..." ~sw
               ~stdenv:(env :> Caqti_eio.stdenv) ()
             |> Result.get_ok in
  let _ = Db.exec pool insert_q (1, "Alice") in
  let name = Db.find pool find_q 1 in
  ...
```

`caqti` uses `?` placeholders in SQL strings; the postgresql driver translates them to `$1`, `$2`, etc.

### `Migration`

```ocaml
type status = {
  version    : int;
  name       : string;
  applied_at : string option;  (* None if not yet applied *)
}

(** Apply all pending SQL migrations from [dir].
    Pass [~table] to use a per-workspace tracking table, avoiding version-number
    collisions when multiple workspaces share the same database in development.
    The default table name is "sun_schema_migrations".
    Calling apply twice is a no-op for already-applied migrations. *)
val apply
  :  ?table:string
  -> Db.pool
  -> dir:string
  -> (unit, Storage_error.t) result

(** Return one entry per migration file, showing whether each version has been
    applied and when. Pass [~table] to match the table used in [apply]. *)
val status
  :  ?table:string
  -> Db.pool
  -> dir:string
  -> (status list, Storage_error.t) result

(** Roll back the last applied migration by running the companion
    [NNNN_name.down.sql] file and removing the version record from the tracking
    table. Fails if no migrations are applied or if the down-migration file does
    not exist. Pass [~table] to match the table used in [apply]. *)
val rollback
  :  ?table:string
  -> Db.pool
  -> dir:string
  -> (unit, Storage_error.t) result
```

Migration files follow the naming convention `NNNN_description.sql` (e.g. `0001_init.sql`).
Down-migration files follow `NNNN_description.down.sql` (required for `rollback`).
Applied versions are tracked in a table created automatically on first `apply`.

**`~table` parameter:** The default tracking table name is `"sun_schema_migrations"`. When
multiple workspaces share the same database in development (e.g. `sun dev up` with a single
PostgreSQL instance), pass a workspace-scoped name to avoid version-number collisions:

```ocaml
Migration.apply ~table:"myworkspace_schema_migrations" pool ~dir:"db/migrations"
```

The `sun migrate` CLI derives the table name automatically from the workspace directory name
(`sun_<workspace>_schema_migrations`), so manual `~table` wiring is only needed when calling
`Migration` directly.

**Tracking table schema:**
```sql
CREATE TABLE sun_schema_migrations (
  version    INT  PRIMARY KEY,
  name       TEXT NOT NULL,
  applied_at TIMESTAMPTZ DEFAULT now()
)
```

### `Table.Make(SCHEMA)`

```ocaml
module type SCHEMA = sig
  val table     : string
  val id_column : string
  val columns   : string list
  type t
  type id
  val row_type : t Caqti_type.t
  val id_type  : id Caqti_type.t
  val get_id   : t -> id
end

module Make (S : SCHEMA) : sig
  val find   : Db.pool -> S.id -> (S.t option, Storage_error.t) result
  val insert : Db.pool -> S.t  -> (unit, Storage_error.t) result
  val delete : Db.pool -> S.id -> (unit, Storage_error.t) result
  val list   : Db.pool -> ?limit:int -> ?offset:int -> unit -> (S.t list, Storage_error.t) result
end
```

`table`, `id_column`, and each entry in `columns` are validated once when
`Table.Make` is applied. They must be unquoted SQL identifiers matching
`[A-Za-z_][A-Za-z0-9_]*`; quoted and schema-qualified identifiers are rejected.

**Example:**

```ocaml
module UserSchema = struct
  let table     = "users"
  let id_column = "id"
  let columns   = ["id"; "name"; "email"]
  type t  = { id : int; name : string; email : string }
  type id = int
  let row_type =
    Caqti_type.(custom
      ~encode:(fun u -> Ok (u.id, u.name, u.email))
      ~decode:(fun (id, name, email) -> Ok { id; name; email })
      (t3 int string string))
  let id_type = Caqti_type.int
  let get_id u = u.id
end

module Users = Table.Make(UserSchema)

let _ = Users.insert pool { id = 1; name = "Alice"; email = "alice@example.com" }
let _ = Users.find   pool 1
let _ = Users.list   pool ~limit:10 ()
let _ = Users.delete pool 1
```

---

## Configuration

| Parameter      | Type     | Default | Description                          |
|----------------|----------|---------|--------------------------------------|
| `url`          | `string` | —       | PostgreSQL connection URL             |
| `pool_size`    | `int`    | caqti default (10) | Max connections in pool  |
| `sw`           | `Eio.Switch.t` | — | Pool lifetime tied to switch         |
| `stdenv`       | `Caqti_eio.stdenv` | — | Coerce from full env with `:>` |

`Caqti_eio.stdenv` requires `< net; clock; mono_clock >`. Coerce from the full Eio env with `(env :> Caqti_eio.stdenv)`.

---

## Local Development

```bash
bash platform/local/scripts/ensure-postgres.sh
export POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sun_dev
dune test integrations/storage/ --force
```

The script starts `postgres:16-alpine` in Docker on port 5432 and waits for `pg_isready`.

---

## Dependencies

```
uri
caqti
caqti-eio
caqti-eio.unix      ← required for C-binding drivers (postgresql); plain caqti-eio only has pgx
caqti-driver-postgresql
```

---

## Out of Scope (v1)

- Update/upsert helpers (use `Db.exec` with a hand-written query)
- Query builder / DSL
- Multiple database backends (PostgreSQL is Sun's opinionated default)
