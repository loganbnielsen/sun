type infra_requirements = {
  kafka      : bool;
  postgres   : bool;
  loki       : bool;
  prometheus : bool;
}

val pending_migration_count : dir:string -> int
(** Count [.sql] files in [dir/db/migrations].  Returns 0 if the directory
    does not exist.  Used by [sun up] to warn users about unapplied migrations. *)

val scan : dir:string -> infra_requirements
(** Walk all [dune] files under [dir] and detect which Sun infrastructure
    libraries the workspace depends on. Used by [sun dev up] to start exactly
    the infra the workspace needs. *)
