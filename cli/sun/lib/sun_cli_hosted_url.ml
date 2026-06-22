type dns_label = Dns_label of string
type dns_domain = Dns_domain of string
type positive_ttl = Positive_ttl of int

let dns_label_to_string (Dns_label s) = s
let dns_domain_to_string (Dns_domain s) = s
let positive_ttl_to_int (Positive_ttl ttl) = ttl

let valid_dns_label s =
  Result.is_ok (Sun_cli_kubernetes_name.validate_dns_label s)

let make_dns_label s =
  let s = String.lowercase_ascii s in
  if valid_dns_label s then Ok (Dns_label s)
  else Error (Printf.sprintf "invalid DNS label: %S" s)

let dns_safe_segment s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | 'a' .. 'z' as c -> Buffer.add_char b c
      | 'A' .. 'Z' as c -> Buffer.add_char b (Char.lowercase_ascii c)
      | '0' .. '9' as c -> Buffer.add_char b c
      | '_' | '-' | ' ' -> Buffer.add_char b '-'
      | _ -> ())
    s;
  let seg = Buffer.contents b in
  make_dns_label seg

let split_domain s =
  let rec loop acc start i =
    if i = String.length s then
      List.rev (String.sub s start (i - start) :: acc)
    else if s.[i] = '.' then
      loop (String.sub s start (i - start) :: acc) (i + 1) (i + 1)
    else loop acc start (i + 1)
  in
  loop [] 0 0

let make_dns_domain s =
  let s = String.lowercase_ascii s in
  if String.length s = 0 then Error "invalid DNS domain: empty"
  else if String.length s > 253 then Error (Printf.sprintf "invalid DNS domain: %S" s)
  else
    let labels = split_domain s in
    if List.for_all valid_dns_label labels then Ok (Dns_domain s)
    else Error (Printf.sprintf "invalid DNS domain: %S" s)

let make_positive_ttl ttl =
  if ttl > 0 then Ok (Positive_ttl ttl)
  else Error (Printf.sprintf "invalid DNS TTL: %d" ttl)

let generate_default_url ~service_name ~workspace ~environment_name ~base_domain =
  match dns_safe_segment service_name,
        dns_safe_segment workspace,
        dns_safe_segment environment_name,
        make_dns_domain base_domain with
  | Ok service_name, Ok workspace, Ok environment_name, Ok base_domain ->
    Ok (Printf.sprintf "%s.%s.%s.apps.%s"
          (dns_label_to_string service_name)
          (dns_label_to_string workspace)
          (dns_label_to_string environment_name)
          (dns_domain_to_string base_domain))
  | Error msg, _, _, _
  | _, Error msg, _, _
  | _, _, Error msg, _
  | _, _, _, Error msg -> Error msg

type dns_record_kind =
  | Cname
  | Txt

type dns_record = {
  name  : string;
  kind  : dns_record_kind;
  value : string;
  ttl   : positive_ttl;
}

type custom_domain_config = {
  domain             : dns_domain;
  verification_token : string;
}

let make_custom_domain_config ~domain ~verification_token =
  match make_dns_domain domain with
  | Ok domain -> Ok { domain; verification_token }
  | Error msg -> Error msg

let verification_record_name domain = "_sun-verify." ^ dns_domain_to_string domain
let verification_record_value token = "sun-verify=" ^ token

let dns_records_for_custom_domain (cfg : custom_domain_config) ~default_url =
  match make_dns_domain default_url, make_positive_ttl 300 with
  | Ok default_url, Ok ttl ->
    let domain = dns_domain_to_string cfg.domain in
    Ok [
      { name = domain;
        kind = Cname;
        value = dns_domain_to_string default_url;
        ttl;
      };
      { name = verification_record_name cfg.domain;
        kind = Txt;
        value = verification_record_value cfg.verification_token;
        ttl;
      };
    ]
  | Error msg, _
  | _, Error msg -> Error msg

let dns_record_kind_to_string = function
  | Cname -> "CNAME"
  | Txt   -> "TXT"

let dns_record_to_json (r : dns_record) =
  `Assoc [
    "name",  `String r.name;
    "kind",  `String (dns_record_kind_to_string r.kind);
    "value", `String r.value;
    "ttl",   `Int (positive_ttl_to_int r.ttl);
  ]

let custom_domain_config_to_json (c : custom_domain_config) =
  `Assoc [
    "domain",             `String (dns_domain_to_string c.domain);
    "verification_token", `String c.verification_token;
  ]
