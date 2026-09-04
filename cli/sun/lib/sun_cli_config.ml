type target = {
  name                   : string;
  env                    : string;
  provider               : string;
  region                 : string;
  registry               : string option;
  base_domain            : string option;
  cluster_name           : string option;
  terraform_var_file     : string option;
  observability_backend  : string option;
}

type resource = {
  name          : string;
  typ           : string option;
  partition_key : string option;
  sort_key      : string option;
  indexes       : string list;
  size          : string option;
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
  let rec loop quote i =
    if i >= String.length s then s
    else match s.[i] with
      | '"' when quote = None -> loop (Some '"') (i + 1)
      | '\'' when quote = None -> loop (Some '\'') (i + 1)
      | c when quote = Some c -> loop None (i + 1)
      | '#' when quote = None -> String.sub s 0 i
      | _ -> loop quote (i + 1)
  in
  loop None 0

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

let parse_scalar s =
  let s = trim s in
  let len = String.length s in
  if len = 0 then Ok s
  else if s.[0] = '"' || s.[0] = '\'' then
    if len >= 2 && s.[len - 1] = s.[0] then
      Ok (String.sub s 1 (len - 2))
    else Error "malformed quoted value"
  else if s.[len - 1] = '"' || s.[len - 1] = '\'' then
    Error "malformed quoted value"
  else Ok s

let split_key_value s =
  match String.index_opt s ':' with
  | None -> None
  | Some i ->
    Some (trim (String.sub s 0 i),
          trim (String.sub s (i + 1) (String.length s - i - 1)))

let parse_list s =
  let parse_items s =
    String.split_on_char ',' s
    |> List.map trim
    |> List.filter ((<>) "")
    |> List.fold_left (fun acc v ->
      let* xs = acc in
      let* v = parse_scalar v in
      Ok (xs @ [v])) (Ok [])
  in
  let s = trim s in
  let len = String.length s in
  if len >= 2 && s.[0] = '[' && s.[len - 1] = ']' then
    parse_items (String.sub s 1 (len - 2))
  else if len > 0 && (s.[0] = '[' || s.[len - 1] = ']') then
    Error "malformed list"
  else if s = "" then Ok []
  else
    let* v = parse_scalar s in
    Ok [v]

let parse_int s =
  match int_of_string_opt (trim s) with
  | Some i -> Ok (Some i)
  | None -> Error "expected integer"

let parse_bool s =
  match trim s with
  | "true" -> Ok true
  | "false" -> Ok false
  | _ -> Error "expected true or false"

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
  size = None; omit = false;
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
  | Target_provider
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
         let seen_target = ref false in
         let seen_resources = ref false in
         let seen_services = ref false in
         let line_no = ref 0 in
         let fail message = Error { path; line = !line_no; message } in
         let require_value k v =
           if v = "" then fail (Printf.sprintf "missing value for %s" k) else Ok ()
         in
         let scalar k v =
           match parse_scalar v with
           | Ok v -> Ok v
           | Error msg -> fail (msg ^ " for " ^ k)
         in
         let update_resource name f =
           let rec loop acc = function
             | [] -> fail (Printf.sprintf "resource %S is missing" name)
             | (r : resource) :: rest when r.name = name ->
               let* r = f r in
               Ok (List.rev_append acc (r :: rest))
             | r :: rest -> loop (r :: acc) rest
           in
           let* resources = loop [] !cfg.resources in
           cfg := { !cfg with resources };
           Ok ()
         in
         let update_service name f =
           let rec loop acc = function
             | [] -> fail (Printf.sprintf "service %S is missing" name)
             | (s : service) :: rest when s.name = name ->
               let* s = f s in
               Ok (List.rev_append acc (s :: rest))
             | s :: rest -> loop (s :: acc) rest
           in
           let* services = loop [] !cfg.services in
           cfg := { !cfg with services };
           Ok ()
         in
         let add_resource name =
           if List.exists (fun (r : resource) -> r.name = name) !cfg.resources then
             fail (Printf.sprintf "duplicate resource %S" name)
           else begin
             cfg := { !cfg with resources = !cfg.resources @ [resource_empty name] };
             Ok ()
           end
         in
         let add_service name =
           if List.exists (fun (s : service) -> s.name = name) !cfg.services then
             fail (Printf.sprintf "duplicate service %S" name)
           else begin
             cfg := { !cfg with services = !cfg.services @ [service_empty name] };
             Ok ()
           end
         in
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
               | _, _, _ when ind >= 4 && !section = Target_provider -> loop ()
               | 0, "target:", _ ->
                 if !seen_target then fail "duplicate top-level section \"target\""
                 else if !root <> No_root then fail "target must appear before resources or services"
                 else begin
                   seen_target := true;
                   root := No_root; section := Target; loop ()
                 end
               | 0, "resources:", _ ->
                 if !seen_resources then fail "duplicate top-level section \"resources\""
                 else begin
                   seen_resources := true;
                   root := Resources_root; section := Resources; loop ()
                 end
               | 0, "services:", _ ->
                 if !seen_services then fail "duplicate top-level section \"services\""
                 else begin
                   seen_services := true;
                   root := Services_root; section := Services; loop ()
                 end
               | 0, _, Some ("project", v) ->
                 let* () = require_value "project" v in
                 let* project = scalar "project" v in
                 cfg := { !cfg with project = Some project }; loop ()
               | 0, _, Some (k, _) -> fail (Printf.sprintf "unknown top-level key %S" k)
               | 2, _, _ when ends_with ~suffix:":" body ->
                 let name = drop_suffix ~suffix:":" body |> trim in
                 begin match !root with
                 | Resources_root ->
                   section := Resource name;
                   let* () = add_resource name in
                   loop ()
                 | Services_root ->
                   section := Service name;
                   let* () = add_service name in
                   loop ()
                 | No_root ->
                   begin match !section, split_key_value body with
                   | (Target | Target_provider), Some (k, "") when k = "aws" || k = "gcp" ->
                     section := Target_provider;
                     loop ()
                   | (Target | Target_provider), Some (k, "") ->
                     fail (Printf.sprintf "missing value for %s" k)
                   | _ -> fail "unsupported sun.yml syntax"
                   end
                 end
               | 2, _, Some (k, v) ->
                 let* () = begin match !section with
                 | Target | Target_provider ->
                   if (k = "aws" || k = "gcp") && v = "" then begin
                     section := Target_provider;
                     Ok ()
                   end else
                   let* () = require_value k v in
                   section := Target;
                   let current = Option.value !cfg.target ~default:{
                     name = ""; env = ""; provider = ""; region = "";
                     registry = None; base_domain = None; cluster_name = None;
                     terraform_var_file = None; observability_backend = None;
                   } in
                   let* target =
                     match k with
                     | "registry" ->
                       let* v = scalar k v in
                       Ok { current with registry = Some v }
                     | "base_domain" ->
                       let* v = scalar k v in
                       Ok { current with base_domain = Some v }
                     | "cluster_name" ->
                       let* v = scalar k v in
                       Ok { current with cluster_name = Some v }
                     | "terraform_var_file" ->
                       let* v = scalar k v in
                       Ok { current with terraform_var_file = Some v }
                     | "observability_backend" ->
                       let* v = scalar k v in
                       Ok { current with observability_backend = Some v }
                     | _ -> fail (Printf.sprintf "unknown target key %S" k)
                   in
                   cfg := { !cfg with target = Some target };
                   Ok ()
                 | _ -> fail "unsupported sun.yml syntax"
                 end in
                 loop ()
               | 4, _, Some (k, v) ->
                 let* () = begin match !section with
                 | Resource name | Resource_indexes name ->
                   if k = "indexes" && v = "" then begin
                     section := Resource_indexes name;
                     Ok ()
                   end
                   else
                     let* () = require_value k v in
                     let* () =
                       update_resource name (fun r ->
                       match k with
                       | "type" ->
                         let* v = scalar k v in
                         Ok { r with typ = Some v }
                       | "partition_key" ->
                         let* v = scalar k v in
                         Ok { r with partition_key = Some v }
                       | "sort_key" ->
                         let* v = scalar k v in
                         Ok { r with sort_key = Some v }
                       | "size" ->
                         let* v = scalar k v in
                         Ok { r with size = Some v }
                       | "omit" ->
                         (match parse_bool v with
                          | Ok omit -> Ok { r with omit }
                          | Error msg -> fail (msg ^ " for omit"))
                       | _ -> fail (Printf.sprintf "unknown resource key %S" k))
                     in
                     Ok ()
                 | Service name | Service_scale name ->
                   if k = "scale" && v = "" then begin
                     section := Service_scale name;
                     Ok ()
                   end
                   else
                     let* () = require_value k v in
                     let* () =
                       update_service name (fun s ->
                       match k with
                       | "type" ->
                         let* v = scalar k v in
                         Ok { s with typ = Some v }
                       | "path" ->
                         let* v = scalar k v in
                         Ok { s with path = Some v }
                       | "uses" ->
                         (match parse_list v with
                          | Ok uses -> Ok { s with uses }
                          | Error msg -> fail (msg ^ " for uses"))
                       | "omit" ->
                         (match parse_bool v with
                          | Ok omit -> Ok { s with omit }
                          | Error msg -> fail (msg ^ " for omit"))
                       | _ -> fail (Printf.sprintf "unknown service key %S" k))
                     in
                     Ok ()
                 | Target_provider -> Ok ()
                 | _ -> fail "unsupported sun.yml syntax"
                 end in
                 loop ()
               | 6, _, _ when ends_with ~suffix:":" body ->
                 let* () = begin match !section with
                 | Resource_indexes resource_name ->
                   let index_name = drop_suffix ~suffix:":" body |> trim in
                   let update old =
                     let r = Option.value old ~default:(resource_empty resource_name) in
                     if List.mem index_name r.indexes then
                       fail (Printf.sprintf "duplicate index %S" index_name)
                     else Ok { r with indexes = r.indexes @ [index_name] }
                   in
                   update_resource resource_name (fun r -> update (Some r))
                 | _ -> fail "unsupported sun.yml syntax"
                 end in
                 loop ()
               | 6, _, Some (k, v) ->
                 let* () = begin match !section with
                 | Service_scale name ->
                   let* () = require_value k v in
                   let* () =
                     update_service name (fun s ->
                     match k with
                     | "min" ->
                       (match parse_int v with
                        | Ok scale_min -> Ok { s with scale_min }
                        | Error msg -> fail (msg ^ " for min"))
                     | "max" ->
                       (match parse_int v with
                        | Ok scale_max -> Ok { s with scale_max }
                        | Error msg -> fail (msg ^ " for max"))
                     | _ -> fail (Printf.sprintf "unknown scale key %S" k))
                   in
                   Ok ()
                 | _ -> fail "unsupported sun.yml syntax"
                 end in
                 loop ()
               | 8, _, Some (k, _) ->
                 begin match !section with
                 | Resource_indexes _ when k = "partition_key" || k = "sort_key" -> loop ()
                 | _ -> fail (Printf.sprintf "unknown key %S" k)
                 end
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
  observability_backend = prefer a.observability_backend b.observability_backend;
}

let merge_resource (a : resource) (b : resource) = {
  name = a.name;
  typ = prefer a.typ b.typ;
  partition_key = prefer a.partition_key b.partition_key;
  sort_key = prefer a.sort_key b.sort_key;
  indexes = prefer_list a.indexes b.indexes;
  size = prefer a.size b.size;
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
  | [env; provider; region]
    when env <> "" && provider <> "" && region <> ""
         && env <> ".." && provider <> ".." && region <> ".." ->
    Ok { name = s; env; provider; region; registry = None; base_domain = None;
         cluster_name = None; terraform_var_file = None; observability_backend = None }
  | parts when List.exists ((=) "..") parts ->
    Error { path = s; line = 0; message = "target path must not contain '..'" }
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
  let base_target =
    match base.target with
    | None -> target
    | Some t -> { t with name = target.name; env = target.env;
                         provider = target.provider; region = target.region }
  in
  Ok (merge { base with target = Some base_target } overlay)

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
