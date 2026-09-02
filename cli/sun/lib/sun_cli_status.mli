(* Workspace-level status rollup for 'sun status' (OBS-009). *)

type domain_status = Healthy | Degraded | Not_deployed

(** [rollup_domain_status ~ns_exists diagnoses] aggregates one domain's
    per-service diagnoses (as returned by
    [Sun_cli_rollout_diagnosis.diagnose_service_live] -- [None] means
    healthy, [Some _] means that service's rollout failed) into a single
    domain-level status:
    - [Not_deployed] when the namespace doesn't exist.
    - [Degraded] when the namespace exists and any service is unhealthy.
    - [Healthy] when the namespace exists and every service is healthy. *)
val rollup_domain_status : ns_exists:bool -> string option list -> domain_status

(** Display label. Non-healthy states are upper-cased so they stand out in
    plain-text output without needing ANSI colors. *)
val domain_status_to_string : domain_status -> string

(* Observability reachability (OBS-018). *)

type reachability = Healthy | Unreachable | Not_checked

val reachability_to_string : reachability -> string

(** [probe_url ~backend ~explicit_url ~default_local_url ~probe_path]
    decides which URL, if any, is safe to check: [explicit_url] always
    wins; otherwise only [Local]'s hardcoded default is meaningful to
    guess at -- [None] ("don't check") for any other backend. *)
val probe_url
  :  backend:Sun_cli_observability_url.backend
  -> explicit_url:string option
  -> default_local_url:string
  -> probe_path:string
  -> string option

(** [reachability_of_probe ~probe_url ~is_reachable] classifies the result
    of [probe_url]: [Not_checked] when there's nothing to check, otherwise
    [is_reachable url ? Healthy : Unreachable]. *)
val reachability_of_probe
  :  probe_url:string option
  -> is_reachable:(string -> bool)
  -> reachability
