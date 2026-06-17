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
    Result.bind (required_string fields "id") @@ fun id ->
    Result.bind (required_int fields "amount_cents") @@ fun amount_cents ->
    Result.bind (required_string fields "customer_id") @@ fun customer_id ->
    Result.bind (required_string fields "currency") @@ fun currency ->
    Result.map
      (fun correlation_id ->
         { id; amount_cents; customer_id; currency; correlation_id })
      (required_string fields "correlation_id")
  | _ -> Error "expected object"
