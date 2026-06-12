type project_id = string
type release_id = string

type release_status =
  | Queued
  | Building
  | Live
  | Failed

type service_status = Service_live | Service_failed

type release_service = {
  service_name   : string;
  service_status : service_status;
}

type project = {
  project_id : project_id;
  workspace  : string;
}

type release = {
  release_id  : release_id;
  project_id  : project_id;
  environment : string;
  image_tag   : string;
  digest      : string option;
  services    : release_service list;
  status      : release_status;
  created_at  : string;
}

type t = {
  projects : (project_id, project) Hashtbl.t;
  releases : (release_id, release) Hashtbl.t;
  counters : (project_id, int) Hashtbl.t;
  logs     : (release_id, string list) Hashtbl.t;
}

let create () = {
  projects = Hashtbl.create 8;
  releases = Hashtbl.create 16;
  counters = Hashtbl.create 8;
  logs     = Hashtbl.create 16;
}

let project_id_of_workspace workspace =
  let b = Buffer.create (String.length workspace + 5) in
  Buffer.add_string b "proj-";
  String.iter
    (function
      | 'a' .. 'z' as c -> Buffer.add_char b c
      | 'A' .. 'Z' as c -> Buffer.add_char b (Char.lowercase_ascii c)
      | '0' .. '9' as c -> Buffer.add_char b c
      | '_' | ' ' -> Buffer.add_char b '-'
      | _ -> ())
    workspace;
  Buffer.contents b

let create_project t ~workspace =
  let project_id = project_id_of_workspace workspace in
  match Hashtbl.find_opt t.projects project_id with
  | Some project -> Ok project
  | None ->
    let project = { project_id; workspace } in
    Hashtbl.replace t.projects project_id project;
    Ok project

let get_project t project_id =
  match Hashtbl.find_opt t.projects project_id with
  | Some p -> Ok p
  | None -> Error (Printf.sprintf "project %S not found" project_id)

let list_projects t =
  Hashtbl.fold (fun _ p acc -> p :: acc) t.projects []

let next_release_id t ~project_id =
  let n = match Hashtbl.find_opt t.counters project_id with
    | Some n -> n + 1
    | None -> 1
  in
  Hashtbl.replace t.counters project_id n;
  Printf.sprintf "rel-%s-%d" project_id n

let append_log_line t release_id line =
  let existing = match Hashtbl.find_opt t.logs release_id with
    | Some ls -> ls | None -> []
  in
  Hashtbl.replace t.logs release_id (existing @ [line])

let update_release_digest t release_id digest_str =
  match Hashtbl.find_opt t.releases release_id with
  | None -> Error (Printf.sprintf "release %S not found" release_id)
  | Some r ->
    Hashtbl.replace t.releases release_id { r with digest = Some digest_str };
    Ok ()

let update_release_status t release_id status_str =
  match Hashtbl.find_opt t.releases release_id with
  | None -> Error (Printf.sprintf "release %S not found" release_id)
  | Some r ->
    let status = match status_str with
      | "failed"   -> Failed
      | "building" -> Building
      | "live"     -> Live
      | _          -> Queued
    in
    Hashtbl.replace t.releases release_id { r with status };
    Ok ()

let create_release t ~project_id ~environment ~image_tag ~service_names =
  match get_project t project_id with
  | Error msg -> Error msg
  | Ok _ ->
    let release_id = next_release_id t ~project_id in
    let created_at = string_of_float (Unix.gettimeofday ()) in
    let services =
      List.map (fun name -> { service_name = name; service_status = Service_live })
        service_names
    in
    let release = {
      release_id;
      project_id;
      environment;
      image_tag;
      digest = None;
      services;
      status = Live;
      created_at;
    } in
    Hashtbl.replace t.releases release_id release;
    append_log_line t release_id
      (Printf.sprintf "[deploy] release %s started: env=%s tag=%s"
        release_id environment image_tag);
    List.iter (fun svc ->
      append_log_line t release_id
        (Printf.sprintf "[deploy] service %s deployed" svc))
      service_names;
    append_log_line t release_id
      (Printf.sprintf "[deploy] release %s complete: status=live" release_id);
    Ok release

let list_releases t ~project_id =
  match get_project t project_id with
  | Error msg -> Error msg
  | Ok _ ->
    let all =
      Hashtbl.fold
        (fun _ r acc -> if r.project_id = project_id then r :: acc else acc)
        t.releases []
    in
    Ok (List.sort (fun a b -> String.compare a.release_id b.release_id) all)

let list_releases_page t ~project_id ?(page = 1) ?(page_size = 20) () =
  match list_releases t ~project_id with
  | Error msg -> Error msg
  | Ok all ->
    let total = List.length all in
    let offset = (page - 1) * page_size in
    let page_items =
      if offset >= total then []
      else
        let tail = List.filteri (fun i _ -> i >= offset) all in
        List.filteri (fun i _ -> i < page_size) tail
    in
    Ok (page_items, total)

let get_release t release_id =
  match Hashtbl.find_opt t.releases release_id with
  | Some r -> Ok r
  | None -> Error (Printf.sprintf "release %S not found" release_id)

let get_release_logs t release_id =
  match get_release t release_id with
  | Error msg -> Error msg
  | Ok _ ->
    let lines = match Hashtbl.find_opt t.logs release_id with
      | Some ls -> ls | None -> []
    in
    Ok lines

let release_status_to_string = function
  | Queued   -> "queued"
  | Building -> "building"
  | Live     -> "live"
  | Failed   -> "failed"

let service_status_to_string = function
  | Service_live   -> "live"
  | Service_failed -> "failed"

let release_service_to_json (s : release_service) =
  `Assoc [
    "service_name", `String s.service_name;
    "status",       `String (service_status_to_string s.service_status);
  ]

let project_to_json (p : project) =
  `Assoc [
    "project_id", `String p.project_id;
    "workspace",  `String p.workspace;
  ]

let release_to_json (r : release) =
  `Assoc [
    "release_id",  `String r.release_id;
    "project_id",  `String r.project_id;
    "environment", `String r.environment;
    "image_tag",   `String r.image_tag;
    "digest",      (match r.digest with None -> `Null | Some s -> `String s);
    "status",      `String (release_status_to_string r.status);
    "created_at",  `String r.created_at;
    "services",    `List (List.map release_service_to_json r.services);
  ]
