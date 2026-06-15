let ( let* ) = Result.bind

type status = {
  version    : int;
  name       : string;
  applied_at : string option;
}

(* ── File parsing ────────────────────────────────────────────────────────── *)

let parse_filename f =
  if not (Filename.check_suffix f ".sql") then None
  else if Filename.check_suffix f ".down.sql" then None
  else
    let base = Filename.chop_suffix f ".sql" in
    match String.split_on_char '_' base with
    | [] | [_] -> None
    | version_str :: rest ->
      (match int_of_string_opt version_str with
       | None   -> None
       | Some v -> Some (v, String.concat "_" rest))

let read_migrations dir =
  match Sys.readdir dir with
  | exception Sys_error msg ->
    Error (Storage_error.Migration_error ("cannot read migrations dir: " ^ msg))
  | files ->
    let parsed = Array.to_list files |> List.filter_map (fun f ->
      match parse_filename f with
      | None         -> None
      | Some (v, nm) -> Some (v, nm, Filename.concat dir f))
    in
    let sorted = List.sort (fun (a, _, _) (b, _, _) -> compare a b) parsed in
    Ok sorted

let split_statements sql =
  String.split_on_char ';' sql
  |> List.filter_map (fun s ->
    let s = String.trim s in
    if String.length s = 0 then None else Some (s ^ ";"))

(* ── Per-table helpers (table name injected at call time) ───────────────── *)

let ensure_table tbl pool =
  let q = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
    (Printf.sprintf
       {|CREATE TABLE IF NOT EXISTS %s (
           version    INTEGER PRIMARY KEY,
           name       TEXT    NOT NULL,
           applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
         )|} tbl)
  in
  Db.exec pool q ()

let applied_versions tbl pool =
  let q = Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.int) ~oneshot:true
    (Printf.sprintf "SELECT version FROM %s ORDER BY version" tbl)
  in
  Db.collect pool q ()

let record_migration tbl pool version name =
  let q = Caqti_request.Infix.(Caqti_type.(t2 int string) ->. Caqti_type.unit) ~oneshot:true
    (Printf.sprintf "INSERT INTO %s (version, name) VALUES (?, ?)" tbl)
  in
  Db.exec pool q (version, name)

let applied_at_q tbl =
  Caqti_request.Infix.(Caqti_type.int ->? Caqti_type.string) ~oneshot:true
    (Printf.sprintf "SELECT applied_at::text FROM %s WHERE version = ?" tbl)

let last_applied_q tbl =
  Caqti_request.Infix.(Caqti_type.unit ->? Caqti_type.(t2 int string)) ~oneshot:true
    (Printf.sprintf "SELECT version, name FROM %s ORDER BY version DESC LIMIT 1" tbl)

let delete_version_q tbl =
  Caqti_request.Infix.(Caqti_type.int ->. Caqti_type.unit) ~oneshot:true
    (Printf.sprintf "DELETE FROM %s WHERE version = ?" tbl)

(* ── Public API ──────────────────────────────────────────────────────────── *)

let default_table = "sun_schema_migrations"

let apply ?(table = default_table) pool ~dir =
  let wrap msg = Result.map_error (fun e ->
    Storage_error.Migration_error (msg ^ Storage_error.to_string e))
  in
  let* () = ensure_table table pool |> wrap "create migrations table: " in
  let* migrations = read_migrations dir in
  let* applied = applied_versions table pool |> wrap "query applied migrations: " in
  let pending = List.filter (fun (v, _, _) -> not (List.mem v applied)) migrations in
  List.fold_left (fun acc (version, name, path) ->
    match acc with
    | Error _ as e -> e
    | Ok () ->
      let content =
        match In_channel.with_open_text path In_channel.input_all with
        | s -> Ok s
        | exception Sys_error msg ->
          Error (Storage_error.Migration_error ("cannot read " ^ path ^ ": " ^ msg))
      in
      let* sql = content in
      Db.transaction pool (fun pool ->
        let stmts = split_statements sql in
        let* () = List.fold_left (fun acc stmt ->
          match acc with
          | Error _ as e -> e
          | Ok () ->
            let q = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true stmt in
            Db.exec pool q ()
        ) (Ok ()) stmts in
        record_migration table pool version name
      )
      |> Result.map_error (fun e ->
        Storage_error.Migration_error (
          Printf.sprintf "migration %04d (%s) failed: %s"
            version name (Storage_error.to_string e)))
  ) (Ok ()) pending

let status ?(table = default_table) pool ~dir =
  let wrap msg = Result.map_error (fun e ->
    Storage_error.Migration_error (msg ^ Storage_error.to_string e))
  in
  let* () = ensure_table table pool |> wrap "create migrations table: " in
  let* migrations = read_migrations dir in
  let row_q = applied_at_q table in
  List.fold_right (fun (version, name, _) acc ->
    match acc with
    | Error _ as e -> e
    | Ok rows ->
      (match Db.find pool row_q version with
       | Error e -> Error e
       | Ok applied_at -> Ok ({ version; name; applied_at } :: rows))
  ) migrations (Ok [])

(** Roll back the last applied migration using a companion .down.sql file.
    Expects e.g. db/migrations/0001_notifications.down.sql alongside the up file. *)
let rollback ?(table = default_table) pool ~dir =
  let wrap msg = Result.map_error (fun e ->
    Storage_error.Migration_error (msg ^ Storage_error.to_string e))
  in
  let* () = ensure_table table pool |> wrap "create migrations table: " in
  match Db.find pool (last_applied_q table) () with
  | Error e -> Error e
  | Ok None ->
    Error (Storage_error.Migration_error
      "no migrations have been applied; nothing to roll back")
  | Ok (Some (version, name)) ->
    let down_file = Printf.sprintf "%04d_%s.down.sql" version name in
    let down_path = Filename.concat dir down_file in
    if not (Sys.file_exists down_path) then
      Error (Storage_error.Migration_error (Printf.sprintf
        "no down-migration file found for version %04d (%s).\n\
         Create %s with the reverse SQL and retry."
        version name down_path))
    else
      let content =
        match In_channel.with_open_text down_path In_channel.input_all with
        | s -> Ok s
        | exception Sys_error msg ->
          Error (Storage_error.Migration_error ("cannot read " ^ down_path ^ ": " ^ msg))
      in
      let* sql = content in
      Db.transaction pool (fun pool ->
        let stmts = split_statements sql in
        let* () = List.fold_left (fun acc stmt ->
          match acc with
          | Error _ as e -> e
          | Ok () ->
            let q = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit)
                      ~oneshot:true stmt in
            Db.exec pool q ()
        ) (Ok ()) stmts in
        Db.exec pool (delete_version_q table) version
        |> Result.map_error (fun e ->
          Storage_error.Migration_error (
            "update tracking table: " ^ Storage_error.to_string e))
      )
      |> Result.map_error (fun e ->
        Storage_error.Migration_error (
          Printf.sprintf "rollback %04d (%s) failed: %s"
            version name (Storage_error.to_string e)))
