(* Sun_cli_env_target — typed boundary between workspace intent and
   environment-owned substrate inputs.

   A deployment target captures what is provided by the environment (the
   cluster, the registry, the secrets infrastructure) rather than by the
   application workspace being deployed.  The four variants cover the full
   range of Sun-supported deployment modes without trying to provision
   cloud resources:

     local_k3d          — default for sun up; k3d cluster with a local
                          registry container
     customer_k8s_direct — customer-owned cluster, apply manifests directly
                          via kubectl
     customer_k8s_gitops — customer-owned cluster, write manifests to a
                          GitOps directory (Argo CD / Flux)
     sun_hosted         — reserved for a future Sun-hosted control plane;
                          not yet implemented *)

type target =
  | Local_k3d
  | Customer_k8s_direct
  | Customer_k8s_gitops
  | Sun_hosted

(* ── Environment-owned inputs ────────────────────────────────────────────── *)

(** All values that come from the target environment rather than from the
    application workspace.  Callers should build this via one of the
    constructor helpers below rather than assembling the record manually. *)
type t = {
  (* Deployment mode tag — used by the plan and manifest layers to make
     mode-specific decisions without re-inspecting every field. *)
  target              : target;

  (* Container image coordinates — owned by the environment (CI pipeline or
     local build loop provides the registry; the build job stamps the tag). *)
  registry            : string;
  image_tag           : string;

  (* Cloud placement — both optional; not required for local or direct-apply
     modes, but needed for hosted modes that provision DNS or select a region. *)
  region              : string option;
  base_domain         : string option;

  (* Infrastructure endpoints — all optional because not every deployment
     uses every subsystem.  Values come from env vars in CI, or are left as
     None for local dev where the platform/local/scripts/ensure-*.sh helpers handle
     the actual endpoints. *)
  kafka_brokers           : string option;
  postgres_secret_name    : string option;
  loki_url                : string option;
  pushgateway_url         : string option;
}

(* ── Internal constructors ───────────────────────────────────────────────── *)

(** [local_defaults ~image_tag] builds the env target for a local k3d
    deployment.  The registry constants here mirror the hard-coded values that
    were previously inlined in [cmd_up.ml]:
      push via  localhost:5000  (host-accessible registry container)
      pull via  sun-registry:5000  (cluster-internal DNS alias)
    [image_tag] is the short git SHA or a caller-supplied override. *)
let local_defaults ~image_tag = {
  target           = Local_k3d;
  registry         = "sun-registry:5000";
  image_tag;
  region           = None;
  base_domain      = None;
  kafka_brokers    = None;
  postgres_secret_name = None;
  loki_url         = None;
  pushgateway_url  = None;
}

(** [customer_cloud_defaults ~registry ~image_tag ?emit_to ()] builds the env
    target for a customer-cloud deployment.  The registry and image tag are
    required and come from CLI flags.  When [emit_to] is [Some _] the target
    is [Customer_k8s_gitops]; otherwise it is [Customer_k8s_direct]. *)
let customer_cloud_defaults
      ~registry
      ~image_tag
      ?(region = None)
      ?(base_domain = None)
      ?(kafka_brokers = None)
      ?(postgres_secret_name = None)
      ?(loki_url = None)
      ?(pushgateway_url = None)
      ~emit_to
      () =
  let target = match emit_to with
    | Some _ -> Customer_k8s_gitops
    | None   -> Customer_k8s_direct
  in
  { target
  ; registry
  ; image_tag
  ; region
  ; base_domain
  ; kafka_brokers
  ; postgres_secret_name
  ; loki_url
  ; pushgateway_url
  }

(* ── Accessors ───────────────────────────────────────────────────────────── *)

let target t          = t.target
let registry t        = t.registry
let image_tag t       = t.image_tag
let region t          = t.region
let base_domain t     = t.base_domain
let kafka_brokers t   = t.kafka_brokers
let postgres_secret_name t = t.postgres_secret_name
let loki_url t        = t.loki_url
let pushgateway_url t = t.pushgateway_url

(* ── Validation ──────────────────────────────────────────────────────────── *)

(** [validate t] checks that the env target satisfies the self-hosted substrate
    contract.

    Customer cluster modes require a non-empty registry prefix because there is
    no implicit registry for external clusters (unlike local k3d, which always
    uses sun-registry:5000).  Local and Sun-hosted modes are always valid since
    their substrate is managed externally to this record. *)
let validate t =
  match t.target with
  | Local_k3d            -> Ok ()
  | Sun_hosted           -> Ok ()
  | Customer_k8s_direct
  | Customer_k8s_gitops  ->
    if String.length (String.trim t.registry) = 0 then
      Error "registry must be set for customer cluster deployments \
(pass --registry <prefix> or set a registry in sun.toml). \
See docs/deployment/self-hosted-substrate-contract.md for the full substrate contract."
    else
      Ok ()

(* ── Conversion to deployment plan env_config ────────────────────────────── *)

(** Map the target type to the deployment_mode expected by
    [Sun_cli_deployment_plan.env_config]. *)
let deployment_mode_of_target = function
  | Local_k3d            -> Sun_cli_deployment_plan.Local
  | Customer_k8s_direct  -> Sun_cli_deployment_plan.Customer_cloud
  | Customer_k8s_gitops  -> Sun_cli_deployment_plan.Customer_cloud
  | Sun_hosted           -> Sun_cli_deployment_plan.Sun_hosted

(** [to_env_config ~name t] converts an env target into the
    [Sun_cli_deployment_plan.env_config] required by [Deployment_plan.of_services].
    [name] is the logical environment name (e.g., ["local"], ["production"]). *)
let to_env_config ~name t : Sun_cli_deployment_plan.env_config = {
  name;
  mode        = deployment_mode_of_target t.target;
  registry    = t.registry;
  image_tag   = t.image_tag;
  region      = t.region;
  base_domain = t.base_domain;
}
