(* Registry storage selection for `sun cloud` commands. *)

(* ── Postgres-backed registry ────────────────────────────────────────────── *)

module Pg_registry = struct
  open Caqti_request.Infix

  (* ── schema ────────────────────────────────────────────────────────────── *)

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

  (* ── queries ───────────────────────────────────────────────────────────── *)

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

  (* ── helpers ───────────────────────────────────────────────────────────── *)

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

  (* ── operations ────────────────────────────────────────────────────────── *)

  let pg_get_project pool project_id =
    match Db.find pool find_project_q project_id with
    | Error e -> Error (storage_err_to_string e)
    | Ok None -> Error (Printf.sprintf "project %S not found" project_id)
    | Ok (Some row) -> Ok (row_to_project row)

  let pg_create_project pool ~workspace =
    let project_id = Sun_cli_registry.project_id_of_workspace workspace in
    (* Check if already exists by workspace *)
    match Db.find pool find_project_by_workspace_q workspace with
    | Error e -> Error (storage_err_to_string e)
    | Ok (Some row) -> Ok (row_to_project row)
    | Ok None ->
      match Db.exec pool upsert_project_q (project_id, workspace) with
      | Error e -> Error (storage_err_to_string e)
      | Ok () ->
        (* Re-fetch in case there was a conflict on project_id *)
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

  let update_status_q =
    (Caqti_type.(t2 string string) ->. Caqti_type.unit)
      "UPDATE hosted_releases SET status = ? WHERE release_id = ?"

  let pg_update_status pool release_id status =
    let status_str = Sun_cli_registry.string_of_release_status status in
    match Db.exec pool update_status_q (status_str, release_id) with
    | Ok () -> Ok ()
    | Error e -> Error (storage_err_to_string e)

  (* ── vtable builder ────────────────────────────────────────────────────── *)

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
end

(* ── In-memory vtable ────────────────────────────────────────────────────── *)

let memory_ops () =
  let r = Sun_cli_registry.create () in
  { Sun_cli_control_plane.
    create_project        = Sun_cli_registry.create_project r;
    get_project           = Sun_cli_registry.get_project r;
    create_release        = Sun_cli_registry.create_release r;
    list_releases         = Sun_cli_registry.list_releases r;
    list_releases_page    = Sun_cli_registry.list_releases_page r;
    get_release_logs      = (fun _project_id release_id ->
                               Sun_cli_registry.get_release_logs r release_id);
    append_log_line       = Sun_cli_registry.append_log_line r;
    update_service_digest = (fun rid svc img dig ->
                               Sun_cli_registry.update_service_digest r rid
                                 ~service_name:svc ~image_ref:img ~digest_str:dig);
    update_release_status = (fun rid s -> Sun_cli_registry.update_release_status r rid s);
  }

(* ── Registry selector ───────────────────────────────────────────────────── *)

let with_registry f =
  match Sys.getenv_opt "CONTROL_PLANE_DATABASE_URL" with
  | None -> f (memory_ops ())
  | Some url ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        match Db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
        | Error e ->
          Printf.eprintf "error: cannot connect to control-plane database: %s\n"
            (Storage_error.to_string e);
          exit 1
        | Ok pool ->
          Pg_registry.ensure_schema pool;
          f (Pg_registry.pg_ops pool)
      )
    )
