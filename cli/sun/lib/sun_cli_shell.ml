let read_file path =
  let ic = open_in path in
  let s = In_channel.input_all ic in
  close_in ic; s

let with_temp_file prefix suffix f =
  let path = Filename.temp_file prefix suffix in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

let run_cmd ?(echo = true) cmd =
  Sun_process.run_rc ~echo cmd

let run_cmd_ok ?(echo = true) cmd =
  Sun_process.run_ok ~echo cmd

let run_cmd_lines ?(echo = false) cmd =
  Sun_process.lines ~echo cmd

let run_cmd_to_string cmd =
  Sun_process.output ~echo:false cmd
