let find_repo_root () =
  let rec go dir =
    if Sys.file_exists (Filename.concat dir "dune-workspace") then dir
    else if Sys.file_exists (Filename.concat dir "dune-project") then dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then dir
      else go parent
  in
  go (Sys.getcwd ())

(** Prepare a self-contained build context with `rsync --copy-links`,
    call [f ctx_dir], then remove the context directory regardless of outcome.
    Exits 1 if rsync fails. *)
let with_context ~repo_root f =
  let ctx_dir = repo_root ^ ".docker-ctx" in
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir)));
  Printf.printf "Preparing build context...\n%!";
  let rsync_cmd = Printf.sprintf
    "rsync -a --copy-links --exclude='_build' --exclude='.git' %s/ %s"
    (Filename.quote repo_root) (Filename.quote ctx_dir) in
  if Sys.command rsync_cmd <> 0 then begin
    Printf.eprintf "error: failed to copy workspace for docker build context\n";
    exit 1
  end;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote ctx_dir))))
    (fun () -> f ctx_dir)

(** Build and push a single service image. Returns [Error msg] on failure. *)
let build_and_push ~ctx_dir ~push_image ~source_dir =
  Printf.printf "  packaging %s...\n%!" push_image;
  if (Sun_process.run_argv ~echo:false
        ["docker"; "build"; "-t"; push_image;
         "-f"; Printf.sprintf "%s/%s/Dockerfile" ctx_dir source_dir;
         ctx_dir]).exit_code <> 0 then
    Error (Printf.sprintf "docker build failed: %s" source_dir)
  else begin
    Printf.printf "  pushing...\n%!";
    if (Sun_process.run_argv ~echo:false ["docker"; "push"; push_image]).exit_code <> 0 then
      Error (Printf.sprintf "docker push failed: %s" push_image)
    else
      Ok ()
  end
