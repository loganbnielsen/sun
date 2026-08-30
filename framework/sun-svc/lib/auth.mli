type jwt_algorithm = [ `HS256 | `RS256 | `ES256 | `ES384 | `ES512 ]

type jwt_key_source =
  | Hs256_secret of string
      (** Shared secret. Verified via [jose]'s HS256 path, not a hand-rolled
          HMAC comparison. *)
  | Jwks_static  of string
      (** A JWKS document (RFC 7517) baked into config, e.g. for a fixed
          non-rotating key set. *)
  | Jwks_url     of string
      (** HTTPS URL of a JWKS endpoint. Fetched over TLS and cached with a
          fixed rotation window; never fetched on every request. *)

type jwt_verified_config =
  { issuer     : string
  ; audience   : string
  ; algorithms : jwt_algorithm list
      (** Allowlist. A token whose header [alg] is not in this list is
          rejected before any key lookup or signature check. *)
  ; key_source : jwt_key_source
  }

type jwt_verification =
  | Verified_signature_required of jwt_verified_config
  | Unverified_dev_only

type jwt_config =
  { scopes       : string list
  ; verification : jwt_verification
  }

type level =
  [ `Public
  | `Api_key
  | `Jwt of jwt_config
  ]

type principal =
  | Public
  | Service of { key_id : string }
  | User of
      { sub    : string
      ; scopes : string list
      ; claims : Yojson.Safe.t
      }

type context = { principal : principal }

type error =
  [ `Unauthorized    of string
  | `Forbidden       of string
  | `Server_error    of string
  ]

(** Internal — called by [Service.Make]. Not intended for direct use.
    [fetch_jwks] is the injected capability to resolve a [Jwks_url]; [Public],
    [Api_key], [Unverified_dev_only], [Hs256_secret], and [Jwks_static] never
    touch it. If a route uses [Jwks_url] and no [fetch_jwks] is given, that
    route fails closed with [`Server_error]. *)
val validate :
  ?read_api_key:(unit -> string option) ->
  ?fetch_jwks:(string -> (Jose.Jwks.t, string) result) ->
  level -> Http.Header.t -> (context, error) result

(** The real [fetch_jwks] transport: HTTPS GET + JSON parse via [https-eio].
    [Service.Make.run] builds this once, closing over its Eio env, and passes
    it to [validate] as [~fetch_jwks:(fetch_jwks_over_https ~env)]. *)
val fetch_jwks_over_https :
  env:< net : _ Eio.Net.t ; clock : _ Eio.Time.clock ; .. > ->
  string -> (Jose.Jwks.t, string) result
