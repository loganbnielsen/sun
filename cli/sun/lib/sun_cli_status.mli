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
