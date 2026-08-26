(** DynamoDB's attribute-value encoding
    ({{:https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_AttributeValue.html}
    AWS reference}). *)

type t =
  | S of string
  | N of string
      (** DynamoDB numbers are wire-encoded as decimal strings, not JSON
          numbers, specifically to avoid precision loss on large integers —
          encoding a real OCaml [int]/[float] into this decimal-string form
          is the caller's job, not this module's. *)
  | B of string  (** Raw bytes; base64-encoded only at the JSON boundary. *)
  | Bool of bool
  | Null
  | Ss of string list
  | Ns of string list
  | Bs of string list
  | L of t list
  | M of (string * t) list

val to_json : t -> Yojson.Safe.t
(** [{"S": "foo"}], [{"N": "123"}], [{"B": "<base64>"}], etc. — one
    single-key object per DynamoDB's own encoding, never a bare JSON scalar. *)

val of_json : Yojson.Safe.t -> (t, string) result
(** The inverse of {!to_json}. [Error msg] for anything that isn't a
    single-key object naming one of the attribute-value type tags, or whose
    [B]/[BS] payload isn't valid base64. *)
