type infra_requirements = {
  kafka      : bool;
  postgres   : bool;
  loki       : bool;
  prometheus : bool;
}

val scan : dir:string -> infra_requirements
(** Walk all [dune] files under [dir] and detect which Sun infrastructure
    libraries the workspace depends on. Used by [sun dev up] to start exactly
    the infra the workspace needs. *)
