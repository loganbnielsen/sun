let subst = Sun_cli_scaffold.subst
let write  = Sun_cli_scaffold.write_file

let svc_handler_ml = {tpl|let routes = [
  Route.get "/health" ~auth:`Public (fun _req ->
    Response.ok "ok"
  );
]
|tpl}

let svc_lib_dune = {tpl|(library
 (name {{lib}})
 (wrapped false)
 (modules Handler)
 (libraries sun_svc))
|tpl}

let svc_bin_ml = {tpl|let () = Eio_main.run @@ fun env ->
  Service.run Handler.routes ~env ()
|tpl}

let svc_bin_dune = {tpl|(executable
 (name main)
 (libraries {{lib}} sun_svc eio_main))
|tpl}

let new_svc arg =
  let ws = Sun_cli_scaffold.ws_of_cwd () in
  let domain, name = Sun_cli_scaffold.parse_domain_name arg in
  let dir      = Printf.sprintf "app/%s/%s_svc" domain name in
  let repo_dir = dir in
  let lib      = Printf.sprintf "%s_%s_%s_svc" ws domain name in
  let v = [("lib", lib); ("dir", dir); ("repo_dir", repo_dir);
           ("name", name); ("domain", domain); ("binary", name ^ "-svc")] in
  Printf.printf "\nScaffolding svc %s/%s_svc ...\n\n" domain name;
  write ~path:(dir ^ "/lib/handler.ml") ~content:svc_handler_ml;
  write ~path:(dir ^ "/lib/dune")       ~content:(subst v svc_lib_dune);
  write ~path:(dir ^ "/bin/main.ml")    ~content:svc_bin_ml;
  write ~path:(dir ^ "/bin/dune")       ~content:(subst v svc_bin_dune);
  write ~path:(dir ^ "/sun.toml")       ~content:Sun_cli_scaffold.tpl_sun_toml;
  write ~path:(dir ^ "/Dockerfile")     ~content:(subst v Sun_cli_scaffold.tpl_dockerfile);
  Printf.printf "\nDone.  Build: dune build %s/bin/main.exe\n" dir
