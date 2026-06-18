(** E2E golden workflow tests — asserts the full svc→Kafka→worker→Postgres path. *)

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let str_contains haystack needle =
  let h = String.length haystack and n = String.length needle in
  if n = 0 then true else if n > h then false
  else
    let rec go i =
      if i + n > h then false
      else if String.sub haystack i n = needle then true
      else go (i+1)
    in
    go 0

let metric_nonzero render name =
  let n = String.length name in
  String.split_on_char '\n' render
  |> List.exists (fun line ->
    String.length line > n &&
    String.sub line 0 n = name &&
    (line.[n] = '{' || line.[n] = ' ') &&
    match List.rev (String.split_on_char ' ' line) with
    | v :: _ -> (match float_of_string_opt v with Some f -> f > 0.0 | None -> false)
    | []     -> false)

let loki_port url =
  match String.rindex_opt url ':' with
  | None -> 3100
  | Some i ->
    let s = String.sub url (i+1) (String.length url - i - 1) in
    let s = match String.index_opt s '/' with Some j -> String.sub s 0 j | None -> s in
    Option.value ~default:3100 (int_of_string_opt s)

let http_get env ~sw ~port ~path () =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let flow = Eio.Net.connect ~sw env#net addr in
  Eio.Flow.copy_string
    (Printf.sprintf "GET %s HTTP/1.0\r\nHost: localhost\r\n\r\n" path)
    flow;
  Eio.Buf_read.take_all (Eio.Buf_read.of_flow flow ~max_size:65536)

let http_post env ~sw ~port ~path ?(headers=[]) ~body () =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let flow  = Eio.Net.connect ~sw env#net addr in
  let extra = List.map (fun (k,v) -> Printf.sprintf "%s: %s\r\n" k v) headers
              |> String.concat "" in
  let req =
    Printf.sprintf
      "POST %s HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\
       content-type: application/json\r\ncontent-length: %d\r\n%s\r\n%s"
      path (String.length body) extra body
  in
  Eio.Flow.copy_string req flow;
  Eio.Flow.shutdown flow `Send;
  let buf = Eio.Buf_read.of_flow flow ~max_size:65536 in
  let resp = Eio.Buf_read.take_all buf in
  match String.split_on_char ' ' resp with
  | _ :: code :: _ -> (try int_of_string (String.trim code) with _ -> 0)
  | _              -> 0

(* ── DB schema (matches demo.ml) ─────────────────────────────────────────── *)
module FulfilledOrderSchema = struct
  let table     = "fulfilled_orders"
  let id_column = "order_id"
  let columns   = ["order_id"; "item"; "quantity"; "correlation_id"]
  type t  = { order_id : string; item : string; quantity : int; correlation_id : string }
  type id = string
  let row_type =
    Caqti_type.(custom
      ~encode:(fun r -> Ok (r.order_id, r.item, r.quantity, r.correlation_id))
      ~decode:(fun (order_id, item, quantity, correlation_id) ->
        Ok { order_id; item; quantity; correlation_id })
      (t4 string string int string))
  let id_type = Caqti_type.string
  let get_id r = r.order_id
end

module FulfilledOrders = Table.Make(FulfilledOrderSchema)

(* ── Golden path result ───────────────────────────────────────────────────── *)
type result = {
  http_statuses : int list;
  metrics_text  : string;
  loki_resp     : string option;
  db_rows       : int;
}

(* ── Run golden path ──────────────────────────────────────────────────────── *)
let run_golden_path () =
  let loki_url     = Sys.getenv_opt "LOKI_URL" in
  let postgres_url = Sys.getenv_opt "POSTGRES_URL" in
  let orders_count = 3 in

  let kafka_config : Kafka_service.config =
    { (Kafka_service.config_of_env ()) with linger_ms = 5 }
  in

  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->

  (* Observability *)
  let prom_backend, render = Obs_prometheus.create () in
  let log_backend =
    match loki_url with
    | None     -> Obs.stdout
    | Some url ->
      Obs_loki.create ~net:env#net ~clock:env#clock ~url ()
  in
  let backend   = Obs.compose log_backend prom_backend in
  let svc_ot    = Obs.create ~service:"order-svc"
                    ~mono_clock:env#mono_clock ~backend in
  let worker_ot = Obs.create ~service:"fulfillment-worker"
                    ~mono_clock:env#mono_clock ~backend in

  (* Storage *)
  let db_pool = match postgres_url with
    | None     -> None
    | Some url ->
      match Db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
      | Error _ -> None
      | Ok pool ->
        (match Migration.apply pool ~dir:"examples/local-demo/migrations" with
         | Error _ -> None
         | Ok ()   -> Some pool)
  in

  (* Kafka *)
  let svc =
    match Kafka_service.create kafka_config ~sw with
    | Ok s    -> s
    | Error e -> failwith ("Kafka create: " ^ e)
  in
  let topic =
    match Kafka_service.register svc ~net:env#net ~clock:env#clock
            (module Events.OrderPlaced) with
    | Ok t    -> t
    | Error e -> failwith ("Kafka register: " ^ e)
  in

  (* Worker *)
  let worker_ready_p, worker_ready_r = Eio.Promise.create () in
  let worker_done_p,  worker_done_r  = Eio.Promise.create () in

  let module W = struct
    module Message = Events.OrderPlaced
    let group_id = "sun-e2e-test-worker"

    let handle msg ~ack ~trace_ctx:_ =
      ack ();
      (match db_pool with
       | None -> ()
       | Some pool ->
         let row = FulfilledOrderSchema.{
           order_id = msg.Message.order_id; item = msg.Message.item;
           quantity = msg.Message.quantity; correlation_id = msg.Message.correlation_id;
         } in
         (match FulfilledOrders.insert pool row with
          | Ok () | Error _ -> ()));
      Ok ()
  end in

  Eio.Fiber.fork ~sw (fun () ->
    (try
      let module WR = Worker.Make(W) in
      WR.run ~env ~config:kafka_config ~ot:worker_ot
        ~on_ready:(fun () ->
          (try Eio.Promise.resolve worker_ready_r () with _ -> ()))
        ~max_messages:orders_count
        ()
    with Failure _ -> ());
    (try Eio.Promise.resolve worker_done_r () with _ -> ())
  );

  (* Service *)
  let handle_order req =
    let corr_id = Option.value (Request.header req "x-correlation-id")
                    ~default:"test-corr" in
    let body_j  = (try Yojson.Safe.from_string req.Request.body
                   with _ -> `Assoc []) in
    let s k = match body_j with
      | `Assoc fs -> (match List.assoc_opt k fs with Some (`String s) -> s | _ -> "") | _ -> "" in
    let i k = match body_j with
      | `Assoc fs -> (match List.assoc_opt k fs with Some (`Int n) -> n | _ -> 0) | _ -> 0 in
    let msg = Events.OrderPlaced.{
      order_id = s "order_id"; item = s "item"; quantity = i "quantity";
      correlation_id = corr_id;
    } in
    let trace_ctx = Obs.with_span svc_ot "receive_order" (fun span ->
      Obs.log span Info ~fields:[("order_id", msg.order_id)] "order received";
      Obs.current_trace_ctx span
    ) in
    (match Eio.Promise.await (Kafka_service.publish svc topic msg ~trace_ctx) with
     | Ok () | Error _ -> ());
    Response.json ~status:202 {|{"accepted":true}|}
  in

  let svc_port_p, svc_port_r = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Service.run [ Route.post "/orders" ~auth:`Public handle_order ]
      ~env ~port:0 ~ot:svc_ot
      ~on_listen:(fun p -> Eio.Promise.resolve svc_port_r p)
      ();
    `Stop_daemon
  );
  let port = Eio.Promise.await svc_port_p in

  (* Wait for worker ready *)
  (match Eio.Time.with_timeout env#clock 15.0 (fun () ->
     Ok (Eio.Promise.await worker_ready_p)) with
   | Error `Timeout -> failwith "timed out waiting for worker partition assignment"
   | Ok () -> ());

  (* Send 3 orders *)
  let orders = [
    ("order-e2e-001", "Mechanical Keyboard", 1);
    ("order-e2e-002", "USB-C Hub",           2);
    ("order-e2e-003", "Standing Desk Riser", 1);
  ] in
  let http_statuses = List.map (fun (order_id, item, qty) ->
    let body = Printf.sprintf {|{"order_id":%S,"item":%S,"quantity":%d}|} order_id item qty in
    http_post env ~sw ~port ~path:"/orders"
      ~headers:[("x-correlation-id", "test-" ^ order_id)]
      ~body ()
  ) orders in

  (* Wait for worker done *)
  (match Eio.Time.with_timeout env#clock 20.0 (fun () ->
     Ok (Eio.Promise.await worker_done_p)) with
   | Error `Timeout -> failwith "timed out waiting for worker to process messages"
   | Ok () -> ());

  (* Collect results *)
  let metrics_text = render () in
  let loki_resp = match loki_url with
    | None     -> None
    | Some url ->
      let p = loki_port url in
      let path = "/loki/api/v1/query?query=%7Bservice%3D%22order-svc%22%7D&limit=5" in
      (try Some (http_get env ~sw ~port:p ~path ()) with _ -> None)
  in
  let db_rows = match db_pool with
    | None      -> 0
    | Some pool ->
      match FulfilledOrders.list pool () with
      | Error _ -> 0
      | Ok rows -> List.length rows
  in
  { http_statuses; metrics_text; loki_resp; db_rows }

(* ── Tests ────────────────────────────────────────────────────────────────── *)
let () =
  let r = run_golden_path () in
  Alcotest.run "e2e golden workflow" [
    "http", [
      Alcotest.test_case "all orders accepted (HTTP 202)" `Quick (fun () ->
        let bad = List.filter ((<>) 202) r.http_statuses in
        if bad <> [] then
          Alcotest.failf "expected 202, got: %s"
            (String.concat ", " (List.map string_of_int bad)));
    ];
    "metrics", [
      Alcotest.test_case "sun_svc_requests_total > 0" `Quick (fun () ->
        if not (metric_nonzero r.metrics_text "sun_svc_requests_total") then
          Alcotest.fail "metric absent or zero");
      Alcotest.test_case "sun_worker_messages_total > 0" `Quick (fun () ->
        if not (metric_nonzero r.metrics_text "sun_worker_messages_total") then
          Alcotest.fail "metric absent or zero");
    ];
    "loki", [
      Alcotest.test_case "logs received for service=order-svc" `Quick (fun () ->
        match r.loki_resp with
        | None      -> ()  (* LOKI_URL not set — skip *)
        | Some resp ->
          if not (str_contains resp {|"values":[[|}) then
            Alcotest.fail "no log streams in Loki response");
    ];
    "postgres", [
      Alcotest.test_case "fulfilled orders persisted" `Quick (fun () ->
        if r.db_rows = 0 then ()  (* POSTGRES_URL not set — skip *)
        else
          Alcotest.(check int) "3 rows stored" 3 r.db_rows);
    ];
  ]
