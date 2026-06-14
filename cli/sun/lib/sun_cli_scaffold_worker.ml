let subst = Sun_cli_scaffold.subst
let write  = Sun_cli_scaffold.write_file
let cap    = Sun_cli_scaffold.capitalize_name

let worker_lib_ml = {tpl|(* Replace Message with your event module, e.g.:
     module Message = My_team_events.My_event *)
module Message = struct
  type t = { id : string }
  let topic_name = "{{domain}}-{{name}}-events"
  let schema = {|{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}|}
  let encode t = `Assoc [("id", `String t.id)]
  let decode = function
    | `Assoc fields ->
      (match List.assoc_opt "id" fields with
       | Some (`String id) -> Ok { id }
       | _ -> Error "missing id")
    | _ -> Error "expected object"
end

let group_id = "{{domain}}-{{name}}-worker"

let handle (msg : Message.t) ~ack ~trace_ctx:_ =
  Printf.printf "[{{name}}-worker] received id=%s\n%!" msg.id;
  (* Add side effects here. Call ack() only after all side effects succeed.
     Returning Error without acking causes the message to be retried. *)
  ack ();
  Ok ()
|tpl}

let worker_lib_dune = {tpl|(library
 (name {{lib}})
 (wrapped false)
 (modules {{Mod}})
 (libraries kafka_eio_service yojson))
|tpl}

let worker_bin_ml = {tpl|let () = Eio_main.run @@ fun env ->
  let config = Kafka_service.config_of_env () in
  let module W = Worker.Make({{Mod}}) in
  W.run ~env ~config ()
|tpl}

let worker_bin_dune = {tpl|(executable
 (name main)
 (libraries {{lib}} sun_worker kafka_eio_service eio_main))
|tpl}

let new_worker arg =
  let ws = Sun_cli_scaffold.ws_of_cwd () in
  let domain, name = Sun_cli_scaffold.parse_domain_name arg in
  let dir      = Printf.sprintf "app/%s/%s_worker" domain name in
  let repo_dir = dir in
  let lib      = Printf.sprintf "%s_%s_%s_worker" ws domain name in
  let mod_     = cap name ^ "_worker" in
  let v = [("lib", lib); ("dir", dir); ("repo_dir", repo_dir);
           ("name", name); ("domain", domain); ("Mod", mod_);
           ("binary", name ^ "-worker")] in
  Printf.printf "\nScaffolding worker %s/%s_worker ...\n\n" domain name;
  write ~path:(dir ^ "/lib/" ^ (Sun_cli_scaffold.normalize name) ^ "_worker.ml")
    ~content:(subst v worker_lib_ml);
  write ~path:(dir ^ "/lib/dune")    ~content:(subst v worker_lib_dune);
  write ~path:(dir ^ "/bin/main.ml") ~content:(subst v worker_bin_ml);
  write ~path:(dir ^ "/bin/dune")    ~content:(subst v worker_bin_dune);
  write ~path:(dir ^ "/sun.toml")    ~content:Sun_cli_scaffold.tpl_sun_toml;
  write ~path:(dir ^ "/Dockerfile")  ~content:(subst v Sun_cli_scaffold.tpl_dockerfile);
  Printf.printf "\nDone.  Replace the stub Message module with your event module, then:\n";
  Printf.printf "  dune build %s/bin/main.exe\n" dir
