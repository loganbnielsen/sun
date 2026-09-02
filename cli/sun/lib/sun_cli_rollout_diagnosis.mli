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

(** Which pod-count/lifecycle model a service follows. Kept local to this
    module rather than taking [Sun_cli_manifest.primitive] directly, so
    rollout diagnosis doesn't couple to manifest concepts -- callers
    translate from primitive to this. *)
type pod_expectation =
  | Continuous
  (** Deployment/Rollout-backed (Svc, Worker): a pod should always be
      running; zero pods, or a pod that isn't [is_healthy], is a finding. *)
  | Ephemeral
  (** CronJob-backed (Fn): no pod at all between scheduled runs is the
      expected resting state, and a pod that ran to completion
      successfully (phase "Succeeded") is not a failure either -- only an
      active pod that isn't healthy and hasn't completed is a finding. *)

(** [true] when [p] ran to completion successfully (Kubernetes pod phase
    "Succeeded") -- exposed for [Ephemeral] callers that want to
    distinguish this from an active/failed pod directly. *)
val is_successfully_completed : pod_status -> bool

(** Render one pod's diagnosis block: state/reason, restarts, last
    termination reason, image, and recent events. *)
val format_pod_diagnosis : pod_status -> event list -> string

(** [format_service_diagnosis ?pod_expectation ~service_name pods events]
    returns [None] when every pod is OK for [pod_expectation] (default
    [Continuous]), or a rendered "<service_name> rollout failed" block
    otherwise:
    - [Continuous]: any pod that isn't [is_healthy] is a finding,
      including an empty pod list (OBS-024) -- a namespace that exists
      with no pod means the service never started.
    - [Ephemeral]: an empty pod list is not a finding (idle between runs
      is expected), and a pod is only a finding when it's neither
      [is_healthy] nor [is_successfully_completed] (OBS-026) -- a
      scheduled run that finished successfully isn't a failure either.
    Only pass a confirmed pod list here (see [fetch_pod_statuses]) -- an
    empty list always reads as "confirmed zero pods," never "couldn't
    check." *)
val format_service_diagnosis
  :  ?pod_expectation:pod_expectation
  -> service_name:string
  -> pod_status list
  -> event list
  -> string option

(** [kubectl get events -n <ns> -o json], parsed. Empty list on any kubectl
    failure — diagnosis degrades gracefully rather than erroring. *)
val fetch_namespace_events : ns:string -> event list

(** [kubectl get pods -n <ns> -l app=<k8s_name> -o json], parsed. [None] if
    the kubectl call itself failed (transient error, timeout, ...) --
    distinct from [Some []], a confirmed zero pods. *)
val fetch_pod_statuses : ns:string -> k8s_name:string -> pod_status list option

(** Live, I/O-performing version of [format_service_diagnosis]: fetches pods
    and events for the given service and returns its diagnosis, if any.
    [None] both when every pod is OK and when the pod fetch itself
    failed -- a transient kubectl failure stays silent rather than being
    reported as "no pods found." [?pod_expectation] is forwarded to
    [format_service_diagnosis]. *)
val diagnose_service_live
  :  ?pod_expectation:pod_expectation
  -> ns:string
  -> service_name:string
  -> k8s_name:string
  -> unit
  -> string option
