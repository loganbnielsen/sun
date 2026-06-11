type http_method = Get | Post

type request = {
  meth : http_method;
  path : string;
  body : Yojson.Safe.t option;
}

type response = {
  status : int;
  body   : Yojson.Safe.t;
}

let ok body      = { status = 200; body }
let created body = { status = 201; body }
let bad_request msg =
  { status = 400; body = `Assoc [ "error", `String msg ] }
let not_found msg =
  { status = 404; body = `Assoc [ "error", `String msg ] }

let json_string key json =
  match Yojson.Safe.Util.(json |> member key) with
  | `String s -> Ok s
  | `Null | _ -> Error (Printf.sprintf "missing string field %S" key)

let json_strings key json =
  match Yojson.Safe.Util.(json |> member key) with
  | `List vs ->
    let strs = List.filter_map (function `String s -> Some s | _ -> None) vs in
    Ok strs
  | `Null | _ -> Ok []

(* ── path matching ──────────────────────────────────────────────────────── *)

let split_path path =
  String.split_on_char '/' path
  |> List.filter (fun s -> s <> "")

(* POST /projects *)
let handle_post_projects registry body =
  match body with
  | None -> bad_request "body required"
  | Some json ->
    match json_string "workspace" json with
    | Error msg -> bad_request msg
    | Ok workspace ->
      match Sun_cli_registry.create_project registry ~workspace with
      | Error msg -> bad_request msg
      | Ok project ->
        created (Sun_cli_registry.project_to_json project)

(* GET /projects/{id} *)
let handle_get_project registry project_id =
  match Sun_cli_registry.get_project registry project_id with
  | Error _ -> not_found (Printf.sprintf "project %S not found" project_id)
  | Ok project ->
    let releases =
      match Sun_cli_registry.list_releases registry ~project_id with
      | Ok rs -> rs
      | Error _ -> []
    in
    let release_ids =
      List.map (fun (r : Sun_cli_registry.release) ->
        `String r.release_id) releases
    in
    ok (`Assoc [
      "project",     Sun_cli_registry.project_to_json project;
      "release_ids", `List release_ids;
    ])

(* POST /projects/{id}/releases *)
let ( let* ) = Result.bind

let handle_post_release registry project_id body =
  match body with
  | None -> bad_request "body required"
  | Some json ->
    let result =
      let* environment = json_string "environment" json in
      let* image_tag = json_string "image_tag" json in
      let* service_names = json_strings "service_names" json in
      Sun_cli_registry.create_release registry
        ~project_id ~environment ~image_tag ~service_names
    in
    match result with
    | Error msg -> bad_request msg
    | Ok release ->
      created (Sun_cli_registry.release_to_json release)

(* ── dispatcher ─────────────────────────────────────────────────────────── *)

let handle registry req =
  match req.meth, split_path req.path with
  | Post, [ "projects" ] ->
    handle_post_projects registry req.body
  | Get, [ "projects"; id ] ->
    handle_get_project registry id
  | Post, [ "projects"; id; "releases" ] ->
    handle_post_release registry id req.body
  | _ ->
    not_found (Printf.sprintf "no route for %s" req.path)

(* ── request constructors ───────────────────────────────────────────────── *)

let post_projects ~workspace =
  { meth = Post;
    path = "/projects";
    body = Some (`Assoc [ "workspace", `String workspace ]) }

let get_project ~project_id =
  { meth = Get;
    path = Printf.sprintf "/projects/%s" project_id;
    body = None }

let post_release ~project_id ~environment ~image_tag ~service_names =
  { meth = Post;
    path = Printf.sprintf "/projects/%s/releases" project_id;
    body = Some (`Assoc [
      "environment",   `String environment;
      "image_tag",     `String image_tag;
      "service_names", `List (List.map (fun s -> `String s) service_names);
    ]) }
