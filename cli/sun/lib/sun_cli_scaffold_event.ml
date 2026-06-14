let subst = Sun_cli_scaffold.subst
let write  = Sun_cli_scaffold.write_file
let cap    = Sun_cli_scaffold.capitalize_name

let event_ml = {tpl|type t = {
  id      : string;
  payload : string;
}

let topic_name = "{{team}}-{{name}}s"

let schema = {|{
  "type": "object",
  "properties": {
    "id":      { "type": "string" },
    "payload": { "type": "string" }
  },
  "required": ["id", "payload"]
}|}

let encode t = `Assoc [
  ("id",      `String t.id);
  ("payload", `String t.payload);
]

let decode = function
  | `Assoc fields ->
    let get_s k = match List.assoc_opt k fields with Some (`String s) -> Some s | _ -> None in
    (match get_s "id", get_s "payload" with
     | Some id, Some payload -> Ok { id; payload }
     | _ -> Error "missing required fields")
  | _ -> Error "expected object"
|tpl}

(* Append [new_mod] to the "(modules ...)" stanza in [path].
   Handles the standard single-line form "(modules Foo Bar)". *)
let patch_modules_stanza path new_mod =
  let ic = open_in path in
  let content = In_channel.input_all ic in
  close_in ic;
  let prefix = "(modules " in
  let plen = String.length prefix in
  let clen = String.length content in
  let rec find_prefix i =
    if i > clen - plen then None
    else if String.sub content i plen = prefix then Some (i + plen)
    else find_prefix (i + 1)
  in
  match find_prefix 0 with
  | None ->
    Printf.printf "  note: could not locate (modules ...) in %s — add %s manually\n" path new_mod
  | Some pos ->
    let rec find_close i depth =
      if i >= clen then clen
      else match content.[i] with
        | '(' -> find_close (i + 1) (depth + 1)
        | ')' -> if depth = 0 then i else find_close (i + 1) (depth - 1)
        | _   -> find_close (i + 1) depth
    in
    let close = find_close pos 0 in
    let updated =
      String.sub content 0 close
      ^ " " ^ new_mod
      ^ String.sub content close (clen - close)
    in
    let oc = open_out path in
    output_string oc updated;
    close_out oc;
    Printf.printf "  updated %s\n" path

let new_event arg =
  let ws = Sun_cli_scaffold.ws_of_cwd () in
  let team, name = Sun_cli_scaffold.parse_domain_name arg in
  let file    = Printf.sprintf "events/%s/%s.ml" team name in
  let dune_f  = Printf.sprintf "events/%s/dune"  team in
  let mod_    = cap name in
  let lib     = ws ^ "_" ^ team ^ "_events" in
  let v = [("team", team); ("name", name); ("Mod", mod_); ("lib", lib)] in
  Printf.printf "\nScaffolding event %s/%s ...\n\n" team name;
  if Sys.file_exists file then begin
    Printf.eprintf "error: %S already exists\n" file;
    exit 1
  end;
  write ~path:file ~content:(subst v event_ml);
  if Sys.file_exists dune_f then
    patch_modules_stanza dune_f mod_
  else begin
    write ~path:dune_f ~content:(subst v {tpl|(library
 (name {{lib}})
 (wrapped false)
 (modules {{Mod}})
 (libraries kafka_eio_service yojson))
|tpl});
  end;
  Printf.printf "\nDone.  Consumers add (libraries %s) to their dune files.\n" lib
