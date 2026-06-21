type up_request = {
  filter_path          : string option;
  dry_run              : bool;
  image_tag            : string;
  confirm_group_change : bool;
}

type deploy_request = {
  filter_path          : string option;
  dry_run              : bool;
  emit_to              : string option;
  emit_plan_to         : string option;
  image_tag            : string;
  registry             : string;
  secret_backend       : Sun_cli_manifest.secret_backend;
  confirm_group_change : bool;
}

let make_up_request ~filter_path ~dry_run ~tag ~confirm_group_change ~git_sha =
  let image_tag = match tag with Some t -> t | None -> git_sha () in
  Ok { filter_path; dry_run; image_tag; confirm_group_change }

let make_deploy_request ~filter_path ~dry_run ~emit_to ~emit_plan_to
    ~image_tag ~registry ~secret_backend ~confirm_group_change ~git_sha =
  let image_tag = match image_tag with Some t -> t | None -> git_sha () in
  let registry  = match registry  with Some r -> r | None -> "sun-registry:5000" in
  Ok { filter_path; dry_run; emit_to; emit_plan_to; image_tag; registry;
       secret_backend; confirm_group_change }
