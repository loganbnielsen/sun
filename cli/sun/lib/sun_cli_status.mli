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

(** [service_is_declared ~k8s_name declared_k8s_names] is [true] when
    [k8s_name] is one of [declared_k8s_names] -- the pure decision behind
    `sun status <domain>/<service>` rejecting an undeclared service
    (OBS-022). Discovering [declared_k8s_names] itself is a filesystem
    scan and stays in [cmd_status.ml]; this is just the set-membership
    check, pulled out so it's directly testable. *)
val service_is_declared : k8s_name:string -> string list -> bool

(** Which health model a declared service's primitive implies: [Fn] is
    [Ephemeral] (CronJob-status diagnosis), [Svc]/[Worker] are
    [Continuous] (live-pod diagnosis). Swapping this mapping would
    silently reintroduce the OBS-024/026 regression (a zero-pod Fn
    reported as failed), so it's pulled out of `cmd_status.ml` to be
    directly unit-tested rather than left as untested glue. *)
val pod_expectation_of_primitive
  :  Sun_cli_manifest.primitive
  -> Sun_cli_rollout_diagnosis.pod_expectation
