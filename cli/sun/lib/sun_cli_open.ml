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
   at workspace scope, the service template (with $domain/$service preset
   via query params) once scoped. 'metrics' and 'dashboard' share this
   target -- OBS-011 provisions one dashboard per scope covering both,
   there's no separate metrics-only dashboard to link to. *)
let dashboard_url ~base_url scope =
  match scope with
  | Workspace -> base_url ^ "/d/sun-workspace-overview"
  | Domain domain ->
    Printf.sprintf "%s/d/sun-service-template?var-domain=%s" base_url domain
  | Service (domain, service) ->
    Printf.sprintf "%s/d/sun-service-template?var-domain=%s&var-service=%s"
      base_url domain service

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
  | Metrics | Dashboard -> Ok (dashboard_url ~base_url scope)
