(* Postgres-backed implementation of the Sun control-plane registry vtable.
   Separated from cmd_cloud.ml so it can be tested independently. *)

open Caqti_request.Infix

(* ── schema ─────────────────────────────────────────────────────────────── *)

let ddl = [
  {|CREATE TABLE IF NOT EXISTS hosted_projects (
    project_id TEXT PRIMARY KEY,
    workspace  TEXT NOT NULL UNIQUE
  )|};
  {|CREATE TABLE IF NOT EXISTS hosted_releases (
    release_id  TEXT PRIMARY KEY,
    project_id  TEXT NOT NULL REFERENCES hosted_projects(project_id),
    environment TEXT NOT NULL,
    image_tag   TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'live',
    created_at  TEXT NOT NULL
  )|};
  {|CREATE TABLE IF NOT EXISTS hosted_release_services (
    release_id     TEXT NOT NULL REFERENCES hosted_releases(release_id),
    service_name   TEXT NOT NULL,
    service_status TEXT NOT NULL DEFAULT 'live',
    image_ref      TEXT,
    digest         TEXT,
    PRIMARY KEY (release_id, service_name)
  )|};
  {|CREATE TABLE IF NOT EXISTS hosted_release_logs (
    id         SERIAL PRIMARY KEY,
    release_id TEXT NOT NULL REFERENCES hosted_releases(release_id),
    line       TEXT NOT NULL
  )|};
]

(* ── queries ─────────────────────────────────────────────────────────────── *)

let find_project_q =
  (Caqti_type.string ->? Caqti_type.(t2 string string))
    "SELECT project_id, workspace FROM hosted_projects WHERE project_id = ?"

let find_project_by_workspace_q =
  (Caqti_type.string ->? Caqti_type.(t2 string string))
    "SELECT project_id, workspace FROM hosted_projects WHERE workspace = ?"

let upsert_project_q =
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
    "INSERT INTO hosted_projects (project_id, workspace) VALUES (?, ?) \
     ON CONFLICT (project_id) DO NOTHING"

let insert_release_q =
  (Caqti_type.(t6 string string string string string string) ->. Caqti_type.unit)
    "INSERT INTO hosted_releases \
       (release_id, project_id, environment, image_tag, status, created_at) \
     VALUES (?, ?, ?, ?, ?, ?)"

let list_releases_q =
  (Caqti_type.string ->* Caqti_type.(t7 string string string string string string (option string)))
    "SELECT release_id, project_id, environment, image_tag, status, created_at, digest \
     FROM hosted_releases WHERE project_id = ? ORDER BY created_at ASC"

let update_digest_q =
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
    "UPDATE hosted_releases SET digest = ? WHERE release_id = ?"

let append_log_q =
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
    "INSERT INTO hosted_release_logs (release_id, line) VALUES (?, ?)"

let insert_service_q =
  (Caqti_type.(t3 string string string) ->. Caqti_type.unit)
    "INSERT INTO hosted_release_services (release_id, service_name, service_status) \
     VALUES (?, ?, ?) ON CONFLICT DO NOTHING"

let list_services_q =
  (Caqti_type.string ->* Caqti_type.(t4 string string (option string) (option string)))
    "SELECT service_name, service_status, image_ref, digest \
     FROM hosted_release_services WHERE release_id = ?"

let update_service_digest_q =
  (Caqti_type.(t4 string string string string) ->. Caqti_type.unit)
    "UPDATE hosted_release_services \
     SET image_ref = ?, digest = ? WHERE release_id = ? AND service_name = ?"

let list_logs_q =
  (Caqti_type.string ->* Caqti_type.string)
    "SELECT line FROM hosted_release_logs \
     WHERE release_id = ? ORDER BY id ASC"

let update_status_q =
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
    "UPDATE hosted_releases SET status = ? WHERE release_id = ?"

let delete_logs_q =
  (Caqti_type.string ->. Caqti_type.unit)
    "DELETE FROM hosted_release_logs WHERE release_id = ?"

let delete_services_q =
  (Caqti_type.string ->. Caqti_type.unit)
    "DELETE FROM hosted_release_services WHERE release_id = ?"

let delete_release_q =
  (Caqti_type.string ->. Caqti_type.unit)
    "DELETE FROM hosted_releases WHERE release_id = ?"

let delete_project_q =
  (Caqti_type.string ->. Caqti_type.unit)
    "DELETE FROM hosted_projects WHERE project_id = ?"

let list_releases_by_project_q =
  (Caqti_type.string ->* Caqti_type.string)
    "SELECT release_id FROM hosted_releases WHERE project_id = ?"

(* ── helpers ─────────────────────────────────────────────────────────────── *)

let storage_err_to_string e = Storage_error.to_string e

let ensure_schema pool =
  let all_ddl = ddl @ [
    "ALTER TABLE hosted_releases ADD COLUMN IF NOT EXISTS digest TEXT";
    "ALTER TABLE hosted_release_services ADD COLUMN IF NOT EXISTS image_ref TEXT";
    "ALTER TABLE hosted_release_services ADD COLUMN IF NOT EXISTS digest TEXT";
  ] in
  List.iter (fun sql ->
    let q = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) sql in
    match Db.exec pool q () with
    | Ok () -> ()
    | Error e ->
      Printf.eprintf "warning: schema DDL failed: %s\n%!" (storage_err_to_string e)
  ) all_ddl

let row_to_project (project_id, workspace) : Sun_cli_registry.project =
  { project_id; workspace }

let row_to_release services (release_id, project_id, environment, image_tag, status_s, created_at, digest)
    : Sun_cli_registry.release =
  let status = match status_s with
    | "queued"   -> Sun_cli_registry.Queued
    | "building" -> Sun_cli_registry.Building
    | "failed"   -> Sun_cli_registry.Failed
    | _          -> Sun_cli_registry.Live
  in
  { release_id; project_id; environment; image_tag; digest; status; created_at; services }

let fetch_services pool release_id =
  match Db.collect pool list_services_q release_id with
  | Error e -> Error (storage_err_to_string e)
  | Ok rows ->
    let svcs = List.map (fun (service_name, svc_status_s, image_ref, digest) ->
      let service_status = match svc_status_s with
        | "failed" -> Sun_cli_registry.Service_failed
        | _        -> Sun_cli_registry.Service_live
      in
      { Sun_cli_registry.service_name; service_status; image = image_ref; digest }
    ) rows in
    Ok svcs

(* ── operations ──────────────────────────────────────────────────────────── *)

let pg_get_project pool project_id =
  match Db.find pool find_project_q project_id with
  | Error e -> Error (storage_err_to_string e)
  | Ok None -> Error (Printf.sprintf "project %S not found" project_id)
  | Ok (Some row) -> Ok (row_to_project row)

let pg_create_project pool ~workspace =
  let project_id = Sun_cli_registry.project_id_of_workspace workspace in
  match Db.find pool find_project_by_workspace_q workspace with
  | Error e -> Error (storage_err_to_string e)
  | Ok (Some row) -> Ok (row_to_project row)
  | Ok None ->
    match Db.exec pool upsert_project_q (project_id, workspace) with
    | Error e -> Error (storage_err_to_string e)
    | Ok () ->
      match Db.find pool find_project_q project_id with
      | Error e -> Error (storage_err_to_string e)
      | Ok None -> Error "project not found after insert"
      | Ok (Some row) -> Ok (row_to_project row)

let pg_create_release pool ~project_id ~environment ~image_tag ~service_names =
  match pg_get_project pool project_id with
  | Error msg -> Error msg
  | Ok _ ->
    let release_id =
      Printf.sprintf "rel-%s-%s"
        project_id
        (string_of_int (int_of_float (Unix.gettimeofday () *. 1000.0)))
    in
    let created_at = string_of_float (Unix.gettimeofday ()) in
    let status = "live" in
    let result = Db.transaction pool (fun tx ->
      match Db.exec tx insert_release_q
              (release_id, project_id, environment, image_tag, status, created_at) with
      | Error e -> Error e
      | Ok () ->
        let service_err =
          List.fold_left (fun acc name ->
            match acc with
            | Error _ as e -> e
            | Ok () ->
              Db.exec tx insert_service_q (release_id, name, "live")
          ) (Ok ()) service_names
        in
        (match service_err with
         | Error _ as e -> e
         | Ok () ->
           let log_lines = [
             Printf.sprintf "[deploy] release %s started: env=%s tag=%s"
               release_id environment image_tag;
           ] @ List.map (fun svc ->
             Printf.sprintf "[deploy] service %s deployed" svc
           ) service_names
           @ [ Printf.sprintf "[deploy] release %s complete: status=live" release_id ]
           in
           List.fold_left (fun acc line ->
             match acc with
             | Error _ as e -> e
             | Ok () -> Db.exec tx append_log_q (release_id, line)
           ) (Ok ()) log_lines)
    ) in
    (match result with
     | Error e -> Error (storage_err_to_string e)
     | Ok () ->
       let services =
         List.map (fun name ->
           { Sun_cli_registry.service_name = name;
             service_status = Sun_cli_registry.Service_live;
             image = None; digest = None })
           service_names
       in
       Ok { Sun_cli_registry.
            release_id; project_id; environment; image_tag;
            digest = None;
            status = Sun_cli_registry.Live; created_at; services })

let pg_list_releases pool ~project_id =
  match pg_get_project pool project_id with
  | Error msg -> Error msg
  | Ok _ ->
    match Db.collect pool list_releases_q project_id with
    | Error e -> Error (storage_err_to_string e)
    | Ok rows ->
      let results = List.map (fun row ->
        let (release_id, _, _, _, _, _, _) = row in
        match fetch_services pool release_id with
        | Error e -> Error e
        | Ok svcs -> Ok (row_to_release svcs row)
      ) rows in
      let err = List.find_opt (function Error _ -> true | Ok _ -> false) results in
      (match err with
       | Some (Error e) -> Error e
       | _ ->
         Ok (List.filter_map (function Ok r -> Some r | Error _ -> None) results))

let pg_list_releases_page pool ~project_id ?(page = 1) ?(page_size = 20) () =
  match pg_list_releases pool ~project_id with
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

let pg_get_release_logs pool _project_id release_id =
  match Db.collect pool list_logs_q release_id with
  | Error e -> Error (storage_err_to_string e)
  | Ok lines -> Ok lines

let pg_append_log_line pool release_id line =
  (match Db.exec pool append_log_q (release_id, line) with
   | Ok () -> ()
   | Error e ->
     Printf.eprintf "warning: append_log_line failed: %s\n%!" (storage_err_to_string e))

let pg_update_service_digest pool release_id service_name image_ref digest_str =
  match Db.exec pool update_service_digest_q (image_ref, digest_str, release_id, service_name) with
  | Ok () -> Ok ()
  | Error e -> Error (storage_err_to_string e)

let pg_update_status pool release_id status_str =
  match Db.exec pool update_status_q (status_str, release_id) with
  | Ok () -> Ok ()
  | Error e -> Error (storage_err_to_string e)

(* ── test cleanup helper ──────────────────────────────────────────────────── *)

let delete_project_rows pool project_id =
  match Db.collect pool list_releases_by_project_q project_id with
  | Error _ -> ()
  | Ok release_ids ->
    List.iter (fun rid ->
      ignore (Db.exec pool delete_logs_q rid);
      ignore (Db.exec pool delete_services_q rid);
      ignore (Db.exec pool delete_release_q rid);
    ) release_ids;
    ignore (Db.exec pool delete_project_q project_id)

(* ── vtable builder ──────────────────────────────────────────────────────── *)

let pg_ops pool : Sun_cli_control_plane.registry_ops = {
  Sun_cli_control_plane.
  create_project        = pg_create_project pool;
  get_project           = pg_get_project pool;
  create_release        = pg_create_release pool;
  list_releases         = pg_list_releases pool;
  list_releases_page    = pg_list_releases_page pool;
  get_release_logs      = pg_get_release_logs pool;
  append_log_line       = pg_append_log_line pool;
  update_service_digest = pg_update_service_digest pool;
  update_release_status = pg_update_status pool;
}

let _ = update_digest_q  (* suppress unused warning — used by cmd_cloud *)
