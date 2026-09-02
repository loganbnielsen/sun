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

val find_root : dir:string -> string option
(** Walk up from [dir] (inclusive) looking for the nearest ancestor
    containing an [app/] subdirectory -- Sun's workspace-root marker,
    already used by [discover_services]/[discover_domains]. Returns [None]
    when no such ancestor exists (e.g. before [sun new]'s first scaffold),
    so callers can fall back to today's behavior rather than erroring.
    Used by [main.ml] to make every [sun] command deterministic from any
    directory inside the workspace, not just the root. *)
