type http_method = Get | Post

type request = {
  meth   : http_method;
  path   : string;
  body   : Yojson.Safe.t option;
  params : (string * string) list;
}

type response = {
  status : int;
  body   : Yojson.Safe.t;
}

(* ── vtable ─────────────────────────────────────────────────────────────── *)

type registry_ops = {
  create_project        : workspace:string -> (Sun_cli_registry.project, string) result;
  get_project           : string -> (Sun_cli_registry.project, string) result;
  create_release        : project_id:string -> environment:string -> image_tag:string
                          -> service_names:string list -> (Sun_cli_registry.release, string) result;
  list_releases         : project_id:string -> (Sun_cli_registry.release list, string) result;
  list_releases_page    : project_id:string -> ?page:int -> ?page_size:int -> unit
                          -> (Sun_cli_registry.release list * int, string) result;
  get_release_logs      : string -> string -> (string list, string) result;
  append_log_line       : string -> string -> unit;
  update_service_digest : string -> string -> string -> string -> (unit, string) result;
  (** [update_service_digest release_id service_name image_ref digest_str] *)
  update_release_status : string -> Sun_cli_registry.release_status -> (unit, string) result;
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
let handle_post_projects ops body =
  match body with
  | None -> bad_request "body required"
  | Some json ->
    match json_string "workspace" json with
    | Error msg -> bad_request msg
    | Ok workspace ->
      match ops.create_project ~workspace with
      | Error msg -> bad_request msg
      | Ok project ->
        created (Sun_cli_registry.project_to_json project)

(* GET /projects/{id} *)
let handle_get_project ops project_id =
  match ops.get_project project_id with
  | Error _ -> not_found (Printf.sprintf "project %S not found" project_id)
  | Ok project ->
    let releases =
      match ops.list_releases ~project_id with
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

let handle_post_release ops project_id body =
  match body with
  | None -> bad_request "body required"
  | Some json ->
    let result =
      let* environment = json_string "environment" json in
      let* image_tag = json_string "image_tag" json in
      let* service_names = json_strings "service_names" json in
      ops.create_release ~project_id ~environment ~image_tag ~service_names
    in
    match result with
    | Error msg -> bad_request msg
    | Ok release ->
      created (Sun_cli_registry.release_to_json release)

let param_int key params default =
  match List.assoc_opt key params with
  | Some s -> (match int_of_string_opt s with Some n -> n | None -> default)
  | None -> default

(* GET /projects/{id}/releases *)
let handle_get_releases ops project_id params =
  let page      = param_int "page"      params 1  in
  let page_size = param_int "page_size" params 20 in
  match ops.list_releases_page ~project_id ~page ~page_size () with
  | Error _ -> not_found (Printf.sprintf "project %S not found" project_id)
  | Ok (items, total) ->
    ok (`Assoc [
      "releases",  `List (List.map Sun_cli_registry.release_to_json items);
      "total",     `Int total;
      "page",      `Int page;
      "page_size", `Int page_size;
    ])

(* GET /projects/{id}/releases/{release_id}/logs *)
let handle_get_release_logs ops project_id release_id =
  match ops.get_release_logs project_id release_id with
  | Error _ -> not_found (Printf.sprintf "release %S not found" release_id)
  | Ok lines ->
    ok (`Assoc [
      "release_id", `String release_id;
      "lines",      `List (List.map (fun s -> `String s) lines);
    ])

(* ── dispatcher ─────────────────────────────────────────────────────────── *)

let handle ops req =
  match req.meth, split_path req.path with
  | Post, [ "projects" ] ->
    handle_post_projects ops req.body
  | Get, [ "projects"; id ] ->
    handle_get_project ops id
  | Post, [ "projects"; id; "releases" ] ->
    handle_post_release ops id req.body
  | Get, [ "projects"; id; "releases" ] ->
    handle_get_releases ops id req.params
  | Get, [ "projects"; id; "releases"; rid; "logs" ] ->
    handle_get_release_logs ops id rid
  | _ ->
    not_found (Printf.sprintf "no route for %s" req.path)

(* ── request constructors ───────────────────────────────────────────────── *)

let post_projects ~workspace =
  { meth = Post;
    path = "/projects";
    body = Some (`Assoc [ "workspace", `String workspace ]);
    params = [] }

let get_project ~project_id =
  { meth = Get;
    path = Printf.sprintf "/projects/%s" project_id;
    body = None;
    params = [] }

let post_release ~project_id ~environment ~image_tag ~service_names =
  { meth = Post;
    path = Printf.sprintf "/projects/%s/releases" project_id;
    body = Some (`Assoc [
      "environment",   `String environment;
      "image_tag",     `String image_tag;
      "service_names", `List (List.map (fun s -> `String s) service_names);
    ]);
    params = [] }

let get_releases ~project_id ?(page = 1) ?(page_size = 20) () =
  { meth = Get;
    path = Printf.sprintf "/projects/%s/releases" project_id;
    body = None;
    params = [
      "page",      string_of_int page;
      "page_size", string_of_int page_size;
    ] }

let get_release_logs ~project_id ~release_id =
  { meth = Get;
    path = Printf.sprintf "/projects/%s/releases/%s/logs" project_id release_id;
    body = None;
    params = [] }
