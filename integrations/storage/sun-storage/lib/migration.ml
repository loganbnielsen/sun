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

(* ── PostgreSQL-aware statement splitter ─────────────────────────────────── *)
(*
   Splits a SQL string into individual statements terminated by a top-level
   semicolon.  Correctly skips semicolons that appear inside:
     - Single-quoted string literals  ('...' with '' escape sequences)
     - Line comments                  (-- ... newline)
     - Block comments                 (/* ... */, non-nested)
     - Dollar-quoted body sections    ($tag$...$tag$, e.g. $$ or $body$)

   Each returned statement is trimmed; empty segments are dropped.
*)

let split_statements sql =
  let n     = String.length sql in
  let buf   = Buffer.create 256 in
  let stmts = ref [] in
  let i     = ref 0 in

  let at d  = if !i + d < n then sql.[!i + d] else '\x00' in
  let adv k = i := !i + k in
  let emit  () = Buffer.add_char buf sql.[!i]; adv 1 in

  (* Consume a single-quoted string; opening quote already emitted by caller. *)
  let read_single_quoted () =
    let continue = ref true in
    while !continue && !i < n do
      match sql.[!i] with
      | '\'' ->
        emit ();
        if !i < n && sql.[!i] = '\'' then emit ()  (* '' escape *)
        else continue := false
      | _ -> emit ()
    done
  in

  (* Consume a line comment (--) through end-of-line. *)
  let read_line_comment () =
    while !i < n && sql.[!i] <> '\n' do emit () done
  in

  (* Consume a block comment (/* ... */) — non-nested. *)
  let read_block_comment () =
    let continue = ref true in
    while !continue && !i < n do
      if sql.[!i] = '*' && at 1 = '/' then begin
        emit (); emit ();
        continue := false
      end else
        emit ()
    done
  in

  (* Try to consume a dollar-quoted section starting at !i (positioned on '$').
     Returns true and leaves !i after the closing tag if successful.
     Returns false and leaves !i unchanged if '$' is not a valid dollar-quote
     opener (e.g. it is a positional parameter like $1). *)
  let read_dollar_quoted () =
    let start = !i in
    let j = ref (start + 1) in
    (* Tag characters: letters, digits, underscore; terminated by '$'. *)
    while !j < n && sql.[!j] <> '$'
                  && sql.[!j] <> '\n'
                  && sql.[!j] <> ' '
                  && sql.[!j] <> '\t' do
      incr j
    done;
    if !j >= n || sql.[!j] <> '$' then begin
      (* Not a dollar-quote — emit the '$' literally. *)
      emit ();
      false
    end else begin
      let tag  = String.sub sql start (!j - start + 1) in
      let tlen = String.length tag in
      (* Emit the opening tag. *)
      Buffer.add_string buf tag;
      i := !j + 1;
      (* Scan for the matching closing tag. *)
      let found = ref false in
      while not !found && !i < n do
        if !i + tlen <= n && String.sub sql !i tlen = tag then begin
          Buffer.add_string buf tag;
          i := !i + tlen;
          found := true
        end else begin
          Buffer.add_char buf sql.[!i];
          incr i
        end
      done;
      true
    end
  in

  while !i < n do
    match sql.[!i] with
    | '\'' ->
      emit ();
      read_single_quoted ()

    | '-' when at 1 = '-' ->
      emit (); emit ();
      read_line_comment ()

    | '/' when at 1 = '*' ->
      emit (); emit ();
      read_block_comment ()

    | '$' ->
      ignore (read_dollar_quoted ())

    | ';' ->
      let s = String.trim (Buffer.contents buf) in
      if String.length s > 0 then stmts := s :: !stmts;
      Buffer.clear buf;
      adv 1

    | _ -> emit ()
  done;
  (* Flush any trailing content after the last semicolon. *)
  let trailing = String.trim (Buffer.contents buf) in
  if String.length trailing > 0 then stmts := trailing :: !stmts;
  List.rev_map (fun s -> s ^ ";") !stmts

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
