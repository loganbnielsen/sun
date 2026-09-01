type target = {
  name               : string;
  env                : string;
  provider           : string;
  region             : string;
  registry           : string option;
  base_domain        : string option;
  cluster_name       : string option;
  terraform_var_file : string option;
}

type resource = {
  name          : string;
  typ           : string option;
  partition_key : string option;
  sort_key      : string option;
  indexes       : string list;
  omit          : bool;
}

type service = {
  name      : string;
  typ       : string option;
  path      : string option;
  uses      : string list;
  scale_min : int option;
  scale_max : int option;
  omit      : bool;
}

type t = {
  project   : string option;
  target    : target option;
  resources : resource list;
  services  : service list;
}

let empty = { project = None; target = None; resources = []; services = [] }

type error = { path : string; line : int; message : string }

let error_to_string e = Printf.sprintf "%s:%d: %s" e.path e.line e.message
let ( let* ) = Result.bind

let trim = String.trim

let strip_comment s =
  match String.index_opt s '#' with
  | None -> s
  | Some i -> String.sub s 0 i

let indent s =
  let rec loop i =
    if i < String.length s && s.[i] = ' ' then loop (i + 1) else i
  in
  loop 0

let ends_with ~suffix s =
  let slen = String.length suffix in
  let len = String.length s in
  len >= slen && String.sub s (len - slen) slen = suffix

let drop_suffix ~suffix s =
  String.sub s 0 (String.length s - String.length suffix)

let strip_quotes s =
  let s = trim s in
  let len = String.length s in
  if len >= 2 && s.[0] = '"' && s.[len - 1] = '"' then
    String.sub s 1 (len - 2)
  else s

let split_key_value s =
  match String.index_opt s ':' with
  | None -> None
  | Some i ->
    Some (trim (String.sub s 0 i),
          trim (String.sub s (i + 1) (String.length s - i - 1)))

let parse_list s =
  let s = trim s in
  let len = String.length s in
  if len >= 2 && s.[0] = '[' && s.[len - 1] = ']' then
    String.sub s 1 (len - 2)
    |> String.split_on_char ','
    |> List.map (fun v -> strip_quotes (trim v))
    |> List.filter ((<>) "")
  else if s = "" then []
  else [strip_quotes s]

let parse_int s = try Some (int_of_string (trim s)) with _ -> None

let parse_bool s =
  match trim s with
  | "true" -> true
  | _ -> false

let upsert_by_name name key update xs =
  let rec loop acc = function
    | [] -> List.rev (update None :: acc)
    | x :: rest when name x = key ->
      List.rev_append acc (update (Some x) :: rest)
    | x :: rest -> loop (x :: acc) rest
  in
  loop [] xs

let resource_empty name = {
  name; typ = None; partition_key = None; sort_key = None; indexes = [];
  omit = false;
}

let service_empty name = {
  name; typ = None; path = None; uses = []; scale_min = None; scale_max = None;
  omit = false;
}

type section =
  | None_section
  | Target
  | Resources
  | Resource of string
  | Resource_indexes of string
  | Services
  | Service of string
  | Service_scale of string

type root_section = No_root | Resources_root | Services_root

let load path =
  if not (Sys.file_exists path) then Ok empty
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let cfg = ref empty in
         let section = ref None_section in
         let root = ref No_root in
         let line_no = ref 0 in
         let fail message = Error { path; line = !line_no; message } in
         let rec loop () =
           match input_line ic with
           | exception End_of_file -> Ok !cfg
           | raw ->
             incr line_no;
             let text = strip_comment raw in
             if trim text = "" then loop ()
             else
               let ind = indent text in
               let body = trim text in
               match ind, body, split_key_value body with
               | 0, "target:", _ -> section := Target; loop ()
               | 0, "resources:", _ -> root := Resources_root; section := Resources; loop ()
               | 0, "services:", _ -> root := Services_root; section := Services; loop ()
               | 0, _, Some ("project", v) ->
                 cfg := { !cfg with project = Some (strip_quotes v) }; loop ()
               | 2, _, _ when ends_with ~suffix:":" body ->
                 let name = drop_suffix ~suffix:":" body |> trim in
                 begin match !root with
                 | Resources_root -> section := Resource name;
                   cfg := { !cfg with resources = upsert_by_name
                              (fun (r : resource) -> r.name) name
                              (function Some r -> r | None -> resource_empty name)
                              !cfg.resources }
                 | Services_root -> section := Service name;
                   cfg := { !cfg with services = upsert_by_name
                              (fun (s : service) -> s.name) name
                              (function Some s -> s | None -> service_empty name)
                              !cfg.services }
                 | No_root -> ()
                 end;
                 loop ()
               | 2, _, Some (k, v) ->
                 begin match !section with
                 | Target ->
                   let current = Option.value !cfg.target ~default:{
                     name = ""; env = ""; provider = ""; region = "";
                     registry = None; base_domain = None; cluster_name = None;
                     terraform_var_file = None;
                   } in
                   let target =
                     match k with
                     | "registry" -> { current with registry = Some (strip_quotes v) }
                     | "base_domain" -> { current with base_domain = Some (strip_quotes v) }
                     | "cluster_name" -> { current with cluster_name = Some (strip_quotes v) }
                     | "terraform_var_file" -> { current with terraform_var_file = Some (strip_quotes v) }
                     | _ -> current
                   in
                   cfg := { !cfg with target = Some target }
                 | _ -> ()
                 end;
                 loop ()
               | 4, _, Some (k, v) ->
                 begin match !section with
                 | Resource name ->
                   if k = "indexes" && v = "" then section := Resource_indexes name
                   else
                     let update old =
                       let r = Option.value old ~default:(resource_empty name) in
                       match k with
                       | "type" -> { r with typ = Some (strip_quotes v) }
                       | "partition_key" -> { r with partition_key = Some (strip_quotes v) }
                       | "sort_key" -> { r with sort_key = Some (strip_quotes v) }
                       | "omit" -> { r with omit = parse_bool v }
                       | _ -> r
                     in
                     cfg := { !cfg with resources = upsert_by_name
                                (fun (r : resource) -> r.name) name update !cfg.resources }
                 | Service name ->
                   if k = "scale" && v = "" then section := Service_scale name
                   else
                     let update old =
                       let s = Option.value old ~default:(service_empty name) in
                       match k with
                       | "type" -> { s with typ = Some (strip_quotes v) }
                       | "path" -> { s with path = Some (strip_quotes v) }
                       | "uses" -> { s with uses = parse_list v }
                       | "omit" -> { s with omit = parse_bool v }
                       | _ -> s
                     in
                     cfg := { !cfg with services = upsert_by_name
                                (fun (s : service) -> s.name) name update !cfg.services }
                 | _ -> ()
                 end;
                 loop ()
               | 6, _, _ when ends_with ~suffix:":" body ->
                 begin match !section with
                 | Resource_indexes resource_name ->
                   let index_name = drop_suffix ~suffix:":" body |> trim in
                   let update old =
                     let r = Option.value old ~default:(resource_empty resource_name) in
                     if List.mem index_name r.indexes then r
                     else { r with indexes = r.indexes @ [index_name] }
                   in
                   cfg := { !cfg with resources = upsert_by_name
                              (fun (r : resource) -> r.name) resource_name update
                              !cfg.resources }
                 | _ -> ()
                 end;
                 loop ()
               | 6, _, Some (k, v) ->
                 begin match !section with
                 | Service_scale name ->
                   let update old =
                     let s = Option.value old ~default:(service_empty name) in
                     match k with
                     | "min" -> { s with scale_min = parse_int v }
                     | "max" -> { s with scale_max = parse_int v }
                     | _ -> s
                   in
                   cfg := { !cfg with services = upsert_by_name
                              (fun (s : service) -> s.name) name update !cfg.services }
                 | _ -> ()
                 end;
                 loop ()
               | 8, _, Some _ -> loop ()
               | _ -> fail "unsupported sun.yml syntax"
         in
         loop ())

let prefer a b = match b with Some _ -> b | None -> a
let prefer_list a b = if b = [] then a else b

let merge_target a b = {
  a with
  registry = prefer a.registry b.registry;
  base_domain = prefer a.base_domain b.base_domain;
  cluster_name = prefer a.cluster_name b.cluster_name;
  terraform_var_file = prefer a.terraform_var_file b.terraform_var_file;
}

let merge_resource (a : resource) (b : resource) = {
  name = a.name;
  typ = prefer a.typ b.typ;
  partition_key = prefer a.partition_key b.partition_key;
  sort_key = prefer a.sort_key b.sort_key;
  indexes = prefer_list a.indexes b.indexes;
  omit = b.omit || a.omit;
}

let merge_service (a : service) (b : service) = {
  name = a.name;
  typ = prefer a.typ b.typ;
  path = prefer a.path b.path;
  uses = prefer_list a.uses b.uses;
  scale_min = prefer a.scale_min b.scale_min;
  scale_max = prefer a.scale_max b.scale_max;
  omit = b.omit || a.omit;
}

let merge_by name merge xs ys =
  List.fold_left (fun acc y ->
    upsert_by_name name (name y)
      (function
        | None -> y
        | Some x -> merge x y)
      acc)
    xs ys

let merge base overlay = {
  project = prefer base.project overlay.project;
  target =
    (match base.target, overlay.target with
     | None, t | t, None -> t
     | Some a, Some b -> Some (merge_target a b));
  resources = merge_by (fun (r : resource) -> r.name) merge_resource
      base.resources overlay.resources;
  services = merge_by (fun (s : service) -> s.name) merge_service
      base.services overlay.services;
}

let target_of_path s =
  match String.split_on_char '/' s with
  | [env; provider; region] when env <> "" && provider <> "" && region <> "" ->
    Ok { name = s; env; provider; region; registry = None; base_domain = None;
         cluster_name = None; terraform_var_file = None }
  | _ ->
    Error { path = s; line = 0;
            message = "target must look like <env>/<provider>/<region>" }

let target_file target =
  Filename.concat "sun"
    (Filename.concat target.env
       (Filename.concat target.provider (target.region ^ ".yml")))

let load_for_target ~target =
  let* target = target_of_path target in
  let* base = load "sun.yml" in
  let* overlay = load (target_file target) in
  Ok (merge { base with target = Some target } overlay)

let target cfg = cfg.target

let resources cfg =
  List.filter (fun (r : resource) -> not r.omit) cfg.resources

let services cfg =
  List.filter (fun (s : service) -> not s.omit) cfg.services

let terraform_vars cfg =
  match cfg.target with
  | None -> Error "target missing"
  | Some target ->
    let add_opt k = function None -> Fun.id | Some v -> fun xs -> (k ^ "=" ^ v) :: xs in
    let vars =
      []
      |> add_opt "region" (Some target.region)
      |> add_opt "cluster_name" target.cluster_name
      |> add_opt "base_domain" target.base_domain
    in
    let has_postgres =
      resources cfg
      |> List.exists (fun (r : resource) -> r.typ = Some "postgres")
    in
    Ok (("create_rds=" ^ string_of_bool has_postgres) :: vars)
