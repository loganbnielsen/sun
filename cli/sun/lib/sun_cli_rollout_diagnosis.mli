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
    from primitive to this.
    - [Continuous] (Svc, Worker): a pod should always be running;
      diagnosed from the live pod list ([format_service_diagnosis]).
    - [Ephemeral] (Fn): several historical run pods can coexist with no
      reliable way to tell which is "the latest" from pod state alone;
      diagnosed instead from the CronJob's own status
      ([format_cronjob_diagnosis]), which only covers its last
      *completed* run -- an in-progress run's pod health isn't inspected. *)
type pod_expectation = Continuous | Ephemeral

(** Render one pod's diagnosis block: state/reason, restarts, last
    termination reason, image, and recent events. *)
val format_pod_diagnosis : pod_status -> event list -> string

(** [Continuous] diagnosis: [None] when every pod is [is_healthy] or
    (OBS-024) when [pods] is empty for a namespace that exists (a
    declared service with no pod at all means it never started); a
    rendered "<service_name> rollout failed" finding otherwise. Pass a
    confirmed pod list only -- an empty list always reads as "confirmed
    zero pods," never "couldn't check." *)
val format_service_diagnosis
  :  service_name:string
  -> pod_status list
  -> event list
  -> string option

(** A CronJob's own status -- the authoritative source for "did the most
    recently scheduled run succeed," which pod inspection can't answer
    reliably once more than one historical pod is retained (OBS-026). *)
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

(** Distinguishes "the CronJob genuinely doesn't exist" ([Missing],
    confirmed via kubectl's NotFound response) from "the kubectl call
    itself failed or its output couldn't be parsed" ([Unavailable],
    transient -- stays silent). Conflating the two used to mean a
    declared [Fn] whose CronJob was never created reported healthy with
    no diagnosis at all (OBS-026). *)
type cronjob_fetch_result =
  | Found of cronjob_status
  | Missing
  | Unavailable

(** [Ephemeral] counterpart to [format_service_diagnosis]: [Unavailable]
    is [None]; [Missing] is always a finding; [Found status] is [None]
    when no run has been scheduled yet, a run is currently active (not
    inspected further -- see [pod_expectation]), or the most recently
    scheduled run has a later-or-equal successful completion recorded,
    and a finding otherwise. *)
val format_cronjob_diagnosis : service_name:string -> cronjob_fetch_result -> string option

(** Live, I/O-performing diagnosis, dispatching on [pod_expectation]:
    [Continuous] fetches pods+events and calls
    [format_service_diagnosis]; [Ephemeral] fetches CronJob status and
    calls [format_cronjob_diagnosis]. [None] both when the target is OK
    and when the underlying kubectl fetch itself failed. *)
val diagnose_service_live
  :  pod_expectation:pod_expectation
  -> ns:string
  -> service_name:string
  -> k8s_name:string
  -> unit
  -> string option
