type t = {
  payment_id   : string;
  charge_id    : string;
  customer_id  : string;
  amount_cents : int;
  currency     : string;
}

let topic_name = "venus-billing-payment-confirmed"

let schema = {|{
  "type": "object",
  "properties": {
    "payment_id":   { "type": "string"  },
    "charge_id":    { "type": "string"  },
    "customer_id":  { "type": "string"  },
    "amount_cents": { "type": "integer" },
    "currency":     { "type": "string"  }
  },
  "required": ["payment_id", "charge_id", "customer_id", "amount_cents", "currency"]
}|}

let encode t = `Assoc [
  ("payment_id",   `String t.payment_id);
  ("charge_id",    `String t.charge_id);
  ("customer_id",  `String t.customer_id);
  ("amount_cents", `Int    t.amount_cents);
  ("currency",     `String t.currency);
]

let decode = function
  | `Assoc fields ->
    let get_s k = match List.assoc_opt k fields with Some (`String s) -> Some s | _ -> None in
    let get_i k = match List.assoc_opt k fields with Some (`Int i)    -> Some i | _ -> None in
    (match get_s "payment_id", get_s "charge_id", get_s "customer_id",
           get_i "amount_cents", get_s "currency" with
     | Some payment_id, Some charge_id, Some customer_id,
       Some amount_cents, Some currency ->
       Ok { payment_id; charge_id; customer_id; amount_cents; currency }
     | _ -> Error "missing required fields")
  | _ -> Error "expected object"
