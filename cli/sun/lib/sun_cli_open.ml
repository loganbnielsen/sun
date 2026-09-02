(* URL construction for 'sun open logs|metrics|dashboard' (OBS-010).
   Pure functions here so scope parsing and URL building can be unit-tested
   without a live Grafana instance. *)

type scope =
  | Workspace
  | Domain of string
  | Service of string * string

type kind = Logs | Metrics | Dashboard

let parse_scope = function
  | None -> Ok Workspace
  | Some s ->
    (match String.split_on_char '/' s with
     | [domain] -> Ok (Domain domain)
     | [domain; service] -> Ok (Service (domain, service))
     | _ -> Error (Printf.sprintf "scope must be 'domain' or 'domain/service', got %S" s))

(* Deep-links into OBS-011's provisioned dashboards: the workspace overview
   at workspace scope, the service template (with $workspace/$domain/
   $service preset via query params) once scoped. 'metrics' and
   'dashboard' share this target -- OBS-011 provisions one dashboard per
   scope covering both, there's no separate metrics-only dashboard to
   link to.

   $workspace/$domain/$service are matched against the actual label
   values. service always matches (both this and manifest rendering use
   k8s_name_result). workspace/domain must go through the exact same
   sanitizer manifest rendering uses (Sun_cli_kubernetes_name
   .sanitize_label_value, not the narrower [normalize]) -- two different
   transforms for the same conceptual value is exactly how a rendered
   label and this dashboard link's query param end up disagreeing
   (OBS-021), so the dashboard opens empty. $workspace matters most once a
   Prometheus/Grafana instance is shared across more than one Sun
   workspace (OBS-020): without it, two workspaces using the same domain
   name would blend in these dashboards. *)
let dashboard_url ~base_url ~workspace scope =
  let workspace = Sun_cli_kubernetes_name.sanitize_label_value workspace in
  match scope with
  | Workspace ->
    Ok (Printf.sprintf "%s/d/sun-workspace-overview?var-workspace=%s" base_url workspace)
  | Domain domain ->
    let domain = Sun_cli_kubernetes_name.sanitize_label_value domain in
    Ok (Printf.sprintf "%s/d/sun-service-template?var-workspace=%s&var-domain=%s"
          base_url workspace domain)
  | Service (domain, service) ->
    let domain = Sun_cli_kubernetes_name.sanitize_label_value domain in
    (match Sun_cli_deployment_plan.k8s_name_result service with
     | Error e -> Error (Sun_cli_deployment_plan.plan_error_to_string e)
     | Ok k8s_name ->
       let service = Sun_cli_deployment_plan.k8s_name_to_string k8s_name in
       Ok (Printf.sprintf "%s/d/sun-service-template?var-workspace=%s&var-domain=%s&var-service=%s"
             base_url workspace domain service))

let logs_url ~base_url ~workspace scope =
  match scope with
  | Workspace ->
    Ok (Sun_cli_logs.explore_url ~base_url
          ~logql:(Printf.sprintf {|{namespace=~"%s-.+"}|} workspace))
  | Domain domain ->
    (match Sun_cli_deployment_plan.namespace_result ~workspace ~domain with
     | Error e -> Error (Sun_cli_deployment_plan.plan_error_to_string e)
     | Ok ns ->
       let ns = Sun_cli_deployment_plan.namespace_to_string ns in
       Ok (Sun_cli_logs.explore_url ~base_url ~logql:(Printf.sprintf {|{namespace="%s"}|} ns)))
  | Service (domain, name) ->
    (match Sun_cli_deployment_plan.namespace_result ~workspace ~domain,
           Sun_cli_deployment_plan.k8s_name_result name with
     | Error e, _ | _, Error e -> Error (Sun_cli_deployment_plan.plan_error_to_string e)
     | Ok ns, Ok k8s_name ->
       let ns = Sun_cli_deployment_plan.namespace_to_string ns in
       let k8s_name = Sun_cli_deployment_plan.k8s_name_to_string k8s_name in
       Ok (Sun_cli_logs.grafana_explore_url ~base_url ~ns ~k8s_name))

let url ~base_url ~workspace ~kind scope =
  match kind with
  | Logs -> logs_url ~base_url ~workspace scope
  | Metrics | Dashboard -> dashboard_url ~base_url ~workspace scope
