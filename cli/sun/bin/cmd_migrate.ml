open Cmdliner

(* Derive the default migration table name from the workspace directory.
   Using a per-workspace name avoids version-number collisions when multiple
   workspaces share the same local Postgres instance (e.g. from sun dev up).
   The --table flag always overrides this default. *)
let default_table_name =
  let cwd_name = Filename.basename (Sys.getcwd ()) in
  let buf = Buffer.create (String.length cwd_name) in
  String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then Buffer.add_char buf c
    else if c >= 'A' && c <= 'Z' then Buffer.add_char buf (Char.lowercase_ascii c)
    else Buffer.add_char buf '_'
  ) cwd_name;
  Printf.sprintf "sun_%s_schema_migrations" (Buffer.contents buf)

let cluster_pg_exists () =
  Sys.command "kubectl get svc postgresql -n postgresql >/dev/null 2>&1" = 0

(* Start a background port-forward to cluster postgres and return the local URL.
   Registers at_exit cleanup so the forward is killed when the process exits. *)
let auto_forward_pg () =
  Printf.printf "Forwarding postgresql (cluster) → localhost:15432 ...\n%!";
  let devnull_w = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  let pid = Unix.create_process "kubectl"
    [|"kubectl"; "port-forward"; "svc/postgresql";
      "-n"; "postgresql"; "15432:5432"|]
    Unix.stdin devnull_w devnull_w
  in
  Unix.close devnull_w;
  Unix.sleepf 2.0;  (* give the port-forward time to establish *)
  at_exit (fun () ->
    (try Unix.kill pid Sys.sigterm with _ -> ());
    (try ignore (Unix.waitpid [Unix.WNOHANG] pid) with _ -> ()));
  "postgresql://postgres:dev@localhost:15432/dev"

let get_postgres_url () =
  match Sys.getenv_opt "POSTGRES_URL" with
  | Some u -> u
  | None ->
    if cluster_pg_exists () then
      auto_forward_pg ()
    else begin
      Printf.eprintf "error: POSTGRES_URL not set and no cluster postgres found.\n";
      Printf.eprintf "  Run 'sun dev up' first, then retry.\n";
      exit 1
    end

let with_pool url f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      match Db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
      | Error e ->
        Printf.eprintf "error: cannot connect to database: %s\n" (Storage_error.to_string e);
        exit 1
      | Ok pool -> f pool
    )
  )

(* ── apply ───────────────────────────────────────────────────────────────── *)

let run_apply dir table () =
  let url = get_postgres_url () in
  with_pool url (fun pool ->
    Printf.printf "Applying migrations from %s...\n%!" dir;
    match Migration.apply ~table pool ~dir with
    | Ok () -> Printf.printf "Done.\n"
    | Error e ->
      Printf.eprintf "error: %s\n" (Storage_error.to_string e);
      exit 1
  )

(* ── status ──────────────────────────────────────────────────────────────── *)

let run_status dir table () =
  let url = get_postgres_url () in
  with_pool url (fun pool ->
    match Migration.status ~table pool ~dir with
    | Error e ->
      Printf.eprintf "error: %s\n" (Storage_error.to_string e);
      exit 1
    | Ok rows ->
      Printf.printf "%-6s  %-30s  %s\n" "VER" "NAME" "APPLIED AT";
      Printf.printf "%s\n" (String.make 60 '-');
      List.iter (fun (s : Migration.status) ->
        Printf.printf "%-6d  %-30s  %s\n" s.version s.name
          (Option.value ~default:"(pending)" s.applied_at)
      ) rows
  )

(* ── rollback ────────────────────────────────────────────────────────────── *)

let run_rollback dir table () =
  let url = get_postgres_url () in
  with_pool url (fun pool ->
    match Migration.rollback ~table pool ~dir with
    | Ok () -> Printf.printf "Rolled back.\n"
    | Error e ->
      Printf.eprintf "error: %s\n" (Storage_error.to_string e);
      exit 1
  )

(* ── Cmdliner terms ──────────────────────────────────────────────────────── *)

let dir_arg =
  Arg.(value & opt string "db/migrations" &
       info ["dir"] ~docv:"DIR"
         ~doc:"Directory containing migration SQL files (default: db/migrations)")

let table_arg =
  Arg.(value & opt string default_table_name &
       info ["table"] ~docv:"TABLE"
         ~doc:"Migration tracking table name \
               (default: sun_<workspace>_schema_migrations; \
               override with this flag to share a table across workspaces)")

let apply_cmd =
  Cmd.v
    (Cmd.info "apply" ~doc:"Apply all pending migrations (default subcommand)")
    Term.(const run_apply $ dir_arg $ table_arg $ const ())

let status_cmd =
  Cmd.v
    (Cmd.info "status" ~doc:"Show per-file applied/pending status")
    Term.(const run_status $ dir_arg $ table_arg $ const ())

let rollback_cmd =
  Cmd.v
    (Cmd.info "rollback" ~doc:"Roll back the last applied migration")
    Term.(const run_rollback $ dir_arg $ table_arg $ const ())

let cmd =
  Cmd.group
    (Cmd.info "migrate"
       ~doc:"Run database migrations against POSTGRES_URL")
    ~default:Term.(const run_apply $ dir_arg $ table_arg $ const ())
    [ apply_cmd; status_cmd; rollback_cmd ]
