(* Backend-aware observability UI URL resolution (OBS-012). One resolver,
   used by sun logs/sun open/sun status's "Open" hints alike, instead of
   each command inventing its own flag and default. *)

type backend = Local | Self_hosted_durable | External

let backend_of_string = function
  | "local" -> Some Local
  | "self_hosted_durable" -> Some Self_hosted_durable
  | "external" -> Some External
  | _ -> None

let backend_to_string = function
  | Local -> "local"
  | Self_hosted_durable -> "self_hosted_durable"
  | External -> "external"

type resolution =
  | Url of string
  | No_url of string
  (** [No_url reason] — there is nothing safe to link to; [reason] is a
      short, printable explanation for the caller to show the user instead
      of a broken/guessed link. *)

(* Extension point: a future Sun-hosted UI is a fourth resolvable target.
   It would add a case here (e.g. [Sun_hosted of { release_url : string }])
   and a matching branch below -- callers already handle [No_url] instead
   of assuming every backend resolves, so adding a case is additive. *)

(** [resolve ~backend ?base_domain ?override ()] resolves the base
    observability UI URL for [backend].
    - [override], when given, always wins (e.g. sun logs's
      [--grafana-base-url] flag) -- the resolver is a default, not a lock.
    - [Local] defaults to ["http://localhost:3000"] (the standard dev
      port-forward address).
    - [Self_hosted_durable] resolves to ["https://grafana.<base_domain>"],
      matching platform/infra/base's own Grafana Ingress
      (kubernetes_ingress_v1.grafana) -- requires [base_domain].
    - [External] never guesses: Sun doesn't know the shape of an
      arbitrary vendor's dashboard URL (Grafana Cloud, Datadog, ...). *)
let resolve ~backend ?base_domain ?override () =
  match override with
  | Some url -> Url url
  | None ->
    match backend with
    | Local -> Url "http://localhost:3000"
    | Self_hosted_durable ->
      (match base_domain with
       | Some d when String.trim d <> "" -> Url (Printf.sprintf "https://grafana.%s" d)
       | _ ->
         No_url
           "self_hosted_durable requires --base-domain to resolve the Grafana URL")
    | External ->
      No_url
        "no generated URL for the \"external\" backend -- check your configured observability provider directly"
