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

let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _              -> Error (name ^ " must be a string")
  | None                -> Error (name ^ " is required")

let required_int fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _            -> Error (name ^ " must be an integer")
  | None              -> Error (name ^ " is required")

let decode = function
  | `Assoc fields ->
    Result.bind (required_string fields "payment_id") @@ fun payment_id ->
    Result.bind (required_string fields "charge_id") @@ fun charge_id ->
    Result.bind (required_string fields "customer_id") @@ fun customer_id ->
    Result.bind (required_int fields "amount_cents") @@ fun amount_cents ->
    Result.map
      (fun currency ->
         { payment_id; charge_id; customer_id; amount_cents; currency })
      (required_string fields "currency")
  | _ -> Error "expected object"
