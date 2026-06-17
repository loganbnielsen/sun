(* POST /charges  — write notification to DB (if POSTGRES_URL is set in cluster)
   GET  /health      — liveness probe
   GET  /notifications — list recent charges from DB *)

let routes pool = [
  Route.get "/health" ~auth:`Public (fun _req ->
    Response.ok "ok"
  );
  Route.post "/charges" ~auth:`Public (fun req ->
    let j     = Yojson.Basic.from_string req.body in
    let get_s k = Yojson.Basic.Util.(j |> member k |> to_string_option
                  |> Option.value ~default:"") in
    let get_i k = Yojson.Basic.Util.(j |> member k |> to_int_option
                  |> Option.value ~default:0) in
    let charge_id = Printf.sprintf "ch_%06d" (Random.int 999999) in
    (match pool with
     | None -> ()
     | Some p ->
       ignore (Notification.insert p
         ~charge_id ~customer_id:(get_s "customer_id")
         ~amount_cents:(get_i "amount_cents") ~currency:(get_s "currency")));
    Response.json ~status:202
      (Printf.sprintf {|{"id":"%s","accepted":true}|} charge_id)
  );
  Route.get "/notifications" ~auth:`Public (fun _req ->
    match pool with
    | None ->
      Response.json {|[]|}
    | Some p ->
      (match Notification.list_recent p with
       | Error _  -> Response.json ~status:500 {|{"error":"db unavailable"}|}
       | Ok rows  ->
         let row_json (charge_id, customer_id, amount_cents, currency) =
           `Assoc [
             ("charge_id",    `String charge_id);
             ("customer_id",  `String customer_id);
             ("amount_cents", `Int amount_cents);
             ("currency",     `String currency);
           ]
         in
         Response.json (Yojson.Basic.to_string (`List (List.map row_json rows))))
  );
]
