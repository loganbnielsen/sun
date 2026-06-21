(* sun deploy — CI/CD integration.
   Like sun up but skips the build step: images are already in a registry.
   Designed to run in CI after the build pipeline has pushed images. *)

open Cmdliner
open Sun_cli_manifest

let workspace_name () = Filename.basename (Sys.getcwd ())

let git_sha () =
  let tmp = Filename.temp_file "sun-" ".tmp" in
  ignore (Sys.command (Printf.sprintf "git rev-parse --short HEAD > %s 2>/dev/null" tmp));
  let ic = open_in tmp in
  let s = String.trim (In_channel.input_all ic) in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  if s = "" then "dev" else s

type run_config = {
  filter_path          : string option;
  dry_run              : bool;
  emit_to              : string option;
  emit_plan_to         : string option;
  image_tag            : string option;
  registry             : string option;
  secret_backend       : Sun_cli_manifest.secret_backend;
  confirm_group_change : bool;
}

let run cfg =
  let workspace = workspace_name () in
  let sha       = match cfg.image_tag with Some t -> t | None -> git_sha () in
  let services  = discover_services ~filter_path:cfg.filter_path in

  if services = [] then begin
    Printf.eprintf "No services found in app/ with a Dockerfile.\n";
    exit 1
  end;

  if not cfg.dry_run && cfg.emit_to = None then begin
    match Sys.getenv_opt "POSTGRES_URL" with
    | None | Some "" ->
      Printf.eprintf
        "error: POSTGRES_URL is not set.\n\
         Set it in your environment before running 'sun deploy':\n\
         \  export POSTGRES_URL=postgresql://user:pass@host:5432/dbname\n";
      exit 1
    | Some _ -> ()
  end;

  Printf.printf "\nWorkspace: %s  tag: %s\n" workspace sha;
  (match cfg.emit_to with
   | Some dir -> Printf.printf "emit-to: %s\n" dir
   | None when cfg.dry_run -> Printf.printf "(dry-run)\n"
   | None -> ());
  Printf.printf "\n%!";

  let reg = match cfg.registry with
    | Some r -> r
    | None   -> "sun-registry:5000"
  in
  let env =
    match Sun_cli_deployment_pipeline.resolve_customer_cloud
      ~registry:reg ~image_tag:sha ~workspace
      ~emit_to:cfg.emit_to
      ~secret_backend:cfg.secret_backend
    with
    | Ok env -> env
    | Error err ->
      Printf.eprintf "error: %s\n" (Sun_cli_deployment_pipeline.pipeline_error_to_string err);
      exit 1
  in
  let req : Sun_cli_deployment_pipeline.request = {
    workspace;
    image_tag            = sha;
    filter_path          = cfg.filter_path;
    emit_to              = cfg.emit_to;
    secret_backend       = cfg.secret_backend;
    confirm_group_change = cfg.confirm_group_change;
    dry_run              = cfg.dry_run;
  } in
  let plan =
    match Sun_cli_deployment_pipeline.build_plan req env services with
    | Ok plan -> plan
    | Error (Sun_cli_deployment_pipeline.Consumer_group_change { removed }) ->
      Printf.eprintf
        "\nwarning: the following consumer group(s) are no longer present in \
         this deploy plan:\n";
      List.iter (fun g -> Printf.eprintf "  - %s\n" g) removed;
      Printf.eprintf
        "\nMessages produced while the old group is absent will be consumed\n\
         from the latest offset when the group is re-added, silently skipping\n\
         any backlog.  Pass --confirm-group-change to acknowledge and proceed.\n\n";
      exit 1
    | Error err ->
      Printf.eprintf "error: %s\n" (Sun_cli_deployment_pipeline.pipeline_error_to_string err);
      exit 1
  in

  (match cfg.emit_plan_to with
   | None -> ()
   | Some path ->
     let json_str = Yojson.Safe.pretty_to_string (Sun_cli_deployment_plan.to_json plan) in
     if path = "-" then begin
       print_string json_str;
       print_char '\n'
     end else begin
       let oc = open_out path in
       output_string oc json_str;
       output_char oc '\n';
       close_out oc;
       Printf.printf "Plan written to %s\n%!" path
     end);

  let artifacts = Sun_cli_deployment_pipeline.render_artifacts
    ~secret_backend:cfg.secret_backend
    plan
  in

  (try
    List.iter (fun (artifact : Sun_cli_deployment_pipeline.artifact) ->
      let spec = artifact.spec in
      Printf.printf "[%s] %s/%s\n%!" (prim_label
        (match spec.primitive with
         | Sun_cli_deployment_plan.Svc    -> Svc
         | Sun_cli_deployment_plan.Worker -> Worker
         | Sun_cli_deployment_plan.Fn     -> Fn))
        spec.domain spec.source_name;

      (match cfg.emit_to with
       | Some dir ->
         let r = Sun_cli_deployment_pipeline.emit_artifact ~dir artifact in
         let path = Filename.concat dir
           (Printf.sprintf "%s-%s.yaml" r.Sun_cli_deployment_pipeline.namespace r.Sun_cli_deployment_pipeline.name) in
         Printf.printf "  ✓  %s\n%!" path
       | None ->
         let r = Sun_cli_deployment_pipeline.apply_artifact ~dry_run:cfg.dry_run artifact in
         if not cfg.dry_run then
           Printf.printf "  ✓  namespace %s  image %s\n\n%!"
             r.Sun_cli_deployment_pipeline.namespace r.Sun_cli_deployment_pipeline.image)

    ) artifacts
  with Deploy_failed msg ->
    Printf.eprintf "\nerror: %s\n" msg;
    exit 1);

  (match cfg.emit_to with
   | Some dir ->
     Printf.printf "\nManifests written to %s/\n" dir;
     Printf.printf "Commit and push to your GitOps repo, then Argo CD will apply them.\n"
   | None when not cfg.dry_run ->
     Printf.printf "\nDone. %d service(s) deployed.\n" (List.length services);
     Printf.printf "Run 'sun status' to check pod health.\n";
     Sun_cli_deployment_state.save_deployed_groups workspace plan.Sun_cli_deployment_plan.consumer_groups
   | None -> ())

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let path_arg =
  Arg.(value & pos 0 (some string) None &
       info [] ~docv:"PATH"
         ~doc:"Service path to deploy (default: all services in workspace)")

let dry_run_flag =
  Arg.(value & flag &
       info ["dry-run"]
         ~doc:"Print synthesized YAML to stdout without applying")

let emit_to_arg =
  Arg.(value & opt (some string) None &
       info ["emit-to"] ~docv:"DIR"
         ~doc:"Write YAML files to DIR instead of applying (GitOps mode). \
               One file per service: <namespace>-<name>.yaml")

let emit_plan_to_arg =
  Arg.(value & opt (some string) None &
       info ["emit-plan-to"] ~docv:"FILE"
         ~doc:"Write the deployment plan as JSON to FILE before executing. \
               Use '-' to print to stdout. Plan format is experimental.")

let image_tag_arg =
  Arg.(value & opt (some string) None &
       info ["image-tag"] ~docv:"TAG"
         ~doc:"Image tag to deploy (default: short git SHA). \
               In CI, pass the exact SHA built by the preceding job.")

let registry_arg =
  Arg.(value & opt (some string) None &
       info ["registry"] ~docv:"URL"
         ~doc:"Container registry prefix, e.g. \
               123456789.dkr.ecr.us-east-1.amazonaws.com. \
               Omit for local k3d cluster (uses sun-registry:5000).")

let secret_backend_arg =
  Arg.(value & opt string "kubernetes-placeholder" &
       info ["secret-backend"] ~docv:"BACKEND"
         ~doc:"Secret backend for GitOps output. \
               'kubernetes-placeholder' (default) emits a redacted Kubernetes Secret; \
               'external-secrets' emits an ExternalSecret CRD for the External Secrets Operator. \
               Only meaningful with --emit-to.")

let secret_store_ref_arg =
  Arg.(value & opt (some string) None &
       info ["secret-store-ref"] ~docv:"NAME"
         ~doc:"Name of the SecretStore or ClusterSecretStore to reference. \
               Required when --secret-backend=external-secrets.")

let secret_store_kind_arg =
  Arg.(value & opt (some string) None &
       info ["secret-store-kind"] ~docv:"KIND"
         ~doc:"Kind of the secret store reference (default: ClusterSecretStore). \
               Use 'SecretStore' for a namespace-scoped store.")

let key_prefix_arg =
  Arg.(value & opt (some string) None &
       info ["key-prefix"] ~docv:"PREFIX"
         ~doc:"Prefix to prepend to each secret key when looking up in the external store \
               (default: \"\"). Example: 'myworkspace/' produces keys like 'myworkspace/POSTGRES_URL'.")

let refresh_interval_arg =
  Arg.(value & opt (some string) None &
       info ["refresh-interval"] ~docv:"INTERVAL"
         ~doc:"How often ESO should sync the secret from the external store (default: 1h). \
               Examples: '1h', '30m', '5m'.")

let secret_backend_term =
  let build str store_ref store_kind key_prefix refresh_interval emit_to =
    match str with
    | "kubernetes-placeholder" | "" -> `Ok Sun_cli_manifest.Kubernetes_placeholder
    | "external-secrets" when emit_to = None ->
      Printf.eprintf "warning: --secret-backend external-secrets is only meaningful \
                      with --emit-to; using kubernetes-placeholder.\n";
      `Ok Sun_cli_manifest.Kubernetes_placeholder
    | "external-secrets" ->
      (match store_ref with
       | None ->
         `Error (true, "--secret-store-ref is required when --secret-backend=external-secrets")
       | Some sref ->
         `Ok (Sun_cli_manifest.External_secrets {
           store_ref        = sref;
           store_kind       = Option.value store_kind ~default:"ClusterSecretStore";
           key_prefix       = Option.value key_prefix ~default:"";
           refresh_interval = Option.value refresh_interval ~default:"1h";
         }))
    | other ->
      `Error (true, Printf.sprintf "unknown --secret-backend value %S \
                    (expected: kubernetes-placeholder | external-secrets)" other)
  in
  Term.(ret (const build
             $ secret_backend_arg $ secret_store_ref_arg $ secret_store_kind_arg
             $ key_prefix_arg $ refresh_interval_arg $ emit_to_arg))

let confirm_group_change_flag =
  Arg.(value & flag &
       info ["confirm-group-change"]
         ~doc:"Acknowledge that consumer group IDs have changed and proceed with deploy")

let make_config filter_path dry_run emit_to emit_plan_to image_tag registry
    secret_backend confirm_group_change =
  { filter_path; dry_run; emit_to; emit_plan_to; image_tag; registry;
    secret_backend; confirm_group_change }

let cmd =
  Cmd.v
    (Cmd.info "deploy"
       ~doc:"Deploy pre-built images to a cluster (CI/CD integration). \
             Like 'sun up' but skips the build step — images must already \
             be in the registry.")
    Term.(const (fun cfg -> run cfg)
          $ (const make_config
             $ path_arg $ dry_run_flag $ emit_to_arg
             $ emit_plan_to_arg $ image_tag_arg $ registry_arg
             $ secret_backend_term $ confirm_group_change_flag))
