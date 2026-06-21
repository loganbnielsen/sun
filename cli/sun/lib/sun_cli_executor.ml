(* Deployment executors — plan-in, side-effect-out.
   Each executor renders a service_spec to YAML and dispatches to the
   appropriate Sun_cli_manifest primitive. *)

type result = {
  namespace : string;
  name      : string;
  image     : string;
}

(* ── helpers ─────────────────────────────────────────────────────────────── *)

let make_result (spec : Sun_cli_deployment_plan.service_spec) =
  { namespace = Sun_cli_deployment_plan.namespace_to_string spec.namespace;
    name = Sun_cli_deployment_plan.k8s_name_to_string spec.k8s_name;
    image = spec.image }

(* ── executors ───────────────────────────────────────────────────────────── *)

let local ~dry_run spec =
  match Sun_cli_deployment_plan.render_spec spec with
  | Error msg -> failwith msg
  | Ok yaml ->
    Sun_cli_manifest.apply yaml ~dry_run;
    make_result spec

let direct ~dry_run spec =
  match Sun_cli_deployment_plan.render_spec spec with
  | Error msg -> failwith msg
  | Ok yaml ->
    Sun_cli_manifest.apply yaml ~dry_run;
    make_result spec

let gitops ~dir ?(secret_backend = Sun_cli_manifest.Kubernetes_placeholder) spec =
  match Sun_cli_deployment_plan.render_spec ~secret_backend spec with
  | Error msg -> failwith msg
  | Ok yaml ->
    let ns = Sun_cli_deployment_plan.namespace_to_string spec.namespace in
    let name = Sun_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
    let _path = Sun_cli_manifest.emit_to_dir dir yaml
      ~ns ~name in
    make_result spec
