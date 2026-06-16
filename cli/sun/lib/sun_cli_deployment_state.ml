let deploy_state_configmap_name workspace =
  Printf.sprintf "sun-deploy-state-%s" workspace

let load_deployed_groups workspace =
  let name = deploy_state_configmap_name workspace in
  let path = Filename.temp_file "sun-groups-" ".txt" in
  let cmd = Printf.sprintf
    "kubectl get configmap %s -n default \
     -o jsonpath='{.data.consumer_groups}' 2>/dev/null > %s"
    (Filename.quote name) (Filename.quote path)
  in
  let groups =
    if Sys.command cmd <> 0 then []
    else begin
      let ic = open_in path in
      let content = In_channel.input_all ic in
      close_in ic;
      String.split_on_char '\n' content
      |> List.map String.trim
      |> List.filter (fun s -> s <> "")
    end
  in
  (try Sys.remove path with _ -> ());
  groups

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
