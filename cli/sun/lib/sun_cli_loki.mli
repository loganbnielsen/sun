(* Minimal Loki query client for 'sun logs'. Shells out to curl rather than
   adding an HTTP library, matching how this CLI already wraps
   kubectl/docker/helm/terraform. *)

type line = { ts_ns : string; text : string }

(** Build the curl argv for a Loki range query over
    [{namespace="<ns>",app="<k8s_name>"}]. Exposed for testing. *)
val query_range_argv
  :  base_url:string -> ns:string -> k8s_name:string
  -> limit:int -> timeout_s:float -> string list

(** Split curl's ["<body>\n<http_code>"] output (produced by [-w
    '\n%{http_code}']) back into the body and the parsed status code. *)
val split_body_and_status : string -> string * int option

(** Parse a Loki [/loki/api/v1/query_range] JSON response body into log
    lines, oldest first. *)
val parse_query_range_body : string -> (line list, string) result

type fetch_error =
  | Timeout
  | Connection_failed
  | Http_error of int
  | Other of string

val fetch_error_to_string : fetch_error -> string

(** Classify a [Sun_cli_process] failure from running curl into a
    [fetch_error], distinguishing timeouts and connection failures from
    other curl errors. *)
val classify_process_error : Sun_cli_process.error -> fetch_error

(** Query Loki for recent log lines for a service. Returns [Ok []] when the
    query succeeds but finds nothing (a legitimate state, e.g. no pod-level
    log shipping configured yet — not treated as a Loki failure). *)
val query
  :  base_url:string -> ns:string -> k8s_name:string
  -> ?limit:int -> ?timeout_s:float -> unit -> (line list, fetch_error) result
