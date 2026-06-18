type k8s_name = K8s_name of string
type namespace = Namespace of string

let max_dns_label_length = 63

let normalize name =
  String.map
    (fun c -> if c = '_' then '-' else Char.lowercase_ascii c)
    name

let is_alnum = function
  | 'a' .. 'z' | '0' .. '9' -> true
  | _ -> false

let is_dns_label_char = function
  | 'a' .. 'z' | '0' .. '9' | '-' -> true
  | _ -> false

let validate_dns_label value =
  let len = String.length value in
  if len = 0 then
    Error "must be between 1 and 63 characters"
  else if len > max_dns_label_length then
    Error "must be between 1 and 63 characters"
  else if not (is_alnum value.[0]) then
    Error "must start with a lowercase alphanumeric character"
  else if not (is_alnum value.[len - 1]) then
    Error "must end with a lowercase alphanumeric character"
  else
    let rec loop i =
      if i = len then Ok ()
      else if is_dns_label_char value.[i] then loop (i + 1)
      else Error "must contain only lowercase alphanumeric characters or hyphens"
    in
    loop 0

let make_k8s_name value =
  Result.map (fun () -> K8s_name value) (validate_dns_label value)

let make_namespace value =
  Result.map (fun () -> Namespace value) (validate_dns_label value)

let k8s_name_of_source source =
  source
  |> normalize
  |> make_k8s_name

let namespace_of_parts ~workspace ~domain =
  Printf.sprintf "%s-%s" (normalize workspace) (normalize domain)
  |> make_namespace

let k8s_name_to_string (K8s_name value) = value
let namespace_to_string (Namespace value) = value
