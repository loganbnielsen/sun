(* Pure parsing/summarizing of kubectl pod + event JSON for 'sun status'
   rollout diagnosis. No I/O — callers fetch JSON via Sun_cli_kubectl. *)

type container_state =
  | Waiting     of { reason : string; message : string option }
  | Running
  | Terminated  of { reason : string; exit_code : int; message : string option }
  | Unknown_state

type pod_status = {
  name                    : string;
  phase                   : string;
  ready                   : bool;
  restarts                : int;
  image                   : string option;
  state                   : container_state;
  last_terminated_reason  : string option;
}

type event = {
  ev_type        : string;
  reason         : string;
  message        : string;
  count          : int;
  last_timestamp : string option;
  involved_name  : string;
}

(** Parse the output of [kubectl get pods -n <ns> -l <selector> -o json]. *)
val parse_pods_json : string -> pod_status list

(** Parse the output of [kubectl get events -n <ns> -o json]. *)
val parse_events_json : string -> event list

(** Most recent [limit] events (default 5) involving the given pod name,
    newest first. *)
val events_for_pod : ?limit:int -> pod_name:string -> event list -> event list

(** A pod is healthy when it is Running, ready, and its container state is
    also Running (not stuck Waiting/Terminated with a stale ready flag). *)
val is_healthy : pod_status -> bool

(** Which health model a service follows. Kept local to this module
    rather than taking [Sun_cli_manifest.primitive] directly, so rollout
    diagnosis doesn't couple to manifest concepts -- callers translate
    from primitive to this. *)
type pod_expectation =
  | Continuous
  (** Deployment/Rollout-backed (Svc, Worker): a pod should always be
      running; zero pods, or a pod that isn't [is_healthy], is a finding.
      Diagnosed from the live pod list ([format_service_diagnosis]). *)
  | Ephemeral
  (** CronJob-backed (Fn): there's no stable pod to inspect between runs,
      and several historical run pods can coexist
      (successfulJobsHistoryLimit/failedJobsHistoryLimit) with no
      reliable way to tell, from pod state alone, whether an old failure
      has since been superseded by a newer success -- pod-list
      inspection is the wrong data source for this primitive. Diagnosed
      instead from the CronJob's own status fields
      ([format_cronjob_diagnosis]). *)

(** Render one pod's diagnosis block: state/reason, restarts, last
    termination reason, image, and recent events. *)
val format_pod_diagnosis : pod_status -> event list -> string

(** [format_service_diagnosis ~service_name pods events] returns [None]
    when every pod is [is_healthy], or a rendered "<service_name> rollout
    failed" block otherwise -- covering every unhealthy pod, or, when
    [pods] is empty, a "no pods found for this service" finding
    (OBS-024): an empty pod list for a namespace that exists means the
    service never started. [Continuous] only -- see
    [format_cronjob_diagnosis] for [Ephemeral]. Only pass a confirmed pod
    list here (see [fetch_pod_statuses]) -- an empty list always reads as
    "confirmed zero pods," never "couldn't check." *)
val format_service_diagnosis
  :  service_name:string
  -> pod_status list
  -> event list
  -> string option

(** A CronJob's own status, as Kubernetes tracks it -- the authoritative
    source for "did the most recently scheduled run succeed," which pod
    inspection can't answer reliably once more than one historical pod is
    retained (OBS-026). *)
type cronjob_status = {
  last_schedule_time    : string option;
  last_successful_time  : string option;
  active_count          : int;
  (** Number of currently-running Jobs for this CronJob. *)
}

(** Parse the output of [kubectl get cronjob <name> -n <ns> -o json].
    [None] only on a JSON parse failure -- a CronJob with no [status] at
    all yet (e.g. brand new) parses to [Some] with every field at its
    "never happened" default, not [None]. *)
val parse_cronjob_status : string -> cronjob_status option

(** Result of trying to fetch a CronJob's status -- distinguishes "the
    resource genuinely doesn't exist" from "the kubectl call itself
    failed" (OBS-026): conflating the two into one [None] used to mean a
    declared [Fn] whose CronJob was never actually created (deploy failed
    partway, or it was deleted) reported healthy with no diagnosis. *)
type cronjob_fetch_result =
  | Found of cronjob_status
  | Missing
  (** Confirmed via kubectl's own NotFound response -- not a transient
      failure. *)
  | Unavailable
  (** The kubectl call itself failed, or its output couldn't be parsed
      (transient error, timeout, RBAC, ...) -- stays silent, same as
      other transient-failure handling in this module. *)

(** [format_cronjob_diagnosis ~service_name result] is the [Ephemeral]
    counterpart to [format_service_diagnosis]:
    - [Unavailable]: [None] -- couldn't check, stays silent.
    - [Missing]: always a finding -- a declared service with no backing
      CronJob at all is exactly the kind of failure this diagnosis exists
      to catch.
    - [Found status]: [None] when no run has been scheduled yet, a run is
      currently active (Sun's CronJobs set `backoffLimit: 3`, so a run
      stuck failing terminates within a few retries rather than staying
      active indefinitely), or the most recently scheduled run has a
      later-or-equal successful completion recorded; a rendered finding
      otherwise -- the most recently scheduled run hasn't (yet, or ever)
      completed successfully. *)
val format_cronjob_diagnosis : service_name:string -> cronjob_fetch_result -> string option

(** [kubectl get events -n <ns> -o json], parsed. Empty list on any kubectl
    failure — diagnosis degrades gracefully rather than erroring. *)
val fetch_namespace_events : ns:string -> event list

(** [kubectl get pods -n <ns> -l app=<k8s_name> -o json], parsed. [None] if
    the kubectl call itself failed (transient error, timeout, ...) --
    distinct from [Some []], a confirmed zero pods. *)
val fetch_pod_statuses : ns:string -> k8s_name:string -> pod_status list option

(** [kubectl get cronjob <k8s_name> -n <ns> -o json], parsed into a
    [cronjob_fetch_result] that distinguishes a confirmed-missing
    resource from an unavailable/unparseable one. *)
val fetch_cronjob_status : ns:string -> k8s_name:string -> cronjob_fetch_result

(** Live, I/O-performing diagnosis, dispatching on [pod_expectation]:
    [Continuous] fetches pods and events and calls
    [format_service_diagnosis]; [Ephemeral] fetches CronJob status and
    calls [format_cronjob_diagnosis]. [None] both when the target is OK
    and when the underlying kubectl fetch itself failed -- a transient
    kubectl failure stays silent rather than being reported as a
    finding. *)
val diagnose_service_live
  :  pod_expectation:pod_expectation
  -> ns:string
  -> service_name:string
  -> k8s_name:string
  -> unit
  -> string option
