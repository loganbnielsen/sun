type mode = Local | Customer_cloud | Sun_hosted

type action_result =
  | Applied of string list
  | Deleted of string list
  | Listed of string list
  | Hosted_unavailable of string

let ( let* ) = Result.bind

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

type object_metadata = {
  name      : string;
  namespace : string;
}

type kubernetes_secret = {
  api_version : string;
  kind        : string;
  metadata    : object_metadata;
  secret_type : string;
  data        : (string * string) list;
  string_data : (string * string) list;
}

let yaml_quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 ->
        Buffer.add_string b (Printf.sprintf "\\x%02X" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let render_mapping ~indent pairs =
  pairs
  |> List.map (fun (k, v) ->
       Printf.sprintf "%s%s: %s" indent k (yaml_quote v))
  |> String.concat "\n"

let render_optional_mapping ~name pairs =
  match pairs with
  | [] -> []
  | _ -> [ name ^ ":"; render_mapping ~indent:"  " pairs ]

let render_secret_manifest secret =
  let lines =
    [ "---"
    ; "apiVersion: " ^ secret.api_version
    ; "kind: " ^ secret.kind
    ; "metadata:"
    ; "  name: " ^ secret.metadata.name
    ; "  namespace: " ^ secret.metadata.namespace
    ; "type: " ^ secret.secret_type
    ]
    @ render_optional_mapping ~name:"data" secret.data
    @ [ "stringData:"; render_mapping ~indent:"  " secret.string_data ]
  in
  String.concat "\n" lines ^ "\n"

let named_secret_manifest ~secret_name ~existing_data ~namespace ~key ~value =
  let data = List.filter (fun (k, _) -> k <> key) existing_data in
  render_secret_manifest
    { api_version = "v1"
    ; kind = "Secret"
    ; metadata = { name = secret_name; namespace }
    ; secret_type = "Opaque"
    ; data
    ; string_data = [ key, value ]
    }

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

let run_kubectl_ok argv =
  match Sun_cli_process.run_ok (Sun_cli_process.cmd argv) with
  | Ok () -> Ok ()
  | Error e -> Error (Sun_cli_process.error_to_string e)

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
  let result = run_kubectl_ok ["kubectl"; "apply"; "-f"; path] in
  (try Sys.remove path with _ -> ());
  result

let get_named_secret_json ~name namespace =
  match Sun_cli_kubectl.get ~resource:"secret" ~name ~namespace ~output:"json" with
  | Error _ -> Ok None
  | Ok r when r.Sun_cli_process.exit_code <> 0 -> Ok None
  | Ok r ->
    (try Ok (Some (Yojson.Safe.from_string r.Sun_cli_process.stdout))
     with _ -> Ok None)

let get_secret_json namespace =
  get_named_secret_json ~name:Sun_cli_manifest.runtime_secret_name namespace

let data_keys = function
  | `Assoc fields ->
    (match List.assoc_opt "data" fields with
     | Some (`Assoc data) -> data
     | _ -> [])
  | _ -> []

let existing_data = function
  | None -> []
  | Some json ->
    List.filter_map (function
      | k, `String v -> Some (k, v)
      | _ -> None
    ) (data_keys json)

(* List per-workload secret names in a namespace — secrets ending in "-secrets"
   except the shared sun-secrets object, which is patched separately for
   Argo Rollout compatibility. *)
let list_workload_secrets namespace =
  let jsonpath = "{range .items[*]}{.metadata.name}{\"\\n\"}{end}" in
  match Sun_cli_kubectl.get_raw
      ~args:["get"; "secrets"; "-n"; namespace; "-o"; "jsonpath=" ^ jsonpath] with
  | Error _ -> []
  | Ok r when r.Sun_cli_process.exit_code <> 0 -> []
  | Ok r ->
    let suffix = "-secrets" in
    let slen = String.length suffix in
    String.split_on_char '\n' r.Sun_cli_process.stdout
    |> List.map String.trim
    |> List.filter (fun name ->
         name <> "" &&
         name <> Sun_cli_manifest.runtime_secret_name &&
         String.length name >= slen &&
         String.sub name (String.length name - slen) slen = suffix)

let apply_to_named_secret ~secret_name ~namespace ~key ~value =
  let* existing = get_named_secret_json ~name:secret_name namespace in
  let existing_data = existing_data existing in
  let yaml = named_secret_manifest ~secret_name ~existing_data ~namespace ~key ~value in
  apply_manifest yaml

let rollout_restart namespace =
  ignore (Sun_cli_kubectl.rollout_restart ~kind:"deployment" ~namespace)

let hosted_stub _env =
  Error "hosted secret management will use the Sun control-plane API; no hosted endpoint is configured yet"

let require_namespaces namespaces =
  match namespaces with
  | [] -> Error "no target namespaces found for this workspace"
  | _ -> Ok ()

let validate_operation_context ~env ~namespaces =
  let* mode = mode_of_env env in
  match mode with
  | Sun_hosted -> hosted_stub env
  | Local | Customer_cloud ->
    let* () = require_namespaces namespaces in
    Ok namespaces

let rec iter_namespaces namespaces ~f =
  match namespaces with
  | [] -> Ok ()
  | namespace :: rest ->
    let* () = f namespace in
    iter_namespaces rest ~f

let rec fold_namespaces namespaces ~init ~f =
  match namespaces with
  | [] -> Ok init
  | namespace :: rest ->
    let* init = f init namespace in
    fold_namespaces rest ~init ~f

let patch_workload_secrets ~namespace ~key ~value =
  list_workload_secrets namespace
  |> List.map (fun secret_name ->
       apply_to_named_secret ~secret_name ~namespace ~key ~value)
  |> List.find_opt Result.is_error
  |> function
     | Some (Error _ as e) -> e
     | _ -> Ok ()

let set ~env ~workspace:_ ~namespaces ~key ~value =
  let* () = validation_error (validate_key key) in
  let* namespaces = validate_operation_context ~env ~namespaces in
  let* () =
    iter_namespaces namespaces ~f:(fun namespace ->
      (* Patch sun-secrets for Argo Rollout workloads *)
      let* existing = get_secret_json namespace in
      let existing_data = existing_data existing in
      let yaml = secret_manifest ~existing_data ~namespace ~key ~value in
      let* () = apply_manifest yaml in
      (* Also patch each per-service secret so standard Deployment workloads
         (which mount <svc>-secrets, not sun-secrets) see the updated value
         immediately on next restart. *)
      let* () = patch_workload_secrets ~namespace ~key ~value in
      rollout_restart namespace;
      Ok ())
  in
  Ok (Applied namespaces)

let read_keys namespace =
  let* json = get_secret_json namespace in
  match json with
  | None -> Ok []
  | Some json -> Ok (List.map fst (data_keys json))

let list ~env ~workspace:_ ~namespaces =
  let* namespaces = validate_operation_context ~env ~namespaces in
  let* keys =
    fold_namespaces namespaces ~init:[] ~f:(fun acc namespace ->
      match read_keys namespace with
      | Ok keys -> Ok (keys @ acc)
      | Error _ -> Ok acc)
  in
  Ok (Listed (List.sort_uniq String.compare keys))

let delete ~env ~workspace:_ ~namespaces ~key =
  let* () = validation_error (validate_key key) in
  let* namespaces = validate_operation_context ~env ~namespaces in
  let patch = Printf.sprintf
    "[{\"op\":\"remove\",\"path\":\"/data/%s\"}]"
    key
  in
  let remove_from namespace name =
    ignore (Sun_cli_kubectl.patch ~resource:"secret" ~name ~namespace
              ~patch_type:"json" ~patch);
    Ok ()
  in
  let* () =
    iter_namespaces namespaces ~f:(fun namespace ->
      let* () = remove_from namespace Sun_cli_manifest.runtime_secret_name in
      list_workload_secrets namespace
      |> List.iter (fun secret_name ->
           let _ = remove_from namespace secret_name in
           ());
      rollout_restart namespace;
      Ok ())
  in
  Ok (Deleted namespaces)
