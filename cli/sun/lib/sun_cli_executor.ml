(* Deployment executors — plan-in, side-effect-out.
   Each executor renders a service_spec to YAML and dispatches to the
   appropriate Sun_cli_manifest primitive. *)

type result = {
  namespace : string;
  name      : string;
  image     : string;
}

type mode = Dry_run | Emit_to of string | Apply

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


let gitops ~dir ?(secret_backend = Sun_cli_manifest.Kubernetes_placeholder) spec =
  match Sun_cli_deployment_plan.render_spec ~secret_backend spec with
  | Error msg -> failwith msg
  | Ok yaml ->
    let ns = Sun_cli_deployment_plan.namespace_to_string spec.namespace in
    let name = Sun_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
    let _path = Sun_cli_manifest.emit_to_dir dir yaml
      ~ns ~name in
    make_result spec

(* ── plan-level executor ─────────────────────────────────────────────────── *)

let run_plan ~mode ?(secret_backend = Sun_cli_manifest.Kubernetes_placeholder) plan =
  let backend = match mode with
    | Emit_to _ -> Sun_cli_manifest.Kubernetes_placeholder
    | Dry_run | Apply -> secret_backend
  in
  (* Render all specs upfront; surface the first error before any side effect. *)
  let rendered = List.map
    (fun spec -> match Sun_cli_deployment_plan.render_spec ~secret_backend:backend spec with
      | Error msg -> Error (spec, msg)
      | Ok yaml   -> Ok (spec, yaml))
    plan.Sun_cli_deployment_plan.services
  in
  match List.find_opt (function Error _ -> true | Ok _ -> false) rendered with
  | Some (Error (_, msg)) -> Error msg
  | _ ->
    let pairs = List.filter_map (function Ok x -> Some x | Error _ -> None) rendered in
    Ok (List.map (fun ((spec : Sun_cli_deployment_plan.service_spec), yaml) ->
      (match mode with
       | Dry_run    -> Sun_cli_manifest.apply yaml ~dry_run:true
       | Emit_to dir ->
         let ns   = Sun_cli_deployment_plan.namespace_to_string spec.namespace in
         let name = Sun_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
         ignore (Sun_cli_manifest.emit_to_dir dir yaml ~ns ~name)
       | Apply      -> Sun_cli_manifest.apply yaml ~dry_run:false);
      make_result spec
    ) pairs)
