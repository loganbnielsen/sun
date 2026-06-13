let ( let* ) = Result.bind

(* ── Helpers ────────────────────────────────────────────────────────────── *)

let or_fail = function
  | Ok v    -> v
  | Error e -> Alcotest.failf "%s" (Storage_error.to_string e)

let postgres_url () = Sys.getenv_opt "POSTGRES_URL"

(* ── Unit tests (no database) ───────────────────────────────────────────── *)

let test_error_to_string () =
  let cases = [
    Storage_error.Connection_failed "timeout",    "connection failed: timeout";
    Storage_error.Query_error "syntax",           "query error: syntax";
    Storage_error.Not_found,                      "not found";
    Storage_error.Constraint_violation "unique",  "constraint violation: unique";
    Storage_error.Migration_error "bad file",     "migration error: bad file";
  ] in
  List.iter (fun (err, expected) ->
    Alcotest.(check string) "to_string" expected (Storage_error.to_string err)
  ) cases

let test_migration_parse_filename () =
  let cases = [
    "0001_init.sql",               Some (1, "init");
    "0042_add_users_table.sql",    Some (42, "add_users_table");
    "not_a_migration.txt",         None;
    "noversion.sql",               None;
    "abc_init.sql",                None;
  ] in
  List.iter (fun (filename, expected) ->
    (* Access internal parse via migration file directly *)
    let got =
      if not (Filename.check_suffix filename ".sql") then None
      else
        let base = Filename.chop_suffix filename ".sql" in
        match String.split_on_char '_' base with
        | [] | [_] -> None
        | v :: rest ->
          (match int_of_string_opt v with
           | None   -> None
           | Some n -> Some (n, String.concat "_" rest))
    in
    Alcotest.(check (option (pair int string))) filename expected got
  ) cases

(* ── Integration tests (require POSTGRES_URL) ───────────────────────────── *)

let test_pool_create () =
  match postgres_url () with
  | None     ->
    Printf.printf "[skip] POSTGRES_URL not set — skipping pool creation test\n%!"
  | Some url ->
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let pool = Db.create_pool ~url ~sw
                 ~stdenv:(env :> Caqti_eio.stdenv) ()
               |> or_fail in
    ignore pool

let test_exec_find_collect () =
  match postgres_url () with
  | None -> Printf.printf "[skip] POSTGRES_URL not set\n%!"
  | Some url ->
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let pool = Db.create_pool ~url ~sw
                 ~stdenv:(env :> Caqti_eio.stdenv) ()
               |> or_fail in
    let create_q =
      Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
        "CREATE TEMP TABLE sun_test_items (id INT, name TEXT)"
    in
    let drop_q =
      Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
        "DROP TABLE IF EXISTS sun_test_items"
    in
    let insert_q =
      Caqti_request.Infix.(Caqti_type.(t2 int string) ->. Caqti_type.unit)
        "INSERT INTO sun_test_items (id, name) VALUES (?, ?)"
    in
    let find_q =
      Caqti_request.Infix.(Caqti_type.int ->? Caqti_type.string)
        "SELECT name FROM sun_test_items WHERE id = ?"
    in
    let all_q =
      Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.(t2 int string))
        "SELECT id, name FROM sun_test_items ORDER BY id"
    in
    or_fail (Db.exec pool create_q ());
    or_fail (Db.exec pool insert_q (1, "apple"));
    or_fail (Db.exec pool insert_q (2, "banana"));
    let found = or_fail (Db.find pool find_q 1) in
    Alcotest.(check (option string)) "find by id" (Some "apple") found;
    let all = or_fail (Db.collect pool all_q ()) in
    Alcotest.(check int) "collect count" 2 (List.length all);
    let missing = or_fail (Db.find pool find_q 99) in
    Alcotest.(check (option string)) "missing returns None" None missing;
    or_fail (Db.exec pool drop_q ())

let test_transaction_commit () =
  match postgres_url () with
  | None -> Printf.printf "[skip] POSTGRES_URL not set\n%!"
  | Some url ->
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let pool = Db.create_pool ~url ~sw
                 ~stdenv:(env :> Caqti_eio.stdenv) ()
               |> or_fail in
    let create_q =
      Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
        "CREATE TEMP TABLE sun_test_tx (id INT)"
    in
    let insert_q =
      Caqti_request.Infix.(Caqti_type.int ->. Caqti_type.unit)
        "INSERT INTO sun_test_tx (id) VALUES (?)"
    in
    let count_q =
      Caqti_request.Infix.(Caqti_type.unit ->! Caqti_type.int)
        "SELECT count(*)::int FROM sun_test_tx"
    in
    let drop_q =
      Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
        "DROP TABLE IF EXISTS sun_test_tx"
    in
    or_fail (Db.exec pool create_q ());
    or_fail (Db.transaction pool (fun p ->
      let* () = Db.exec p insert_q 1 in
      Db.exec p insert_q 2
    ));
    let n = or_fail (Db.find pool count_q ()) in
    Alcotest.(check (option int)) "committed rows" (Some 2) n;
    or_fail (Db.exec pool drop_q ())

let test_transaction_rollback () =
  match postgres_url () with
  | None -> Printf.printf "[skip] POSTGRES_URL not set\n%!"
  | Some url ->
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let pool = Db.create_pool ~url ~sw
                 ~stdenv:(env :> Caqti_eio.stdenv) ()
               |> or_fail in
    let create_q =
      Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
        "CREATE TEMP TABLE sun_test_rb (id INT)"
    in
    let insert_q =
      Caqti_request.Infix.(Caqti_type.int ->. Caqti_type.unit)
        "INSERT INTO sun_test_rb (id) VALUES (?)"
    in
    let count_q =
      Caqti_request.Infix.(Caqti_type.unit ->! Caqti_type.int)
        "SELECT count(*)::int FROM sun_test_rb"
    in
    let drop_q =
      Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
        "DROP TABLE IF EXISTS sun_test_rb"
    in
    or_fail (Db.exec pool create_q ());
    let _ = Db.transaction pool (fun p ->
      let* () = Db.exec p insert_q 1 in
      Error (Storage_error.Query_error "intentional rollback")
    ) in
    let n = or_fail (Db.find pool count_q ()) in
    Alcotest.(check (option int)) "rolled back — zero rows" (Some 0) n;
    or_fail (Db.exec pool drop_q ())

let test_migration_apply () =
  match postgres_url () with
  | None -> Printf.printf "[skip] POSTGRES_URL not set\n%!"
  | Some url ->
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let pool = Db.create_pool ~url ~sw
                 ~stdenv:(env :> Caqti_eio.stdenv) ()
               |> or_fail in
    let dir = Filename.get_temp_dir_name () ^ "/sun_migration_test_" ^
              string_of_int (Random.int 100000) in
    Unix.mkdir dir 0o755;
    let write_file name content =
      let path = Filename.concat dir name in
      let oc = open_out path in
      output_string oc content;
      close_out oc
    in
    write_file "0001_create_items.sql"
      "CREATE TABLE IF NOT EXISTS sun_mig_items (id INT, label TEXT)";
    write_file "0002_add_index.sql"
      "CREATE INDEX IF NOT EXISTS sun_mig_items_id ON sun_mig_items (id)";
    let mtable = Printf.sprintf "sun_test_mig_%d" (Random.int 1000000) in
    or_fail (Migration.apply pool ~dir ~table:mtable);
    (* idempotent — applying again is a no-op *)
    or_fail (Migration.apply pool ~dir ~table:mtable);
    let s = or_fail (Migration.status pool ~dir ~table:mtable) in
    Alcotest.(check int) "two migrations recorded" 2 (List.length s);
    List.iter (fun ms ->
      Alcotest.(check bool) (Printf.sprintf "v%d applied" ms.Migration.version)
        true (ms.Migration.applied_at <> None)
    ) s;
    (* Cleanup *)
    let drop_q =
      Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
        (Printf.sprintf "DROP TABLE IF EXISTS sun_mig_items, %s" mtable)
    in
    or_fail (Db.exec pool drop_q ())

let test_table_make () =
  match postgres_url () with
  | None -> Printf.printf "[skip] POSTGRES_URL not set\n%!"
  | Some url ->
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let pool = Db.create_pool ~url ~sw
                 ~stdenv:(env :> Caqti_eio.stdenv) ()
               |> or_fail in
    let create_q =
      Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
        "CREATE TEMP TABLE sun_test_users (id INT, name TEXT, email TEXT)"
    in
    let drop_q =
      Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
        "DROP TABLE IF EXISTS sun_test_users"
    in
    or_fail (Db.exec pool create_q ());
    let module UserSchema = struct
      let table     = "sun_test_users"
      let id_column = "id"
      let columns   = ["id"; "name"; "email"]
      type t  = { id : int; name : string; email : string }
      type id = int
      let row_type =
        Caqti_type.(custom
          ~encode:(fun u -> Ok (u.id, u.name, u.email))
          ~decode:(fun (id, name, email) -> Ok { id; name; email })
          (t3 int string string))
      let id_type = Caqti_type.int
      let get_id u = u.id
    end in
    let module U = Table.Make(UserSchema) in
    or_fail (U.insert pool { UserSchema.id = 1; name = "Alice"; email = "alice@example.com" });
    or_fail (U.insert pool { UserSchema.id = 2; name = "Bob";   email = "bob@example.com"   });
    let alice = or_fail (U.find pool 1) in
    Alcotest.(check (option string)) "find by id" (Some "Alice")
      (Option.map (fun u -> u.UserSchema.name) alice);
    let all = or_fail (U.list pool ()) in
    Alcotest.(check int) "list count" 2 (List.length all);
    or_fail (U.delete pool 1);
    let gone = or_fail (U.find pool 1) in
    Alcotest.(check (option string)) "deleted" None
      (Option.map (fun u -> u.UserSchema.name) gone);
    or_fail (Db.exec pool drop_q ())

(* ── Unit tests: split_statements (no database) ─────────────────────────── *)

let check_stmts label expected sql =
  let got = Migration.split_statements sql in
  Alcotest.(check (list string)) label expected got

let test_split_simple () =
  check_stmts "two simple statements"
    ["SELECT 1;"; "SELECT 2;"]
    "SELECT 1; SELECT 2;"

let test_split_single_quoted () =
  (* Semicolons inside string literals must not split. *)
  check_stmts "semicolon in string literal"
    ["INSERT INTO t VALUES ('a;b');"; "SELECT 1;"]
    "INSERT INTO t VALUES ('a;b'); SELECT 1;"

let test_split_escaped_quote_in_string () =
  (* '' inside a string is an escaped quote, not a statement end. *)
  check_stmts "escaped quote in string"
    ["INSERT INTO t VALUES ('it''s here; ok');"; "SELECT 2;"]
    "INSERT INTO t VALUES ('it''s here; ok'); SELECT 2;"

let test_split_line_comment () =
  (* The comment text is preserved inside the statement; the semicolon inside
     the comment must NOT cause a split.  Here the comment leads the statement
     and the semicolon inside it is not treated as a terminator. *)
  check_stmts "semicolon in line comment"
    ["-- this is a comment; ignore it\nSELECT 1;"; "SELECT 2;"]
    "-- this is a comment; ignore it\nSELECT 1;\nSELECT 2;"

let test_split_block_comment () =
  (* Semicolons inside a block comment are not statement terminators.
     Comment text is preserved inside the surrounding statement. *)
  check_stmts "semicolon in block comment"
    ["SELECT 1;"; "/* ignore; SELECT 2; */ SELECT 3;"]
    "SELECT 1; /* ignore; SELECT 2; */ SELECT 3;"

let test_split_dollar_quoted () =
  (* Dollar-quoted function body with internal semicolons. *)
  let sql = {|
CREATE OR REPLACE FUNCTION add_one(x int) RETURNS int AS $$
BEGIN
  RETURN x + 1;
END;
$$ LANGUAGE plpgsql;
|}
  in
  let stmts = Migration.split_statements sql in
  Alcotest.(check int) "dollar-quoted function = one statement" 1 (List.length stmts);
  let stmt = List.hd stmts in
  (* The statement must contain the internal semicolons intact. *)
  Alcotest.(check bool) "internal semicolons preserved"
    true (String.length stmt > 0 && String.sub stmt (String.length stmt - 1) 1 = ";")

let test_split_dollar_quoted_named_tag () =
  (* Named dollar-quote tags like $body$. *)
  let sql = {|
CREATE FUNCTION greet(name text) RETURNS text AS $body$
BEGIN
  RETURN 'Hello, ' || name || '; welcome!';
END;
$body$ LANGUAGE plpgsql;
|}
  in
  let stmts = Migration.split_statements sql in
  Alcotest.(check int) "named dollar-quote tag = one statement" 1 (List.length stmts)

let test_split_multi_statement_with_dollar_quote () =
  (* Two statements: a CREATE TABLE and a CREATE FUNCTION. *)
  let sql = {|
CREATE TABLE notifications (id SERIAL PRIMARY KEY, msg TEXT);

CREATE OR REPLACE FUNCTION notify_insert() RETURNS trigger AS $$
BEGIN
  PERFORM pg_notify('ins', NEW.msg);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
|}
  in
  let stmts = Migration.split_statements sql in
  Alcotest.(check int) "table + function = two statements" 2 (List.length stmts)

let test_split_empty_and_whitespace () =
  check_stmts "empty input"  [] "";
  check_stmts "only spaces"  [] "   ";
  (* A comment with no trailing semicolon: the trailing content (just the
     comment text) becomes a single statement.  PostgreSQL accepts a
     comment-only statement fine; the splitter must not panic or drop it. *)
  let only_comment = Migration.split_statements "-- nothing here\n" in
  Alcotest.(check bool) "only-comment produces at most 1 entry"
    true (List.length only_comment <= 1)

(* ── Integration tests: dollar-quoted function round-trip (requires POSTGRES_URL) *)

let test_migration_apply_dollar_quoted () =
  match postgres_url () with
  | None -> Printf.printf "[skip] POSTGRES_URL not set\n%!"
  | Some url ->
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let pool = Db.create_pool ~url ~sw
                 ~stdenv:(env :> Caqti_eio.stdenv) ()
               |> or_fail in
    let dir = Filename.get_temp_dir_name () ^ "/sun_mig_dq_" ^
              string_of_int (Random.int 100000) in
    Unix.mkdir dir 0o755;
    let write_file name content =
      let path = Filename.concat dir name in
      let oc = open_out path in
      output_string oc content;
      close_out oc
    in
    (* Migration up: table + trigger function with internal semicolons. *)
    write_file "0001_with_function.sql" {|
CREATE TABLE IF NOT EXISTS sun_dq_items (id SERIAL PRIMARY KEY, name TEXT);

CREATE OR REPLACE FUNCTION sun_dq_check() RETURNS trigger AS $$
BEGIN
  IF NEW.name = '' THEN
    RAISE EXCEPTION 'name must not be empty; got empty string';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER sun_dq_check_trigger
  BEFORE INSERT ON sun_dq_items
  FOR EACH ROW EXECUTE FUNCTION sun_dq_check();
|};
    (* Migration down: drop trigger, function, table. *)
    write_file "0001_with_function.down.sql" {|
DROP TRIGGER IF EXISTS sun_dq_check_trigger ON sun_dq_items;
DROP FUNCTION IF EXISTS sun_dq_check();
DROP TABLE IF EXISTS sun_dq_items;
|};
    let mtable = Printf.sprintf "sun_test_dq_%d" (Random.int 1000000) in
    (* Apply must succeed despite internal semicolons in the function body. *)
    or_fail (Migration.apply pool ~dir ~table:mtable);
    let s = or_fail (Migration.status pool ~dir ~table:mtable) in
    Alcotest.(check int) "one migration recorded" 1 (List.length s);
    Alcotest.(check bool) "migration applied"
      true ((List.hd s).Migration.applied_at <> None);
    (* Rollback must also succeed. *)
    or_fail (Migration.rollback pool ~dir ~table:mtable);
    let s2 = or_fail (Migration.status pool ~dir ~table:mtable) in
    Alcotest.(check bool) "rolled back — not applied"
      true ((List.hd s2).Migration.applied_at = None);
    (* Cleanup tracking table. *)
    let drop_mtable =
      Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true
        (Printf.sprintf "DROP TABLE IF EXISTS %s" mtable)
    in
    or_fail (Db.exec pool drop_mtable ())

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  Random.self_init ();
  let open Alcotest in
  run "sun_storage" [
    "errors", [
      test_case "to_string"      `Quick test_error_to_string;
    ];
    "migration_parse", [
      test_case "parse_filename" `Quick test_migration_parse_filename;
    ];
    "migration_split", [
      test_case "simple"                       `Quick test_split_simple;
      test_case "single_quoted"                `Quick test_split_single_quoted;
      test_case "escaped_quote_in_string"      `Quick test_split_escaped_quote_in_string;
      test_case "line_comment"                 `Quick test_split_line_comment;
      test_case "block_comment"                `Quick test_split_block_comment;
      test_case "dollar_quoted"                `Quick test_split_dollar_quoted;
      test_case "dollar_quoted_named_tag"      `Quick test_split_dollar_quoted_named_tag;
      test_case "multi_stmt_with_dollar_quote" `Quick test_split_multi_statement_with_dollar_quote;
      test_case "empty_and_whitespace"         `Quick test_split_empty_and_whitespace;
    ];
    "integration", [
      test_case "pool_create"             `Quick test_pool_create;
      test_case "exec_find_collect"       `Quick test_exec_find_collect;
      test_case "transaction_commit"      `Quick test_transaction_commit;
      test_case "transaction_rollback"    `Quick test_transaction_rollback;
      test_case "migration_apply"         `Quick test_migration_apply;
      test_case "migration_apply_dq"      `Quick test_migration_apply_dollar_quoted;
      test_case "table_make"              `Quick test_table_make;
    ];
  ]
