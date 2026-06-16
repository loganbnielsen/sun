(* Fold over entries in [dir], silently returning [init] if the dir is absent. *)
let fold_dir dir ~init ~f =
  if not (Sys.file_exists dir && Sys.is_directory dir) then init
  else begin
    let acc = ref init in
    (try Array.iter (fun entry ->
       let path = Filename.concat dir entry in
       acc := f !acc entry path
     ) (Sys.readdir dir)
    with _ -> ());
    !acc
  end

(** Scan [events/<domain>/] subdirectories for [*.ml] files and derive schema
    subject names as ["<domain>.<EventName>"].  Also handles top-level
    [events/<event>.ml] files (no domain prefix).  Returns a sorted,
    deduplicated list. *)
let discover_schema_subjects () =
  let subjects = fold_dir "events" ~init:[] ~f:(fun acc entry path ->
    if entry.[0] = '.' then acc
    else if Sys.is_directory path then
      fold_dir path ~init:acc ~f:(fun acc2 fname _p ->
        if Filename.check_suffix fname ".ml" then
          (entry ^ "." ^ String.capitalize_ascii (Filename.chop_suffix fname ".ml")) :: acc2
        else acc2)
    else if Filename.check_suffix entry ".ml" then
      Filename.chop_suffix entry ".ml" :: acc
    else acc
  ) in
  List.sort_uniq String.compare subjects

(** Derive consumer group identifiers for worker identities.
    Convention: ["<workspace>.<domain>.<worker_name>"]. *)
let derive_consumer_groups workspace workers =
  List.map (fun (domain, source_name) ->
    Printf.sprintf "%s.%s.%s" workspace domain source_name
  ) workers
  |> List.sort_uniq String.compare

(** Scan [events/] for OCaml files containing [let topic_name = "..."] declarations.
    Searches both [events/*.ml] (top-level) and [events/*/*.ml] (one level deep),
    so domain-namespaced layouts such as [events/payments/charged.ml] are discovered. *)
let discover_topics () =
  let marker = {|let topic_name = "|} in
  let ml = String.length marker in
  let scan_file path =
    try
      let ic = open_in path in
      let content = In_channel.input_all ic in
      close_in ic;
      let sl = String.length content in
      let acc = ref [] in
      for i = 0 to sl - ml - 1 do
        if String.sub content i ml = marker then begin
          let j = ref (i + ml) in
          while !j < sl && content.[!j] <> '"' do incr j done;
          let name = String.sub content (i + ml) (!j - i - ml) in
          if name <> "" then acc := name :: !acc
        end
      done;
      !acc
    with _ -> []
  in
  let topics = fold_dir "events" ~init:[] ~f:(fun acc fname path ->
    if Sys.is_directory path then
      fold_dir path ~init:acc ~f:(fun acc2 child child_path ->
        if not (Sys.is_directory child_path) && Filename.check_suffix child ".ml" then
          scan_file child_path @ acc2
        else acc2)
    else if Filename.check_suffix fname ".ml" then
      scan_file path @ acc
    else acc
  ) in
  List.sort_uniq String.compare topics

(** Scan [db/migrations/] for SQL files, sorted by filename. *)
let discover_migrations () =
  let files = fold_dir "db/migrations" ~init:[] ~f:(fun acc f _path ->
    if Filename.check_suffix f ".sql" then f :: acc else acc
  ) in
  List.sort String.compare files
