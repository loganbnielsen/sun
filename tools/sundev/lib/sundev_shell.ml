let read_file path =
  let ic = open_in path in
  let s = In_channel.input_all ic in
  close_in ic; s

let run_cmd ?(echo = true) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  Sys.command cmd

let run_cmd_lines ?(echo = false) cmd =
  let tmp = Filename.temp_file "sun-cmd-" ".tmp" in
  let full = Printf.sprintf "%s > %s 2>/dev/null" cmd tmp in
  if echo then Printf.printf "  $ %s\n%!" cmd;
  ignore (Sys.command full);
  let lines = String.split_on_char '\n' (String.trim (read_file tmp)) in
  (try Sys.remove tmp with _ -> ());
  List.filter (fun s -> s <> "") lines
