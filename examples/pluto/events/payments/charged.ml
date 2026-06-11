type t = {
  id             : string;
  amount_cents   : int;
  customer_id    : string;
  currency       : string;
  correlation_id : string;
}

let topic_name = "pluto-payments-charges"

let schema = {|{
  "type": "object",
  "properties": {
    "id":             { "type": "string"  },
    "amount_cents":   { "type": "integer" },
    "customer_id":    { "type": "string"  },
    "currency":       { "type": "string"  },
    "correlation_id": { "type": "string"  }
  },
  "required": ["id", "amount_cents", "customer_id", "currency", "correlation_id"]
}|}

let encode t = `Assoc [
  ("id",             `String t.id);
  ("amount_cents",   `Int    t.amount_cents);
  ("customer_id",    `String t.customer_id);
  ("currency",       `String t.currency);
  ("correlation_id", `String t.correlation_id);
]

let decode = function
  | `Assoc fields ->
    let get_s k = match List.assoc_opt k fields with Some (`String s) -> Some s | _ -> None in
    let get_i k = match List.assoc_opt k fields with Some (`Int i)    -> Some i | _ -> None in
    (match get_s "id", get_i "amount_cents", get_s "customer_id",
           get_s "currency", get_s "correlation_id" with
     | Some id, Some amount_cents, Some customer_id,
       Some currency, Some correlation_id ->
       Ok { id; amount_cents; customer_id; currency; correlation_id }
     | _ -> Error "missing required fields")
  | _ -> Error "expected object"
