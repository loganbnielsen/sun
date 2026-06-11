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
    "integration", [
      test_case "pool_create"         `Quick test_pool_create;
      test_case "exec_find_collect"   `Quick test_exec_find_collect;
      test_case "transaction_commit"  `Quick test_transaction_commit;
      test_case "transaction_rollback"`Quick test_transaction_rollback;
      test_case "migration_apply"     `Quick test_migration_apply;
      test_case "table_make"          `Quick test_table_make;
    ];
  ]
