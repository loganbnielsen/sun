let deploy_state_configmap_name workspace =
  Printf.sprintf "sun-deploy-state-%s" workspace

let load_deployed_groups workspace =
  let name = deploy_state_configmap_name workspace in
  let result =
    Sun_process.run_argv ~echo:false
      ["kubectl"; "get"; "configmap"; name; "-n"; "default"; "-o";
       "jsonpath={.data.consumer_groups}"]
  in
  if not (Sun_process.succeeded result) then []
  else
    String.split_on_char '\n' result.stdout
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")

let save_deployed_groups workspace groups =
  let name = deploy_state_configmap_name workspace in
  let value = String.concat "\n" groups in
  let apply_json = Printf.sprintf
    {|{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"%s","namespace":"default"},"data":{"consumer_groups":"%s"}}|}
    (String.escaped name) (String.escaped value)
  in
  let path = Filename.temp_file "sun-state-" ".json" in
  let oc = open_out path in
  output_string oc apply_json;
  close_out oc;
  ignore (Sun_process.run_argv ~echo:false ["kubectl"; "apply"; "-f"; path]);
  (try Sys.remove path with _ -> ())

let removed_consumer_groups ~prev ~next =
  List.filter (fun g -> not (List.mem g next)) prev
