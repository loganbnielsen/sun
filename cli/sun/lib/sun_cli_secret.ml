type mode = Local | Customer_cloud | Sun_hosted

type action_result =
  | Applied of string list
  | Deleted of string list
  | Listed of string list
  | Hosted_unavailable of string

let mode_of_env env =
  let normalized = String.lowercase_ascii (String.trim env) in
  match normalized with
  | "hosted" | "sun_hosted" | "sun-hosted" -> Ok Sun_hosted
  | "local" | "dev" -> Ok Local
  | "cloud" | "customer_cloud" | "customer-cloud" -> Ok Customer_cloud
  | _ ->
    Error
      (Printf.sprintf
         "unknown secret environment %S; expected one of: hosted, sun_hosted, sun-hosted, local, dev, cloud, customer_cloud, customer-cloud"
         env)

let is_key_char = function
  | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false

let validate_key key =
  let len = String.length key in
  if len = 0 then Error "secret key must not be empty"
  else if len > 253 then Error "secret key must be 253 characters or fewer"
  else if not (key.[0] >= 'A' && key.[0] <= 'Z') then
    Error "secret key must start with an uppercase letter"
  else if not (String.for_all is_key_char key) then
    Error "secret key may contain only uppercase letters, digits, and underscores"
  else Ok ()

let yaml_quote s =
  "\"" ^ String.escaped s ^ "\""

let render_data existing_data key =
  let data = List.filter (fun (k, _) -> k <> key) existing_data in
  match data with
  | [] -> ""
  | pairs ->
    "data:\n" ^
    String.concat "\n" (List.map (fun (k, v) ->
      Printf.sprintf "  %s: %s" k v
    ) pairs) ^
    "\n"

let named_secret_manifest ~secret_name ~existing_data ~namespace ~key ~value =
  Printf.sprintf {|---
apiVersion: v1
kind: Secret
metadata:
  name: %s
  namespace: %s
type: Opaque
%s
stringData:
  %s: %s
|} secret_name namespace
    (render_data existing_data key)
    key (yaml_quote value)

let secret_manifest ~existing_data ~namespace ~key ~value =
  named_secret_manifest ~secret_name:Sun_cli_manifest.runtime_secret_name
    ~existing_data ~namespace ~key ~value

let redacted_result = function
  | Applied namespaces ->
    Printf.sprintf "secret set in %d namespace(s)" (List.length namespaces)
  | Deleted namespaces ->
    Printf.sprintf "secret deleted from %d namespace(s)" (List.length namespaces)
  | Listed keys ->
    String.concat "\n" keys
  | Hosted_unavailable msg -> msg

let run_command cmd =
  let rc = Sys.command cmd in
  if rc = 0 then Ok () else Error "kubectl command failed"

let validation_error = function
  | Ok () -> Ok ()
  | Error msg -> Error msg

let write_tmp content =
  let path = Filename.temp_file "sun-secret-" ".yaml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  path

let apply_manifest yaml =
  let path = write_tmp yaml in
  let cmd = Printf.sprintf "kubectl apply -f %s >/dev/null" (Filename.quote path) in
  let result =
    match run_command cmd with
    | Ok () -> Ok ()
    | Error _ as e -> e
  in
  (try Sys.remove path with _ -> ());
  result

let get_named_secret_json ~name namespace =
  let path = Filename.temp_file "sun-secret-get-" ".json" in
  let cmd = Printf.sprintf
    "kubectl get secret %s -n %s -o json > %s 2>/dev/null"
    (Filename.quote name)
    (Filename.quote namespace)
    (Filename.quote path)
  in
  let result =
    if Sys.command cmd <> 0 then Ok None
    else
      let ic = open_in path in
      let json = In_channel.input_all ic in
      close_in ic;
      Ok (Some (Yojson.Safe.from_string json))
  in
  (try Sys.remove path with _ -> ());
  result

let get_secret_json namespace =
  get_named_secret_json ~name:Sun_cli_manifest.runtime_secret_name namespace

let data_keys = function
  | `Assoc fields ->
    (match List.assoc_opt "data" fields with
     | Some (`Assoc data) -> data
     | _ -> [])
  | _ -> []

(* List per-workload secret names in a namespace — secrets ending in "-secrets"
   except the shared sun-secrets object, which is patched separately for
   Argo Rollout compatibility. *)
let list_workload_secrets namespace =
  let path = Filename.temp_file "sun-secret-ls-" ".txt" in
  let cmd = Printf.sprintf
    "kubectl get secrets -n %s \
     -o jsonpath='{range .items[*]}{.metadata.name}{\"\\n\"}{end}' \
     2>/dev/null > %s"
    (Filename.quote namespace) (Filename.quote path)
  in
  let secrets =
    if Sys.command cmd <> 0 then []
    else begin
      let ic = open_in path in
      let content = In_channel.input_all ic in
      close_in ic;
      let suffix = "-secrets" in
      let slen = String.length suffix in
      String.split_on_char '\n' content
      |> List.map String.trim
      |> List.filter (fun name ->
           name <> "" &&
           name <> Sun_cli_manifest.runtime_secret_name &&
           String.length name >= slen &&
           String.sub name (String.length name - slen) slen = suffix)
    end
  in
  (try Sys.remove path with _ -> ());
  secrets

let apply_to_named_secret ~secret_name ~namespace ~key ~value =
  match get_named_secret_json ~name:secret_name namespace with
  | Error _ as e -> e
  | Ok existing ->
    let existing_data = match existing with
      | None -> []
      | Some json ->
        List.filter_map (function
          | k, `String v -> Some (k, v)
          | _ -> None
        ) (data_keys json)
    in
    let yaml = named_secret_manifest ~secret_name ~existing_data ~namespace ~key ~value in
    apply_manifest yaml

let rollout_restart namespace =
  let cmd = Printf.sprintf
    "kubectl rollout restart deployment -n %s >/dev/null 2>/dev/null || true"
    (Filename.quote namespace)
  in
  let _ = Sys.command cmd in
  ()

let hosted_stub _env =
  Error "hosted secret management will use the Sun control-plane API; no hosted endpoint is configured yet"

let require_namespaces namespaces =
  match namespaces with
  | [] -> Error "no target namespaces found for this workspace"
  | _ -> Ok ()

let set ~env ~workspace:_ ~namespaces ~key ~value =
  match validation_error (validate_key key) with
  | Error _ as e -> e
  | Ok () ->
    (match mode_of_env env with
     | Error _ as e -> e
     | Ok Sun_hosted -> hosted_stub env
     | Ok (Local | Customer_cloud) ->
       (match require_namespaces namespaces with
        | Error _ as e -> e
        | Ok () ->
          let rec apply_all = function
            | [] -> Ok (Applied namespaces)
            | ns :: rest ->
              (* Patch sun-secrets for Argo Rollout workloads *)
              (match get_secret_json ns with
               | Error _ as e -> e
               | Ok existing ->
                 let existing_data = match existing with
                   | None -> []
                   | Some json ->
                     List.filter_map (function
                       | k, `String v -> Some (k, v)
                       | _ -> None
                     ) (data_keys json)
                 in
                 let yaml = secret_manifest ~existing_data ~namespace:ns ~key ~value in
                 match apply_manifest yaml with
                 | Error _ as e -> e
                 | Ok () ->
                   (* Also patch each per-service secret so standard Deployment
                      workloads (which mount <svc>-secrets, not sun-secrets) see
                      the updated value immediately on next restart. *)
                   let workload_secrets = list_workload_secrets ns in
                   let patch_results = List.map (fun sname ->
                     apply_to_named_secret ~secret_name:sname ~namespace:ns ~key ~value
                   ) workload_secrets in
                   let first_error = List.find_opt Result.is_error patch_results in
                   (match first_error with
                    | Some (Error _ as e) -> e
                    | _ ->
                      rollout_restart ns;
                      apply_all rest))
          in
          apply_all namespaces))

let read_keys namespace =
  match get_secret_json namespace with
  | Error _ as e -> e
  | Ok None -> Ok []
  | Ok (Some json) -> Ok (List.map fst (data_keys json))

let list ~env ~workspace:_ ~namespaces =
  match mode_of_env env with
  | Error _ as e -> e
  | Ok Sun_hosted -> hosted_stub env
  | Ok (Local | Customer_cloud) ->
    (match require_namespaces namespaces with
     | Error _ as e -> e
     | Ok () ->
       let keys =
         List.fold_left (fun acc ns ->
           match read_keys ns with
           | Ok ks -> ks @ acc
           | Error _ -> acc
         ) [] namespaces
         |> List.sort_uniq String.compare
       in
       Ok (Listed keys))

let delete ~env ~workspace:_ ~namespaces ~key =
  match validation_error (validate_key key) with
  | Error _ as e -> e
  | Ok () ->
    (match mode_of_env env with
     | Error _ as e -> e
     | Ok Sun_hosted -> hosted_stub env
     | Ok (Local | Customer_cloud) ->
       (match require_namespaces namespaces with
        | Error _ as e -> e
        | Ok () ->
          let patch = Printf.sprintf
            "[{\"op\":\"remove\",\"path\":\"/data/%s\"}]"
            key
          in
          let remove_from namespace name =
            let cmd = Printf.sprintf
              "kubectl patch secret %s -n %s --type json -p %s >/dev/null 2>/dev/null || true"
              (Filename.quote name)
              (Filename.quote namespace)
              (Filename.quote patch)
            in
            run_command cmd
          in
          let rec delete_all = function
            | [] -> Ok (Deleted namespaces)
            | ns :: rest ->
              (match remove_from ns Sun_cli_manifest.runtime_secret_name with
               | Error _ as e -> e
               | Ok () ->
                 let workload_secrets = list_workload_secrets ns in
                 let _ = List.iter (fun sname ->
                   let _ = remove_from ns sname in ()
                 ) workload_secrets in
                 rollout_restart ns;
                 delete_all rest)
          in
          delete_all namespaces))
