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
