let deploy_state_configmap_name workspace =
  Printf.sprintf "sun-deploy-state-%s" workspace

let load_deployed_groups workspace =
  let name = deploy_state_configmap_name workspace in
  let cmd = Printf.sprintf
    "kubectl get configmap %s -n default \
     -o jsonpath='{.data.consumer_groups}' 2>/dev/null"
    (Filename.quote name)
  in
  let r = Sun_process.run ~echo:false cmd in
  if r.exit_code <> 0 then []
  else
    String.split_on_char '\n' r.stdout
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")

let save_deployed_groups workspace groups =
  let name = deploy_state_configmap_name workspace in
  let value = String.concat "\n" groups in
  let content = Printf.sprintf
    {|{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"%s","namespace":"default"},"data":{"consumer_groups":"%s"}}|}
    (String.escaped name) (String.escaped value)
  in
  ignore (Sun_process.with_tmp_file "sun-state-" content (fun path ->
    Sun_process.run_argv ~echo:false ["kubectl"; "apply"; "-f"; path]))

let removed_consumer_groups ~prev ~next =
  List.filter (fun g -> not (List.mem g next)) prev
