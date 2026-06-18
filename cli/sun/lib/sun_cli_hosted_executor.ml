type image_ref = {
  service_name : string;
  image        : string;
}

type release_status =
  | Mock_submitted

type service_summary = {
  service_name : string;
  namespace    : string;
  primitive    : Sun_cli_deployment_plan.primitive;
  image        : string;
  default_url  : string option;
}

type release = {
  release_id       : string;
  environment_id   : Sun_cli_hosted_model.environment_id;
  environment_name : string;
  status           : release_status;
  services         : service_summary list;
  inspection       : Sun_cli_release_inspection.release_summary;
}

type request = {
  target          : Sun_cli_hosted_model.release_target;
  plan            : Sun_cli_deployment_plan.t;
  serialized_plan : Yojson.Safe.t;
  image_refs      : image_ref list;
}

let release_status_to_string = function
  | Mock_submitted -> "mock_submitted"

let primitive_to_string = function
  | Sun_cli_deployment_plan.Svc -> "svc"
  | Sun_cli_deployment_plan.Worker -> "worker"
  | Sun_cli_deployment_plan.Fn -> "fn"

let image_refs_of_plan (plan : Sun_cli_deployment_plan.t) =
  List.map
    (fun (s : Sun_cli_deployment_plan.service_spec) ->
       { service_name = Sun_cli_deployment_plan.k8s_name_to_string s.k8s_name;
         image = s.image })
    plan.services

let normalize_id value =
  let b = Buffer.create (String.length value) in
  String.iter
    (function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' as c ->
        Buffer.add_char b (Char.lowercase_ascii c)
      | '-' | '_' -> Buffer.add_char b '-'
      | _ -> ())
    value;
  let s = Buffer.contents b in
  if s = "" then "unknown" else s

let release_id ~(target : Sun_cli_hosted_model.release_target)
    ~(plan : Sun_cli_deployment_plan.t) =
  Printf.sprintf "rel_%s_%s"
    (normalize_id
       (Sun_cli_hosted_model.environment_id_to_string target.environment_id))
    (normalize_id plan.environment.image_tag)

let find_image_ref service_name (image_refs : image_ref list) =
  List.find_opt (fun (ref : image_ref) -> ref.service_name = service_name) image_refs

let duplicate_image_ref (image_refs : image_ref list) =
  let rec loop seen = function
    | [] -> None
    | (ref : image_ref) :: rest ->
      if List.mem ref.service_name seen then Some ref.service_name
      else loop (ref.service_name :: seen) rest
  in
  loop [] image_refs

let default_url_for (s : Sun_cli_deployment_plan.service_spec)
    (plan : Sun_cli_deployment_plan.t) =
  match s.primitive, plan.environment.base_domain with
  | Sun_cli_deployment_plan.Svc, Some base_domain ->
    let service_name = Sun_cli_deployment_plan.k8s_name_to_string s.k8s_name in
    (match Sun_cli_hosted_url.generate_default_url
             ~service_name
             ~workspace:plan.workspace
             ~environment_name:plan.environment.name
             ~base_domain with
     | Ok url -> Ok (Some url)
     | Error msg ->
       Error (Printf.sprintf "invalid hosted default URL for service %s: %s"
                service_name msg))
  | _ -> Ok None

let service_summaries plan (image_refs : image_ref list) =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (s : Sun_cli_deployment_plan.service_spec) :: rest ->
      let service_name = Sun_cli_deployment_plan.k8s_name_to_string s.k8s_name in
      match find_image_ref service_name image_refs with
      | None ->
        Error (Printf.sprintf "missing hosted image ref for service %s" service_name)
      | Some ref ->
        match default_url_for s plan with
        | Error msg -> Error msg
        | Ok default_url ->
          let summary = {
            service_name;
            namespace = Sun_cli_deployment_plan.namespace_to_string s.namespace;
            primitive = s.primitive;
            image = ref.image;
            default_url;
          } in
          loop (summary :: acc) rest
  in
  loop [] plan.Sun_cli_deployment_plan.services

let inspection_image_refs (image_refs : image_ref list) =
  List.map
    (fun (ref : image_ref) ->
       { Sun_cli_release_inspection.service_name = ref.service_name;
         image = ref.image;
       })
    image_refs

let inspection_services plan (image_refs : image_ref list) =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (s : Sun_cli_deployment_plan.service_spec) :: rest ->
      let service_name = Sun_cli_deployment_plan.k8s_name_to_string s.k8s_name in
      match find_image_ref service_name image_refs with
      | None ->
        Error (Printf.sprintf "missing hosted image ref for service %s" service_name)
      | Some ref ->
        match default_url_for s plan with
        | Error msg -> Error msg
        | Ok default_url ->
          let service =
            Sun_cli_release_inspection.affected_service
              ?default_url
              ~image:ref.image s
          in
          loop (service :: acc) rest
  in
  loop [] plan.Sun_cli_deployment_plan.services

let submit_mock request =
  let plan = request.plan in
  let target = request.target in
  if plan.Sun_cli_deployment_plan.environment.mode <> Sun_cli_deployment_plan.Sun_hosted then
    Error "deployment plan is not for sun_hosted mode"
  else if target.workspace <> plan.workspace then
    Error "deployment plan workspace does not match hosted release target"
  else if target.environment_name <> plan.environment.name then
    Error "deployment plan environment does not match hosted release target"
  else if request.serialized_plan <> Sun_cli_deployment_plan.to_json plan then
    Error "serialized deployment plan does not match request plan"
  else
    match duplicate_image_ref request.image_refs with
    | Some service_name ->
      Error (Printf.sprintf "duplicate hosted image ref for service %s" service_name)
    | None ->
      match service_summaries plan request.image_refs with
      | Error msg -> Error msg
      | Ok services ->
        match inspection_services plan request.image_refs with
        | Error msg -> Error msg
        | Ok inspection_services ->
          let release_id = release_id ~target ~plan in
          let inspection =
            Sun_cli_release_inspection.release_summary
              ~release_id
              ~environment_id:
                (Sun_cli_hosted_model.environment_id_to_string
                   target.environment_id)
              ~environment_name:target.environment_name
              ~status:Sun_cli_release_inspection.Mock_submitted
              ~plan
              ~image_refs:(inspection_image_refs request.image_refs)
              ~services:inspection_services
          in
        Ok {
          release_id;
          environment_id = target.environment_id;
          environment_name = target.environment_name;
          status = Mock_submitted;
          services;
          inspection;
        }

let release_to_json release =
  let service_to_json s =
    let fields = [
      "service_name", `String s.service_name;
      "namespace", `String s.namespace;
      "primitive", `String (primitive_to_string s.primitive);
      "image", `String s.image;
    ] in
    let fields =
      match s.default_url with
      | None -> fields
      | Some url -> fields @ [ "default_url", `String url ]
    in
    `Assoc fields
  in
  `Assoc [
    "_note", `String "experimental hosted executor mock; no control plane submission occurred";
    "release_id", `String release.release_id;
    "environment_id",
      `String
        (Sun_cli_hosted_model.environment_id_to_string release.environment_id);
    "environment_name", `String release.environment_name;
    "status", `String (release_status_to_string release.status);
    "services", `List (List.map service_to_json release.services);
    "inspection", Sun_cli_release_inspection.release_summary_to_json release.inspection;
  ]
