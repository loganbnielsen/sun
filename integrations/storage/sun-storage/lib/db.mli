module Type    = Caqti_type
module Request = Caqti_request

(** Opaque connection pool. Create with [create_pool]; pass to query functions. *)
type pool

(** [create_pool ~url ~sw ~stdenv ()] opens a connection pool to the Postgres
    instance at [url] (e.g. ["postgresql://user:pass@localhost/mydb"]).
    The pool lives for the lifetime of [sw]. *)
val create_pool
  :  url:string
  -> ?pool_size:int
  -> sw:Eio.Switch.t
  -> stdenv:Caqti_eio.stdenv
  -> unit
  -> (pool, Storage_error.t) result

(** Execute a statement that returns no rows. *)
val exec
  :  pool
  -> ('p, unit, [< `Zero]) Caqti_request.t
  -> 'p
  -> (unit, Storage_error.t) result

(** Return zero or one row. *)
val find
  :  pool
  -> ('p, 'r, [< `Zero | `One]) Caqti_request.t
  -> 'p
  -> ('r option, Storage_error.t) result

(** Return all matching rows as a list. *)
val collect
  :  pool
  -> ('p, 'r, [< `Zero | `One | `Many]) Caqti_request.t
  -> 'p
  -> ('r list, Storage_error.t) result

(** Run [f] inside a database transaction. Commits on [Ok], rolls back on [Error]. *)
val transaction
  :  pool
  -> (pool -> ('a, Storage_error.t) result)
  -> ('a, Storage_error.t) result
