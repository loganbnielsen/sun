(** The typed indexing layer — see [dynamo-eio.md]'s "the ElectroDB-replacement
    layer" section for the design rationale. One functor application per
    index (primary or secondary); passing one index's key to another index's
    functions is a type error, not a runtime bug. *)

module type INDEX = sig
  type pk
  type sk

  val index_name : string option
      (** [None] = the table's primary index; [Some gsi_name] = a global/local
          secondary index. *)

  val format_pk : pk -> string
  val format_sk : sk -> string

  val pk_attribute : string
  (** the index's partition-key attribute name *)

  val sk_attribute : string
  (** the index's sort-key attribute name *)
end

module Index (I : INDEX) : sig
  val get :
    net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> Dynamo_client.config ->
    pk:I.pk -> sk:I.sk -> (Dynamo_client.item option, Dynamo_error.t) result
  (** Implemented as a [Query] with an equality key condition on both [pk]
      and [sk] — {!Dynamo_client}'s [get_item] only works against the
      table's primary key, and DynamoDB simply has no [GetItem]-by-
      secondary-index operation, so [Query] is the only correct mechanism
      for either case.

      [Error (Malformed_response _)] if more than one item matches:
      DynamoDB only guarantees pk+sk uniqueness on the table's own primary
      key ([I.index_name = None]); it does {e not} enforce uniqueness on a
      global/local secondary index, so a fully-specified key can
      legitimately match more than one item there. Use {!query} instead of
      [get] on an index where that can happen — [get] fails loud rather
      than silently returning one arbitrary match. *)

  val interpret_get_results : Dynamo_client.item list -> (Dynamo_client.item option, Dynamo_error.t) result
  (** [get]'s pure result-interpretation step, exposed for testing — no
      network call needed to exercise the multi-item (non-unique-index)
      case. *)

  val query :
    net:_ Eio.Net.t -> clock:_ Eio.Time.clock -> Dynamo_client.config ->
    pk:I.pk -> unit -> (Dynamo_client.item list, Dynamo_error.t) result
  (** Every item under [pk] on this index. [sk] is deliberately not a
      parameter — a query needing a sort-key condition beyond "every item in
      this partition" is real, deferred scope; see [dynamo-eio.md]. *)
end

module type ENTITY = sig
  val name : string
end

module Entity (E : ENTITY) : sig
  val discriminator_attribute : string

  val stamp : Dynamo_client.item -> Dynamo_client.item
  (** Adds the discriminator attribute — call before {!Dynamo_client.put_item}. *)

  val check : Dynamo_client.item -> (Dynamo_client.item, Dynamo_error.t) result
  (** [Error (Wrong_entity _)] if the stamped name doesn't match [E.name] (or
      is missing entirely) — call on whatever {!Dynamo_client.get_item}/
      {!Index.get}/{!Index.query} returned before treating it as this
      entity's shape. *)
end
