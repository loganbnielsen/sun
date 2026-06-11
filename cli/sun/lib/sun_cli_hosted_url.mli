(** Hosted default URL generation and custom-domain flow.

    Default URLs are Sun-managed, deterministic, and available immediately after
    the first hosted deploy. Custom domains require customer-managed DNS and
    Sun-owned TLS issuance after ownership verification.

    This module is pure — no I/O, no network calls. *)

val dns_safe_segment : string -> string
(** Normalise a string to a DNS label: lowercase; underscores and spaces become
    hyphens; all other non-alphanumeric characters are stripped.
    Returns ["unknown"] if the result would be empty. *)

val generate_default_url :
  service_name:string ->
  workspace:string ->
  environment_name:string ->
  base_domain:string ->
  string
(** [generate_default_url ~service_name ~workspace ~environment_name ~base_domain]
    returns a Sun-managed URL of the form
    [<service>.<workspace>.<env>.apps.<base_domain>].
    Each component is normalised with [dns_safe_segment]. *)

type dns_record_kind =
  | Cname
  | Txt

type dns_record = {
  name  : string;
  kind  : dns_record_kind;
  value : string;
  ttl   : int;
}
(** A DNS record the customer must create in their DNS provider. *)

type custom_domain_config = {
  domain             : string;
  (** The customer-owned domain, e.g. ["api.acme.com"]. *)
  verification_token : string;
  (** Opaque token used to prove domain ownership before TLS issuance. *)
}

val dns_records_for_custom_domain :
  custom_domain_config ->
  default_url:string ->
  dns_record list
(** Returns the two DNS records a customer must create:
    {ul
    {- CNAME [<domain>] → [<default_url>] for routing (TTL 300)}
    {- TXT [_sun-verify.<domain>] → ["sun-verify=<token>"] for ownership
       verification before Sun issues a TLS certificate (TTL 300)}} *)

val verification_record_name : string -> string
(** [verification_record_name domain] returns ["_sun-verify.<domain>"]. *)

val verification_record_value : string -> string
(** [verification_record_value token] returns ["sun-verify=<token>"]. *)

val dns_record_kind_to_string : dns_record_kind -> string
val dns_record_to_json : dns_record -> Yojson.Safe.t
val custom_domain_config_to_json : custom_domain_config -> Yojson.Safe.t
