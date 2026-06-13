type status = {
  version    : int;
  name       : string;
  applied_at : string option; (** None if not yet applied *)
}

(** [split_statements sql] splits [sql] into individual statements using a
    PostgreSQL-aware lexer.  Semicolons inside single-quoted strings, line
    comments, block comments, and dollar-quoted bodies are not treated as
    statement terminators.  Each returned string is trimmed and ends with a
    semicolon.  Exposed for testing. *)
val split_statements : string -> string list

(** [apply pool ~dir] applies all pending SQL migrations from [dir].
    Migrations are files named [NNNN_description.sql] (e.g. [0001_init.sql]).
    Each file is executed in a transaction; the applied version is recorded in
    the migrations tracking table (default: [sun_schema_migrations]).

    Pass [~table] to use a per-workspace table, avoiding version-number
    collisions when multiple workspaces share the same database in development. *)
val apply
  :  ?table:string
  -> Db.pool
  -> dir:string
  -> (unit, Storage_error.t) result

(** [status pool ~dir] returns one entry per migration file, showing whether
    each version has been applied and when. Pass [~table] to match the table
    used in [apply]. *)
val status
  :  ?table:string
  -> Db.pool
  -> dir:string
  -> (status list, Storage_error.t) result

(** [rollback pool ~dir] rolls back the last applied migration by running the
    companion [NNNN_name.down.sql] file and removing the version record from the
    tracking table.  Fails with an error if no migrations are applied or if the
    down-migration file does not exist.  Pass [~table] to match the table used
    in [apply]. *)
val rollback
  :  ?table:string
  -> Db.pool
  -> dir:string
  -> (unit, Storage_error.t) result
