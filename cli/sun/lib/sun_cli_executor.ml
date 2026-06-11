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
  { namespace = spec.namespace; name = spec.k8s_name; image = spec.image }

(* ── executors ───────────────────────────────────────────────────────────── *)

let local ~dry_run spec =
  let yaml = Sun_cli_deployment_plan.render_spec spec in
  Sun_cli_manifest.apply yaml ~dry_run;
  make_result spec

let direct ~dry_run spec =
  let yaml = Sun_cli_deployment_plan.render_spec spec in
  Sun_cli_manifest.apply yaml ~dry_run;
  make_result spec

let gitops ~dir ?(secret_backend = Sun_cli_manifest.Kubernetes_placeholder) spec =
  let yaml = Sun_cli_deployment_plan.render_spec ~secret_backend spec in
  let _path = Sun_cli_manifest.emit_to_dir dir yaml
    ~ns:spec.namespace ~name:spec.k8s_name in
  make_result spec
