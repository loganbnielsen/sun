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

(** [format_service_diagnosis ~service_name pods events] returns [None] when
    every pod is healthy, or a rendered "<service_name> rollout failed" block
    covering every unhealthy pod otherwise. *)
val format_service_diagnosis : service_name:string -> pod_status list -> event list -> string option

(** [kubectl get events -n <ns> -o json], parsed. Empty list on any kubectl
    failure — diagnosis degrades gracefully rather than erroring. *)
val fetch_namespace_events : ns:string -> event list

(** [kubectl get pods -n <ns> -l app=<k8s_name> -o json], parsed. *)
val fetch_pod_statuses : ns:string -> k8s_name:string -> pod_status list

(** Live, I/O-performing version of [format_service_diagnosis]: fetches pods
    and events for the given service and returns its diagnosis, if any. *)
val diagnose_service_live : ns:string -> service_name:string -> k8s_name:string -> string option
