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

(** Render one pod's diagnosis block: state/reason, restarts, last
    termination reason, image, and recent events. *)
val format_pod_diagnosis : pod_status -> event list -> string

(** [format_service_diagnosis ?expects_continuous_pods ~service_name pods
    events] returns [None] when every pod is healthy, or a rendered
    "<service_name> rollout failed" block otherwise -- covering every
    unhealthy pod, or, when [pods] is empty *and* [expects_continuous_pods]
    (default [true]), a "no pods found for this service" finding
    (OBS-024): an empty pod list for a namespace that exists means the
    service never started, which this diagnosis exists to catch.
    [expects_continuous_pods:false] is for primitives that are normally
    idle between runs (Fn/CronJob) -- an empty pod list there is the
    expected resting state, not a failure. Only pass a confirmed pod list
    here (see [fetch_pod_statuses]) -- an empty list always reads as
    "confirmed zero pods," never "couldn't check." *)
val format_service_diagnosis
  :  ?expects_continuous_pods:bool
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
    [None] both when every pod is healthy and when the pod fetch itself
    failed -- a transient kubectl failure stays silent rather than being
    reported as "no pods found." [?expects_continuous_pods] is forwarded
    to [format_service_diagnosis]. *)
val diagnose_service_live
  :  ?expects_continuous_pods:bool
  -> ns:string
  -> service_name:string
  -> k8s_name:string
  -> unit
  -> string option
