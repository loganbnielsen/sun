type t =
  | Local          of { image_tag : string; cluster_registry : string }
  | Customer_direct of { image_tag : string; registry : string }
  | Customer_gitops of { image_tag : string; registry : string }
  | Sun_hosted     of { image_tag : string; registry : string }

let local_defaults ~image_tag =
  Local { image_tag; cluster_registry = "sun-registry:5000" }

let customer_cloud_defaults ~registry ~image_tag ~emit_to () =
  if String.length (String.trim registry) = 0 then
    Error "registry must be set for customer cluster deployments \
(pass --registry <prefix> or set a registry in sun.toml). \
See docs/deployment/self-hosted-substrate-contract.md for the full substrate contract."
  else
    match emit_to with
    | Some _ -> Ok (Customer_gitops { image_tag; registry })
    | None   -> Ok (Customer_direct { image_tag; registry })

let image_tag = function
  | Local          { image_tag; _ }
  | Customer_direct { image_tag; _ }
  | Customer_gitops { image_tag; _ }
  | Sun_hosted     { image_tag; _ } -> image_tag

let registry = function
  | Local          { cluster_registry; _ } -> cluster_registry
  | Customer_direct { registry; _ }
  | Customer_gitops { registry; _ }
  | Sun_hosted     { registry; _ }         -> registry

let deployment_mode_of_target = function
  | Local _           -> Sun_cli_deployment_plan.Local
  | Customer_direct _ -> Sun_cli_deployment_plan.Customer_cloud
  | Customer_gitops _ -> Sun_cli_deployment_plan.Customer_cloud
  | Sun_hosted _      -> Sun_cli_deployment_plan.Sun_hosted

let to_env_config ~name t : Sun_cli_deployment_plan.env_config = {
  name;
  mode           = deployment_mode_of_target t;
  registry       = registry t;
  image_tag      = image_tag t;
  region         = None;
  base_domain    = None;
  secret_backend = Sun_cli_manifest.Kubernetes_placeholder;
}
