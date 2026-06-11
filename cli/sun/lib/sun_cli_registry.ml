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
  services    : release_service list;
  status      : release_status;
  created_at  : string;
}

type t = {
  projects : (project_id, project) Hashtbl.t;
  releases : (release_id, release) Hashtbl.t;
  counters : (project_id, int) Hashtbl.t;
}

let create () = {
  projects = Hashtbl.create 8;
  releases = Hashtbl.create 16;
  counters = Hashtbl.create 8;
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
      services;
      status = Live;
      created_at;
    } in
    Hashtbl.replace t.releases release_id release;
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

let get_release t release_id =
  match Hashtbl.find_opt t.releases release_id with
  | Some r -> Ok r
  | None -> Error (Printf.sprintf "release %S not found" release_id)

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
    "status",      `String (release_status_to_string r.status);
    "created_at",  `String r.created_at;
    "services",    `List (List.map release_service_to_json r.services);
  ]
