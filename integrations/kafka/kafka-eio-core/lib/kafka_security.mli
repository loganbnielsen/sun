(** Security transport configuration shared by producer and consumer. *)

type protocol =
  | Plaintext       (** No encryption or authentication. Local dev default. *)
  | Ssl             (** TLS encryption, no SASL authentication. *)
  | Sasl_plaintext  (** SASL authentication, no TLS encryption. *)
  | Sasl_ssl        (** SASL authentication over TLS. Production default. *)

type t = {
  protocol        : protocol;
  ssl_ca_location : string option;
  (** Path to CA certificate bundle, e.g. ["/etc/ssl/certs/ca-certificates.crt"].
      [None] uses librdkafka's default (system CAs on most Linux distributions). *)
  sasl_mechanism  : string option;
  (** SASL mechanism: ["PLAIN"], ["SCRAM-SHA-256"], or ["SCRAM-SHA-512"]. *)
  sasl_username   : string option;
  sasl_password   : string option;
}

val default : t
(** [Plaintext] with all optional fields [None]. Use for local dev and unit tests.
    Do not use in production — requires explicit [Ssl] or [Sasl_ssl]. *)

val of_env : unit -> t
(** Build from environment variables:
    - [KAFKA_SECURITY_PROTOCOL] — ["plaintext" | "ssl" | "sasl_plaintext" | "sasl_ssl"]
      (default: ["plaintext"])
    - [KAFKA_SSL_CA_LOCATION]   — path to CA cert bundle
    - [KAFKA_SASL_MECHANISM]    — e.g. ["SCRAM-SHA-256"]
    - [KAFKA_SASL_USERNAME]
    - [KAFKA_SASL_PASSWORD] *)

val apply : Kafka_raw.kafka_conf -> t -> (unit, string) result
(** Set librdkafka [security.protocol], [ssl.ca.location], and [sasl.*] keys on [conf].
    Returns [Error msg] if any key is rejected by librdkafka or if a SASL protocol
    is configured without the required [sasl_mechanism], [sasl_username], and [sasl_password].
    Called internally by producer and consumer [conf_of_config]; not part of the public API. *)

val make_base_conf
  :  brokers:string list
  -> security:t
  -> Kafka_raw.kafka_conf * (string -> string -> unit) * string option ref
(** Allocate a fresh rdkafka conf, set [bootstrap.servers], apply [security], and
    return [(conf, set, first_err)] where [set k v] applies one additional key with
    the same first-error-wins guard.  Callers set their own keys then check
    [!first_err] to produce the final [(kafka_conf, string) result]. *)
