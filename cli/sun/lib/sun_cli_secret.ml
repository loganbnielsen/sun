type mode = Local | Customer_cloud | Sun_hosted

type action_result =
  | Applied of string list
  | Deleted of string list
  | Listed of string list
  | Hosted_unavailable of string

let mode_of_env env =
  match String.lowercase_ascii (String.trim env) with
  | "hosted" | "sun_hosted" | "sun-hosted" -> Sun_hosted
  | "local" | "dev" -> Local
  | _ -> Customer_cloud

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

let secret_manifest ~existing_data ~namespace ~key ~value =
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
|} Sun_cli_manifest.runtime_secret_name namespace
    (render_data existing_data key)
    key (yaml_quote value)

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

let get_secret_json namespace =
  let path = Filename.temp_file "sun-secret-get-" ".json" in
  let cmd = Printf.sprintf
    "kubectl get secret %s -n %s -o json > %s 2>/dev/null"
    (Filename.quote Sun_cli_manifest.runtime_secret_name)
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

let data_keys = function
  | `Assoc fields ->
    (match List.assoc_opt "data" fields with
     | Some (`Assoc data) -> data
     | _ -> [])
  | _ -> []

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
     | Sun_hosted -> hosted_stub env
     | Local | Customer_cloud ->
       (match require_namespaces namespaces with
        | Error _ as e -> e
        | Ok () ->
          let rec apply_all = function
            | [] -> Ok (Applied namespaces)
            | ns :: rest ->
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
               | Ok () -> apply_all rest
               | Error _ as e -> e)
          in
          apply_all namespaces))

let read_keys namespace =
  match get_secret_json namespace with
  | Error _ as e -> e
  | Ok None -> Ok []
  | Ok (Some json) -> Ok (List.map fst (data_keys json))

let list ~env ~workspace:_ ~namespaces =
  match mode_of_env env with
  | Sun_hosted -> hosted_stub env
  | Local | Customer_cloud ->
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
     | Sun_hosted -> hosted_stub env
     | Local | Customer_cloud ->
       (match require_namespaces namespaces with
        | Error _ as e -> e
        | Ok () ->
          let patch = Printf.sprintf
            "[{\"op\":\"remove\",\"path\":\"/data/%s\"}]"
            key
          in
          let rec delete_all = function
            | [] -> Ok (Deleted namespaces)
            | ns :: rest ->
              let cmd = Printf.sprintf
                "kubectl patch secret %s -n %s --type json -p %s >/dev/null 2>/dev/null || true"
                (Filename.quote Sun_cli_manifest.runtime_secret_name)
                (Filename.quote ns)
                (Filename.quote patch)
              in
              (match run_command cmd with
               | Ok () -> delete_all rest
               | Error _ as e -> e)
          in
          delete_all namespaces))
