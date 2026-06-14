type warning =
  | Duplicate_topic    of string
  | Duplicate_subject  of string
  | Unreadable_dir     of { path : string; reason : string }
  | Malformed_metadata of { path : string; message : string }

type t = {
  services        : Sun_cli_manifest.service list;
  schedules       : (string * string) list;
  topics          : string list;
  schema_subjects : string list;
  migrations      : string list;
  infra           : Sun_cli_workspace.infra_requirements;
  warnings        : warning list;
}

let warning_to_string = function
  | Duplicate_topic s    -> Printf.sprintf "duplicate topic name: %s" s
  | Duplicate_subject s  -> Printf.sprintf "duplicate schema subject: %s" s
  | Unreadable_dir r     -> Printf.sprintf "unreadable directory %s: %s" r.path r.reason
  | Malformed_metadata m -> Printf.sprintf "malformed metadata in %s: %s" m.path m.message

(* ── Duplicate detection helper ────────────────────────────────────────────── *)

let partition_duplicates items =
  let counts = Hashtbl.create 16 in
  List.iter (fun s ->
    let n = try Hashtbl.find counts s with Not_found -> 0 in
    Hashtbl.replace counts s (n + 1)
  ) items;
  let dups = Hashtbl.fold (fun k v acc -> if v > 1 then k :: acc else acc) counts [] in
  let dups = List.sort_uniq String.compare dups in
  let unique = List.sort_uniq String.compare items in
  (unique, dups)

(* ── discover_topics ──────────────────────────────────────────────────────── *)

let discover_topics ~dir =
  let events_dir = Filename.concat dir "events" in
  if not (Sys.file_exists events_dir && Sys.is_directory events_dir) then ([], [])
  else begin
    let raw_topics = ref [] in
    let warnings   = ref [] in
    let marker = {|let topic_name = "|} in
    let ml = String.length marker in
    let scan_file path =
      try
        let ic = open_in path in
        let content = In_channel.input_all ic in
        close_in ic;
        let sl = String.length content in
        for i = 0 to sl - ml - 1 do
          if String.sub content i ml = marker then begin
            let j = ref (i + ml) in
            while !j < sl && content.[!j] <> '"' do incr j done;
            let name = String.sub content (i + ml) (!j - i - ml) in
            if name <> "" then raw_topics := name :: !raw_topics
          end
        done
      with Sys_error reason ->
        warnings := Unreadable_dir { path; reason } :: !warnings
    in
    let entries =
      try Sys.readdir events_dir
      with Sys_error reason ->
        warnings := Unreadable_dir { path = events_dir; reason } :: !warnings;
        [||]
    in
    Array.iter (fun fname ->
      let path = Filename.concat events_dir fname in
      if Sys.is_directory path then begin
        let children =
          try Sys.readdir path
          with Sys_error reason ->
            warnings := Unreadable_dir { path; reason } :: !warnings;
            [||]
        in
        Array.iter (fun child ->
          let child_path = Filename.concat path child in
          if not (Sys.is_directory child_path) && Filename.check_suffix child ".ml" then
            scan_file child_path
        ) children
      end else if Filename.check_suffix fname ".ml" then
        scan_file path
    ) entries;
    let (unique, dups) = partition_duplicates !raw_topics in
    let dup_warns = List.map (fun s -> Duplicate_topic s) dups in
    (unique, dup_warns @ !warnings)
  end

(* ── discover_schema_subjects ─────────────────────────────────────────────── *)

let discover_schema_subjects ~dir =
  let events_dir = Filename.concat dir "events" in
  if not (Sys.file_exists events_dir && Sys.is_directory events_dir) then ([], [])
  else begin
    let raw_subjects = ref [] in
    let warnings     = ref [] in
    let entries =
      try Sys.readdir events_dir
      with Sys_error reason ->
        warnings := Unreadable_dir { path = events_dir; reason } :: !warnings;
        [||]
    in
    Array.iter (fun entry ->
      let path = Filename.concat events_dir entry in
      if Sys.is_directory path && entry.[0] <> '.' then begin
        let children =
          try Sys.readdir path
          with Sys_error reason ->
            warnings := Unreadable_dir { path; reason } :: !warnings;
            [||]
        in
        Array.iter (fun fname ->
          if Filename.check_suffix fname ".ml" then begin
            let stem        = Filename.chop_suffix fname ".ml" in
            let capitalized = String.capitalize_ascii stem in
            raw_subjects := (entry ^ "." ^ capitalized) :: !raw_subjects
          end
        ) children
      end else if Filename.check_suffix entry ".ml" then begin
        let stem = Filename.chop_suffix entry ".ml" in
        raw_subjects := stem :: !raw_subjects
      end
    ) entries;
    let (unique, dups) = partition_duplicates !raw_subjects in
    let dup_warns = List.map (fun s -> Duplicate_subject s) dups in
    (unique, dup_warns @ !warnings)
  end

(* ── discover_migrations ──────────────────────────────────────────────────── *)

let discover_migrations ~dir =
  let mig_dir = Filename.concat dir "db/migrations" in
  if not (Sys.file_exists mig_dir && Sys.is_directory mig_dir) then ([], [])
  else begin
    try
      let files = Sys.readdir mig_dir in
      Array.sort String.compare files;
      let sql = Array.to_list files
        |> List.filter (fun f -> Filename.check_suffix f ".sql")
      in
      (sql, [])
    with Sys_error reason ->
      ([], [Unreadable_dir { path = mig_dir; reason }])
  end

(* ── discover_services ────────────────────────────────────────────────────── *)

(** Non-exiting variant of [Sun_cli_manifest.discover_services].
    Returns an empty list with an [Unreadable_dir] warning when [app/] is missing
    or unreadable, rather than calling [exit 1]. *)
let discover_services ~dir =
  let app_dir = Filename.concat dir "app" in
  if not (Sys.file_exists app_dir && Sys.is_directory app_dir) then ([], [])
  else begin
    let services = ref [] in
    let warnings = ref [] in
    (try
      Array.iter (fun domain ->
        let dp = Filename.concat app_dir domain in
        if domain.[0] <> '.' && Sys.is_directory dp then
          (try
            Array.iter (fun svc_dir ->
              let sp = Filename.concat dp svc_dir in
              if svc_dir.[0] <> '.' && Sys.is_directory sp then
                match Sun_cli_manifest.prim_of_suffix svc_dir with
                | None -> ()
                | Some prim ->
                  if Sys.file_exists (Filename.concat sp "Dockerfile") then
                    services := Sun_cli_manifest.{ domain; name = svc_dir; prim; dir = sp }
                      :: !services
            ) (Sys.readdir dp)
          with Sys_error reason ->
            warnings := Unreadable_dir { path = dp; reason } :: !warnings)
      ) (Sys.readdir app_dir)
    with Sys_error reason ->
      warnings := Unreadable_dir { path = app_dir; reason } :: !warnings);
    (List.rev !services, !warnings)
  end

(* ── discover_schedules ───────────────────────────────────────────────────── *)

(** A minimal cron-expression check: exactly 5 space-separated fields. *)
let cron_is_valid s =
  let fields = List.filter (fun f -> f <> "")
    (String.split_on_char ' ' (String.trim s)) in
  List.length fields = 5

(** Extract schedule cron strings for all [-fn] services.  Emits
    [Malformed_metadata] for any cron expression that fails the 5-field check. *)
let discover_schedules services =
  let schedules = ref [] in
  let warnings  = ref [] in
  List.iter (fun (svc : Sun_cli_manifest.service) ->
    if svc.prim = Sun_cli_manifest.Fn then begin
      let cron = Sun_cli_manifest.extract_schedule ~dir:svc.dir ~name:svc.name in
      if not (cron_is_valid cron) then begin
        let path = Printf.sprintf "%s/lib/%s_fn.ml" svc.dir
          (String.sub svc.name 0 (String.length svc.name - 3)) in
        warnings := Malformed_metadata {
          path;
          message = Printf.sprintf "schedule = %S is not a valid 5-field cron expression" cron
        } :: !warnings
      end else
        schedules := (svc.name, cron) :: !schedules
    end
  ) services;
  (List.rev !schedules, List.rev !warnings)

(* ── scan ─────────────────────────────────────────────────────────────────── *)

let scan ~dir =
  let infra                            = Sun_cli_workspace.scan ~dir in
  let (services,   svc_warnings)       = discover_services ~dir in
  let (schedules,  sched_warnings)     = discover_schedules services in
  let (topics,     topic_warnings)     = discover_topics ~dir in
  let (subjects,   subject_warnings)   = discover_schema_subjects ~dir in
  let (migrations, mig_warnings)       = discover_migrations ~dir in
  let warnings =
    svc_warnings @ sched_warnings @ topic_warnings @ subject_warnings @ mig_warnings
  in
  { services
  ; schedules
  ; topics
  ; schema_subjects = subjects
  ; migrations
  ; infra
  ; warnings
  }
