(* Workspace-level status rollup for 'sun status' (OBS-009). Pure
   aggregation of diagnosis OBS-001 already computes -- no new diagnosis
   logic here. *)

type domain_status = Healthy | Degraded | Not_deployed

let rollup_domain_status ~ns_exists (diagnoses : string option list) =
  if not ns_exists then Not_deployed
  else if List.exists (fun d -> d <> None) diagnoses then Degraded
  else Healthy

let domain_status_to_string = function
  | Healthy -> "healthy"
  | Degraded -> "DEGRADED"
  | Not_deployed -> "NOT DEPLOYED"

(* Observability reachability (OBS-018). Split into a pure decision
   (which URL, if any, to probe) and a pure classification (given whether
   that URL answered), so both are testable without a real curl call --
   the actual I/O stays in cmd_status.ml. *)

type reachability = Healthy | Unreachable | Not_checked

let reachability_to_string = function
  | Healthy -> "healthy"
  | Unreachable -> "unreachable"
  | Not_checked -> "not checked"

(** [probe_url ~backend ~explicit_url ~default_local_url ~probe_path]
    decides which URL, if any, is safe to check:
    - [explicit_url], when given, always wins.
    - Otherwise, only the [Local] backend's hardcoded default is
      meaningful to guess at -- [Self_hosted_durable]/[External] have no
      equivalent default Loki/Prometheus URL shape, so [None] ("don't
      check") rather than a misleading guess. *)
let probe_url ~backend ~explicit_url ~default_local_url ~probe_path =
  match explicit_url with
  | Some base -> Some (base ^ probe_path)
  | None ->
    (match (backend : Sun_cli_observability_url.backend) with
     | Local -> Some (default_local_url ^ probe_path)
     | Self_hosted_durable | External -> None)

(** [reachability_of_probe ~probe_url ~is_reachable] classifies the result
    of [probe_url] (from [probe_url] above, or a resolved Grafana URL for
    the dashboard line): [Not_checked] when there's no URL to check,
    otherwise [is_reachable url ? Healthy : Unreachable]. *)
let reachability_of_probe ~probe_url ~is_reachable =
  match probe_url with
  | None -> Not_checked
  | Some url -> if is_reachable url then Healthy else Unreachable

(* Service-existence decision (OBS-022/024). Pulled out of cmd_status.ml's
   inline check so it's directly unit-tested -- discovering the declared
   k8s names themselves still requires a filesystem scan
   (Sun_cli_manifest.discover_services), so that part stays in
   cmd_status.ml; this is just the pure "is it in the set" decision. *)
let service_is_declared ~k8s_name declared_k8s_names =
  List.mem k8s_name declared_k8s_names
