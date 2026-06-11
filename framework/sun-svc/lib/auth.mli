type jwt_config =
  { scopes                     : string list
  ; allow_unverified_v1_unsafe : bool
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
  | `Not_implemented of string
  ]

(** Internal — called by [Service.Make]. Not intended for direct use. *)
val validate : level -> Http.Header.t -> (context, error) result
