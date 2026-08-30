let replace_all ~pat ~with_ s =
  let pl = String.length pat in
  let sl = String.length s in
  let buf = Buffer.create (sl + 64) in
  let i = ref 0 in
  while !i < sl do
    if !i + pl <= sl && String.sub s !i pl = pat then begin
      Buffer.add_string buf with_;
      i := !i + pl
    end else begin
      Buffer.add_char buf s.[!i];
      incr i
    end
  done;
  Buffer.contents buf

let subst vars s =
  List.fold_left (fun acc (k, v) ->
    replace_all ~pat:("{{" ^ k ^ "}}") ~with_:v acc
  ) s vars

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if Sys.file_exists dir then begin
    if not (Sys.is_directory dir) then
      raise (Failure (Printf.sprintf "could not create directory %s: a file already exists at that path" dir))
  end else begin
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    | Unix.Unix_error (e, _, _) ->
      raise (Failure (Printf.sprintf "could not create directory %s: %s" dir (Unix.error_message e)))
  end

let write_file ~path ~content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Printf.printf "  created  %s\n%!" path

let link_dir ~path ~target =
  mkdir_p (Filename.dirname path);
  (try Unix.symlink target path
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Printf.printf "  linked   %s -> %s\n%!" path target

let normalize s =
  String.map (function '-' -> '_' | c -> c) (String.lowercase_ascii s)

let capitalize_name s =
  let s = normalize s in
  if String.length s = 0 then s
  else begin
    let b = Bytes.of_string s in
    Bytes.set b 0 (Char.uppercase_ascii (Bytes.get b 0));
    Bytes.to_string b
  end
