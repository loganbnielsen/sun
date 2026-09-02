(* Backend-aware observability UI URL resolution (OBS-012). One resolver,
   used by sun logs/sun open/sun status's "Open" hints alike, instead of
   each command inventing its own flag and default. *)

type backend = Local | Self_hosted_durable | External

val backend_of_string : string -> backend option
val backend_to_string : backend -> string

type resolution =
  | Url of string
  | No_url of string
  (** [No_url reason] — there is nothing safe to link to; [reason] is a
      short, printable explanation for the caller to show the user instead
      of a broken/guessed link. *)

(** [resolve ~backend ?base_domain ?override ()] resolves the base
    observability UI URL for [backend].
    - [override], when given, always wins (e.g. sun logs's
      [--grafana-base-url] flag) -- the resolver is a default, not a lock.
    - [Local] defaults to ["http://localhost:3000"].
    - [Self_hosted_durable] resolves to ["https://grafana.<base_domain>"],
      matching platform/infra/base's Grafana Ingress -- requires
      [base_domain].
    - [External] never guesses: returns [No_url _]. *)
val resolve
  :  backend:backend
  -> ?base_domain:string
  -> ?override:string
  -> unit
  -> resolution
