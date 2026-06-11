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
  if seg = "" then "unknown" else seg

let generate_default_url ~service_name ~workspace ~environment_name ~base_domain =
  Printf.sprintf "%s.%s.%s.apps.%s"
    (dns_safe_segment service_name)
    (dns_safe_segment workspace)
    (dns_safe_segment environment_name)
    base_domain

type dns_record_kind =
  | Cname
  | Txt

type dns_record = {
  name  : string;
  kind  : dns_record_kind;
  value : string;
  ttl   : int;
}

type custom_domain_config = {
  domain             : string;
  verification_token : string;
}

let verification_record_name domain = "_sun-verify." ^ domain
let verification_record_value token = "sun-verify=" ^ token

let dns_records_for_custom_domain (cfg : custom_domain_config) ~default_url = [
  { name = cfg.domain; kind = Cname; value = default_url; ttl = 300 };
  { name = verification_record_name cfg.domain;
    kind = Txt;
    value = verification_record_value cfg.verification_token;
    ttl = 300;
  };
]

let dns_record_kind_to_string = function
  | Cname -> "CNAME"
  | Txt   -> "TXT"

let dns_record_to_json (r : dns_record) =
  `Assoc [
    "name",  `String r.name;
    "kind",  `String (dns_record_kind_to_string r.kind);
    "value", `String r.value;
    "ttl",   `Int r.ttl;
  ]

let custom_domain_config_to_json (c : custom_domain_config) =
  `Assoc [
    "domain",             `String c.domain;
    "verification_token", `String c.verification_token;
  ]
