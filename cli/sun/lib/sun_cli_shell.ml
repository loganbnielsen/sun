let read_file path =
  let ic = open_in path in
  let s = In_channel.input_all ic in
  close_in ic; s

let run_cmd ?(echo = true) cmd =
  Sun_process.run_rc ~echo cmd

let run_cmd_ok ?(echo = true) cmd =
  Sun_process.run_ok ~echo cmd

let run_cmd_lines ?(echo = false) cmd =
  Sun_process.lines ~echo cmd

let run_cmd_to_string cmd =
  Sun_process.output ~echo:false cmd

let string_contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec go i = i <= hl - nl
      && (String.sub haystack i nl = needle || go (i + 1))
    in
    go 0
