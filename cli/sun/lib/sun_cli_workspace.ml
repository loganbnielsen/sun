type infra_requirements = {
  kafka      : bool;
  postgres   : bool;
  loki       : bool;
  prometheus : bool;
}

let contains_string ~needle s =
  let nl = String.length needle in
  let sl = String.length s in
  let found = ref false in
  for i = 0 to sl - nl do
    if not !found && String.sub s i nl = needle then
      found := true
  done;
  !found

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let scan ~dir =
  let kafka      = ref false in
  let postgres   = ref false in
  let loki       = ref false in
  let prometheus = ref false in
  let rec collect d =
    (try
      Array.iter (fun entry ->
        if entry.[0] <> '.' then begin
          let path = Filename.concat d entry in
          if entry = "dune" then begin
            (try
              let content = read_file path in
              if contains_string ~needle:"kafka_eio_service"  content then kafka      := true;
              if contains_string ~needle:"sun_storage"        content then postgres   := true;
              if contains_string ~needle:"obs_eio_loki"       content then loki       := true;
              if contains_string ~needle:"obs_eio_prometheus" content then prometheus := true;
            with _ -> ())
          end else if Sys.is_directory path then
            collect path
        end
      ) (Sys.readdir d)
    with _ -> ())
  in
  collect dir;
  { kafka = !kafka; postgres = !postgres; loki = !loki; prometheus = !prometheus }
