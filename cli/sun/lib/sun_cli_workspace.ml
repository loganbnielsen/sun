type infra_requirements = {
  kafka      : bool;
  postgres   : bool;
  loki       : bool;
  prometheus : bool;
}

let contains_string ~needle s =
  let nl = String.length needle in
  let sl = String.length s in
  let found = ref false in
  for i = 0 to sl - nl do
    if not !found && String.sub s i nl = needle then
      found := true
  done;
  !found

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(** Count .sql files in [dir]/db/migrations.  Returns 0 if the directory does
    not exist.  Used by [sun up] to warn users about unapplied migrations. *)
let pending_migration_count ~dir =
  let mig_dir = Filename.concat dir "db/migrations" in
  if Sys.file_exists mig_dir && Sys.is_directory mig_dir then
    Array.fold_left
      (fun acc f ->
        if Filename.check_suffix f ".sql" && not (Filename.check_suffix f ".down.sql")
        then acc + 1 else acc)
      0
      (Sys.readdir mig_dir)
  else
    0

let skip_dirs = ["vendor"; "_build"; ".git"; "node_modules"; ".opam"]

let is_symlink path =
  (try (Unix.lstat path).Unix.st_kind = Unix.S_LNK with _ -> false)

let scan ~dir =
  let kafka      = ref false in
  let postgres   = ref false in
  let loki       = ref false in
  let prometheus = ref false in
  let rec collect d =
    (try
      Array.iter (fun entry ->
        if entry.[0] <> '.' then begin
          let path = Filename.concat d entry in
          if entry = "dune" then begin
            (try
              let content = read_file path in
              if contains_string ~needle:"kafka_eio_service"  content then kafka      := true;
              if contains_string ~needle:"sun_storage"        content then postgres   := true;
              if contains_string ~needle:"obs_eio_loki"       content then loki       := true;
              if contains_string ~needle:"obs_eio_prometheus" content then prometheus := true;
            with _ -> ())
          end else if Sys.is_directory path
                   && not (List.mem entry skip_dirs)
                   && not (is_symlink path) then
            collect path
        end
      ) (Sys.readdir d)
    with _ -> ())
  in
  collect dir;
  { kafka = !kafka; postgres = !postgres; loki = !loki; prometheus = !prometheus }
