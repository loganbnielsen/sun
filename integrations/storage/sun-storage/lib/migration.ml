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

(* PostgreSQL-aware SQL splitter.  Correctly handles semicolons that appear
   inside single-quoted strings, line comments, block comments, and
   dollar-quoted bodies (PL/pgSQL functions, triggers, etc.). *)
let split_sql_statements sql =
  let n   = String.length sql in
  let buf = Buffer.create 256 in
  let acc = ref [] in
  let i   = ref 0 in
  let flush () =
    let s = String.trim (Buffer.contents buf) in
    if String.length s > 0 then acc := s :: !acc;
    Buffer.clear buf
  in
  while !i < n do
    let c = sql.[!i] in
    (match c with
    | '-' when !i + 1 < n && sql.[!i + 1] = '-' ->
      (* line comment: consume to end of line *)
      Buffer.add_char buf '-'; Buffer.add_char buf '-'; i := !i + 2;
      while !i < n && sql.[!i] <> '\n' do
        Buffer.add_char buf sql.[!i]; incr i
      done
    | '/' when !i + 1 < n && sql.[!i + 1] = '*' ->
      (* block comment: consume until closing *\/ *)
      Buffer.add_char buf '/'; Buffer.add_char buf '*'; i := !i + 2;
      let closed = ref false in
      while !i < n && not !closed do
        let ch = sql.[!i] in
        Buffer.add_char buf ch; incr i;
        if ch = '*' && !i < n && sql.[!i] = '/' then begin
          Buffer.add_char buf '/'; incr i; closed := true
        end
      done
    | '\'' ->
      (* single-quoted string; '' is an escaped quote *)
      Buffer.add_char buf '\''; incr i;
      let closed = ref false in
      while !i < n && not !closed do
        let ch = sql.[!i] in
        Buffer.add_char buf ch; incr i;
        if ch = '\'' then begin
          if !i < n && sql.[!i] = '\'' then begin
            Buffer.add_char buf '\''; incr i  (* escaped quote — stay in string *)
          end else closed := true
        end
      done
    | '$' ->
      (* dollar-quoting: $tag$...$tag$ where tag may be empty *)
      let j = ref (!i + 1) in
      while !j < n && sql.[!j] <> '$' && sql.[!j] <> '\n' && sql.[!j] <> ' ' do
        incr j
      done;
      if !j < n && sql.[!j] = '$' then begin
        let delim = String.sub sql !i (!j - !i + 1) in
        let dlen  = String.length delim in
        Buffer.add_string buf delim; i := !j + 1;
        let closed = ref false in
        while !i < n && not !closed do
          if !i + dlen <= n && String.sub sql !i dlen = delim then begin
            Buffer.add_string buf delim; i := !i + dlen; closed := true
          end else begin
            Buffer.add_char buf sql.[!i]; incr i
          end
        done
      end else begin
        Buffer.add_char buf '$'; incr i
      end
    | ';' ->
      flush (); incr i
    | _ ->
      Buffer.add_char buf c; incr i)
  done;
  flush ();
  List.rev !acc

(* SELECT/WITH/TABLE/VALUES statements return Tuples_ok; DDL returns Command_ok.
   Caqti requires the multiplicity to match, so we route accordingly. *)
let returns_rows stmt =
  let s = String.trim stmt in
  let n = String.length s in
  let i = ref 0 in
  while !i < n && Char.code s.[!i] > 32 && s.[!i] <> '(' do incr i done;
  let kw = String.uppercase_ascii (String.sub s 0 !i) in
  kw = "SELECT" || kw = "WITH" || kw = "TABLE" || kw = "VALUES"

let exec_statements pool stmts =
  List.fold_left (fun acc stmt ->
    match acc with
    | Error _ as e -> e
    | Ok () ->
      if returns_rows stmt then
        let q = Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.unit) ~oneshot:true stmt in
        (match Db.collect pool q () with
         | Ok _   -> Ok ()
         | Error e -> Error e)
      else
        let q = Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true stmt in
        Db.exec pool q ()
  ) (Ok ()) stmts

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
    let* () = acc in
    let* sql =
      match In_channel.with_open_text path In_channel.input_all with
      | s -> Ok s
      | exception Sys_error msg ->
        Error (Storage_error.Migration_error ("cannot read " ^ path ^ ": " ^ msg))
    in
    Db.transaction pool (fun pool ->
      let* () = exec_statements pool (split_sql_statements sql) in
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
    let* rows = acc in
    let* applied_at = Db.find pool row_q version in
    Ok ({ version; name; applied_at } :: rows)
  ) migrations (Ok [])

(** Roll back the last applied migration using a companion .down.sql file.
    Expects e.g. db/migrations/0001_notifications.down.sql alongside the up file. *)
let rollback ?(table = default_table) pool ~dir =
  let wrap msg = Result.map_error (fun e ->
    Storage_error.Migration_error (msg ^ Storage_error.to_string e))
  in
  let* () = ensure_table table pool |> wrap "create migrations table: " in
  let* last = Db.find pool (last_applied_q table) () in
  match last with
  | None ->
    Error (Storage_error.Migration_error
      "no migrations have been applied; nothing to roll back")
  | Some (version, name) ->
    let down_file = Printf.sprintf "%04d_%s.down.sql" version name in
    let down_path = Filename.concat dir down_file in
    if not (Sys.file_exists down_path) then
      Error (Storage_error.Migration_error (Printf.sprintf
        "no down-migration file found for version %04d (%s).\n\
         Create %s with the reverse SQL and retry."
        version name down_path))
    else
      let* sql =
        match In_channel.with_open_text down_path In_channel.input_all with
        | s -> Ok s
        | exception Sys_error msg ->
          Error (Storage_error.Migration_error ("cannot read " ^ down_path ^ ": " ^ msg))
      in
      Db.transaction pool (fun pool ->
        let* () = exec_statements pool (split_sql_statements sql) in
        Db.exec pool (delete_version_q table) version
        |> Result.map_error (fun e ->
          Storage_error.Migration_error (
            "update tracking table: " ^ Storage_error.to_string e))
      )
      |> Result.map_error (fun e ->
        Storage_error.Migration_error (
          Printf.sprintf "rollback %04d (%s) failed: %s"
            version name (Storage_error.to_string e)))
