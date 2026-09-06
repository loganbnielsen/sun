let component_dir sun_home component =
  Filename.concat sun_home (Filename.concat "platform/components" component)

let read_json path =
  if not (Sys.file_exists path) then `Assoc []
  else
    try Yojson.Safe.from_file path
    with Yojson.Json_error msg ->
      Printf.eprintf "error: %s is not valid JSON: %s\n" path msg;
      exit 1

(* Deep merge: [override]'s object keys win over [base]'s on conflict, with
   nested objects merged recursively rather than replaced wholesale. Any
   other conflict (arrays, scalars, mismatched shapes) takes [override]
   outright -- matching Helm's own multi-values-file merge semantics, which
   this mirrors so a single JSON string can stand in for "common file then
   profile file" precedence. *)
let rec deep_merge (base : Yojson.Safe.t) (over : Yojson.Safe.t) : Yojson.Safe.t =
  match base, over with
  | `Assoc base_fields, `Assoc over_fields ->
    let merged = List.map (fun (k, v) ->
      match List.assoc_opt k over_fields with
      | Some v2 -> (k, deep_merge v v2)
      | None -> (k, v))
      base_fields
    in
    let added = List.filter (fun (k, _) -> not (List.mem_assoc k base_fields)) over_fields in
    `Assoc (merged @ added)
  | _, over -> over

let merged_values_yaml ~component ~profile =
  let sun_home = match Sun_cli_cmd_new.infer_sun_home () with
    | Some dir -> dir
    | None ->
      Printf.eprintf
        "error: cannot locate the Sun monorepo root to read platform/components/%s.\n"
        component;
      Printf.eprintf "  Set SUN_HOME to your Sun checkout and re-run:\n";
      Printf.eprintf "    export SUN_HOME=/path/to/sun\n";
      exit 1
  in
  let dir = component_dir sun_home component in
  let common = read_json (Filename.concat dir "values-common.json") in
  let profile_json = read_json (Filename.concat dir (Printf.sprintf "values-%s.json" profile)) in
  Yojson.Safe.pretty_to_string (deep_merge common profile_json)
