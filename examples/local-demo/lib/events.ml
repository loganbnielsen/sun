(** Event contracts for the Sun demo.
    In a real Sun workspace these would live in events/<team>/<name>.ml,
    owned by the team that publishes them and imported by consuming workers. *)

module OrderPlaced = struct
  type t = {
    order_id       : string;
    item           : string;
    quantity       : int;
    correlation_id : string;  (* propagated from the HTTP X-Correlation-Id header *)
  }

  let topic_name = "sun-demo-orders"

  let schema = {|{
    "type": "object",
    "properties": {
      "order_id":       { "type": "string"  },
      "item":           { "type": "string"  },
      "quantity":       { "type": "integer" },
      "correlation_id": { "type": "string"  }
    },
    "required": ["order_id", "item", "quantity", "correlation_id"]
  }|}

  let encode t = `Assoc [
    ("order_id",       `String t.order_id);
    ("item",           `String t.item);
    ("quantity",       `Int    t.quantity);
    ("correlation_id", `String t.correlation_id);
  ]

  let decode = function
    | `Assoc fields ->
      let get_s k = match List.assoc_opt k fields with
        | Some (`String s) -> Some s
        | _ -> None
      in
      let get_i k = match List.assoc_opt k fields with
        | Some (`Int i) -> Some i
        | _ -> None
      in
      (match get_s "order_id", get_s "item", get_i "quantity", get_s "correlation_id" with
       | Some order_id, Some item, Some quantity, Some correlation_id ->
         Ok { order_id; item; quantity; correlation_id }
       | _ -> Error "missing required fields")
    | _ -> Error "expected object"
end
