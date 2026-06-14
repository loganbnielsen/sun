let subst = Sun_cli_scaffold.subst
let write  = Sun_cli_scaffold.write_file
let cap    = Sun_cli_scaffold.capitalize_name

let fn_lib_ml = {tpl|let schedule = "0 * * * *"

let run () =
  Printf.printf "[{{name}}-fn] running\n%!";
  Ok ()
|tpl}

let fn_lib_dune = {tpl|(library
 (name {{lib}})
 (wrapped false)
 (modules {{Mod}}))
|tpl}

let fn_bin_ml = {tpl|let () = Eio_main.run @@ fun env ->
  let module F = Fn.Make({{Mod}}) in
  F.run ~env ()
|tpl}

let fn_bin_dune = {tpl|(executable
 (name main)
 (libraries {{lib}} sun_fn eio_main))
|tpl}

let new_fn arg =
  let ws = Sun_cli_scaffold.ws_of_cwd () in
  let domain, name = Sun_cli_scaffold.parse_domain_name arg in
  let dir      = Printf.sprintf "app/%s/%s_fn" domain name in
  let repo_dir = dir in
  let lib      = Printf.sprintf "%s_%s_%s_fn" ws domain name in
  let mod_     = cap name ^ "_fn" in
  let v = [("lib", lib); ("dir", dir); ("repo_dir", repo_dir);
           ("name", name); ("domain", domain); ("Mod", mod_);
           ("binary", name ^ "-fn")] in
  Printf.printf "\nScaffolding fn %s/%s_fn ...\n\n" domain name;
  write ~path:(dir ^ "/lib/" ^ (Sun_cli_scaffold.normalize name) ^ "_fn.ml")
    ~content:(subst v fn_lib_ml);
  write ~path:(dir ^ "/lib/dune")    ~content:(subst v fn_lib_dune);
  write ~path:(dir ^ "/bin/main.ml") ~content:(subst v fn_bin_ml);
  write ~path:(dir ^ "/bin/dune")    ~content:(subst v fn_bin_dune);
  write ~path:(dir ^ "/sun.toml")    ~content:Sun_cli_scaffold.tpl_sun_toml;
  write ~path:(dir ^ "/Dockerfile")  ~content:(subst v Sun_cli_scaffold.tpl_dockerfile);
  Printf.printf "\nDone.  Build: dune build %s/bin/main.exe\n" dir
