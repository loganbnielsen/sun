(** Sun end-to-end demo
    ─────────────────────────────────────────────────────────────────────────
    Full stack in one binary:

      HTTP client
          │  POST /orders  {order_id, item, quantity}  +  X-Correlation-Id
          ▼
      order-svc  (sun-svc)
          │  Loki span: "receive_order"  ·  Prometheus: svc request metrics
          │  publishes OrderPlaced event with W3C traceparent header
          ▼
      Kafka  sun-demo-orders
          │
          ▼
      fulfillment-worker  (sun-worker)
          │  Loki span: "fulfill_order"  ·  Prometheus: worker message metrics
          │  records fulfilled order in PostgreSQL  (sun-storage)
          ▼
      Loki (logs) · Prometheus (metrics) · PostgreSQL (storage)
      Grafana  http://localhost:3000

    Run:
      bash platform/local/scripts/ensure-broker.sh
      bash platform/local/scripts/ensure-postgres.sh       # optional — skipped if absent
      bash platform/local/scripts/ensure-loki.sh           # optional — logs to stdout if absent
      bash platform/local/scripts/ensure-grafana.sh        # optional
      bash platform/local/scripts/ensure-prometheus.sh     # optional

      KAFKA_BROKERS=localhost:9092 \
      POSTGRES_URL=postgresql://postgres:dev@localhost:5432/sun_dev \
      LOKI_URL=http://localhost:3100 \
        dune exec examples/local-demo/bin/demo.exe
*)

(* ── Config from environment ────────────────────────────────────────────── *)

let loki_url        = Sys.getenv_opt "LOKI_URL"
let pushgateway_url = Sys.getenv_opt "PUSHGATEWAY_URL"
let postgres_url    = Sys.getenv_opt "POSTGRES_URL"

let kafka_config : Kafka_service.config =
  { (Kafka_service.config_of_env ()) with linger_ms = 5 }

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let sep = String.make 60 '-'

let say fmt = Printf.ksprintf (fun s -> Printf.printf "\n[demo] %s\n%!" s) fmt

let new_corr_id () = Printf.sprintf "c-%06x" (Random.int 0xFFFFFF)

(* ── Assertion helpers ────────────────────────────────────────────────────── *)

let http_get env ~sw ~port ~path () =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let flow = Eio.Net.connect ~sw env#net addr in
  Eio.Flow.copy_string
    (Printf.sprintf "GET %s HTTP/1.0\r\nHost: localhost\r\n\r\n" path)
    flow;
  (* No shutdown — HTTP/1.0 server closes after response; shutdown before
     reading triggers 499 "client cancelled" on some proxied services. *)
  Eio.Buf_read.take_all (Eio.Buf_read.of_flow flow ~max_size:65536)

let loki_port url =
  match String.rindex_opt url ':' with
  | None -> 3100
  | Some i ->
    let s = String.sub url (i+1) (String.length url - i - 1) in
    let s = match String.index_opt s '/' with Some j -> String.sub s 0 j | None -> s in
    Option.value ~default:3100 (int_of_string_opt s)

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

(* ── HTTP helper ──────────────────────────────────────────────────────────── *)

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

(* ── Fulfilled order schema (sun-storage Table.Make) ────────────────────── *)

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

(* ── Main ───────────────────────────────────────────────────────────────── *)

let () =
  Random.self_init ();
  Printf.printf "\n%s\n" sep;
  Printf.printf "  Sun End-to-End Demo\n";
  Printf.printf "%s\n" sep;
  Printf.printf "  Kafka brokers:   %s\n" (String.concat "," kafka_config.brokers);
  Printf.printf "  Schema registry: %s\n" kafka_config.schema_registry_url;
  Printf.printf "  Loki:            %s\n" (Option.value ~default:"(stdout fallback)" loki_url);
  Printf.printf "  Pushgateway:     %s\n" (Option.value ~default:"(disabled)" pushgateway_url);
  Printf.printf "  Postgres:        %s\n%!" (Option.value ~default:"(disabled)" postgres_url);

  Eio_main.run @@ fun env ->

  (* ── Observability ─────────────────────────────────────────────────────── *)
  let prom_backend, render = Obs_prometheus.create () in
  let log_backend =
    match loki_url with
    | None ->
      Printf.printf "\n  Note: LOKI_URL not set — logs to stdout.\n%!";
      Obs.stdout
    | Some url ->
      Printf.printf "\n  Logs -> Loki at %s\n%!" url;
      Obs_loki.create ~net:env#net ~clock:env#clock ~url ~label_names:["service"] ()
  in
  let backend   = Obs.compose log_backend prom_backend in
  let svc_ot    = Obs.create ~service:"order-svc"
                    ~mono_clock:env#mono_clock ~backend in
  let worker_ot = Obs.create ~service:"fulfillment-worker"
                    ~mono_clock:env#mono_clock ~backend in

  Eio.Switch.run @@ fun sw ->

  (* ── Storage (optional) ────────────────────────────────────────────────── *)
  let db_pool = match postgres_url with
    | None ->
      Printf.printf "\n  Note: POSTGRES_URL not set — skipping DB storage.\n%!";
      None
    | Some url ->
      (match Db.create_pool ~url ~sw ~stdenv:(env :> Caqti_eio.stdenv) () with
       | Error e -> failwith ("db pool: " ^ Storage_error.to_string e)
       | Ok pool ->
         (match Migration.apply pool ~dir:"examples/local-demo/migrations" with
          | Error e -> failwith ("migrations: " ^ Storage_error.to_string e)
          | Ok ()   ->
            Printf.printf "\n  DB -> Postgres  (migrations applied)\n%!";
            Some pool))
  in

  (* ── Shared Kafka handle ────────────────────────────────────────────────── *)
  say "registering topic %S ..." Events.OrderPlaced.topic_name;
  let svc =
    match Kafka_service.create kafka_config ~sw with
    | Ok s    -> s
    | Error e -> failwith ("create: " ^ e)
  in
  let topic =
    match Kafka_service.register svc ~net:env#net ~clock:env#clock
            (module Events.OrderPlaced) with
    | Ok t    -> t
    | Error e -> failwith ("register: " ^ e)
  in
  say "topic ready.";

  (* ── Fulfillment worker ────────────────────────────────────────────────── *)
  let orders_count = 3 in
  let worker_ready_p, worker_ready_r = Eio.Promise.create () in
  let worker_done_p,  worker_done_r  = Eio.Promise.create () in

  let module W = struct
    module Message = Events.OrderPlaced
    let group_id = "sun-demo-fulfillment-worker"

    let handle msg ~ack ~trace_ctx =
      ack ();
      Obs.with_span worker_ot ?parent:trace_ctx "fulfill_order" (fun span ->
        Obs.log span Info
          ~fields:[("order_id", msg.Message.order_id);
                   ("item",     msg.Message.item);
                   ("quantity", string_of_int msg.Message.quantity)]
          "fulfilling order"
      );
      (match db_pool with
       | None -> ()
       | Some pool ->
         let row = FulfilledOrderSchema.{
           order_id       = msg.Message.order_id;
           item           = msg.Message.item;
           quantity       = msg.Message.quantity;
           correlation_id = msg.Message.correlation_id;
         } in
         (match FulfilledOrders.insert pool row with
          | Ok ()   -> ()
          | Error e ->
            Printf.eprintf "[worker] db error: %s\n%!" (Storage_error.to_string e)));
      Printf.printf "[worker] fulfilled  order=%-12s item=%-22s\n%!"
        msg.Message.order_id msg.Message.item;
      Ok ()
  end in

  Eio.Fiber.fork ~sw (fun () ->
    (try
      let module WR = Worker.Make(W) in
      WR.run ~env ~config:kafka_config ~ot:worker_ot
        ~on_ready:(fun () ->
          Printf.printf "[worker] partition assigned — ready\n%!";
          (try Eio.Promise.resolve worker_ready_r () with _ -> ()))
        ~max_messages:orders_count
        ()
    with Failure msg ->
      Printf.eprintf "[worker] error: %s\n%!" msg);
    (try Eio.Promise.resolve worker_done_r () with _ -> ())
  );

  (* ── Order svc ─────────────────────────────────────────────────────────── *)
  let handle_order req =
    let corr_id = Option.value (Request.header req "x-correlation-id")
                    ~default:(new_corr_id ()) in
    let body_j  = (try Yojson.Safe.from_string req.Request.body
                   with _ -> `Assoc []) in
    let s k = match body_j with
      | `Assoc fs -> (match List.assoc_opt k fs with Some (`String s) -> s | _ -> "")
      | _ -> "" in
    let i k = match body_j with
      | `Assoc fs -> (match List.assoc_opt k fs with Some (`Int n) -> n | _ -> 0)
      | _ -> 0 in
    let msg = Events.OrderPlaced.{
      order_id = s "order_id"; item = s "item"; quantity = i "quantity";
      correlation_id = corr_id;
    } in
    let span_ot = Obs.with_context svc_ot [("correlation_id", corr_id)] in
    let trace_ctx = Obs.with_span span_ot "receive_order" (fun span ->
      Obs.log span Info
        ~fields:[("order_id", msg.order_id); ("item", msg.item)]
        "order received";
      Obs.current_trace_ctx span
    ) in
    Printf.printf "[svc]    received    order=%-12s item=%-22s corr=%s\n%!"
      msg.order_id msg.item corr_id;
    (match Eio.Promise.await (Kafka_service.publish svc topic msg ~trace_ctx) with
     | Ok ()    -> ()
     | Error ke ->
       Printf.eprintf "[svc]    publish error: %s\n%!" (Kafka_error.to_string ke));
    Response.json ~status:202 {|{"accepted":true}|}
  in

  let svc_port_p, svc_port_r = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Service.run [ Route.post "/orders" ~auth:`Public handle_order ]
      ~env ~port:0 ~ot:svc_ot
      ~on_listen:(fun p ->
        Printf.printf "[svc]    listening on port %d\n%!" p;
        Eio.Promise.resolve svc_port_r p)
      ();
    `Stop_daemon
  );
  let port = Eio.Promise.await svc_port_p in

  (* ── Wait for worker partition assignment ───────────────────────────────── *)
  say "waiting for worker partition assignment (up to 15s) ...";
  (match Eio.Time.with_timeout env#clock 15.0 (fun () ->
     Ok (Eio.Promise.await worker_ready_p)) with
   | Error `Timeout -> failwith "timed out waiting for worker partition assignment"
   | Ok () -> ());

  (* ── Send 3 orders ──────────────────────────────────────────────────────── *)
  Printf.printf "\n%s\n%!" sep;
  let orders = [
    ("order-001", "Mechanical Keyboard",  1);
    ("order-002", "USB-C Hub",            2);
    ("order-003", "Standing Desk Riser",  1);
  ] in
  let http_statuses = List.map (fun (order_id, item, qty) ->
    let corr_id = new_corr_id () in
    let body = Printf.sprintf {|{"order_id":%S,"item":%S,"quantity":%d}|}
                 order_id item qty in
    let status = http_post env ~sw ~port ~path:"/orders"
                   ~headers:[("x-correlation-id", corr_id)]
                   ~body () in
    Printf.printf "[client] POST /orders order=%-12s -> HTTP %d  corr=%s\n%!"
      order_id status corr_id;
    status
  ) orders in
  Printf.printf "%s\n%!" sep;

  (* ── Wait for worker to finish ──────────────────────────────────────────── *)
  say "waiting for worker to process all %d messages (up to 20s) ..." orders_count;
  (match Eio.Time.with_timeout env#clock 20.0 (fun () ->
     Ok (Eio.Promise.await worker_done_p)) with
   | Error `Timeout ->
     Printf.eprintf "[demo] timed out waiting for worker — Kafka hang detected\n%!";
     exit 1
   | Ok () -> ());
  say "all %d messages processed." orders_count;

  (* ── PostgreSQL results ─────────────────────────────────────────────────── *)
  (match db_pool with
   | None -> ()
   | Some pool ->
     Printf.printf "\n%s\n" sep;
     Printf.printf "  Fulfilled orders in PostgreSQL\n";
     Printf.printf "%s\n" sep;
     (match FulfilledOrders.list pool () with
      | Error e ->
        Printf.eprintf "  db query error: %s\n%!" (Storage_error.to_string e)
      | Ok rows ->
        List.iter (fun (r : FulfilledOrderSchema.t) ->
          Printf.printf "  %-12s  %-24s  qty=%-3d  corr=%s\n"
            r.order_id r.item r.quantity r.correlation_id
        ) rows;
        Printf.printf "%s\n%!" sep));

  (* ── Prometheus metrics snapshot ────────────────────────────────────────── *)
  Printf.printf "\n%s\n" sep;
  Printf.printf "  Prometheus metrics snapshot\n";
  Printf.printf "%s\n" sep;
  Printf.printf "%s\n%!" (render ());

  (* ── Optional Pushgateway push ──────────────────────────────────────────── *)
  (match pushgateway_url with
   | None -> ()
   | Some url ->
     (match Obs_prometheus.push ~net:env#net ~clock:env#clock
              ~url ~job:"sun-demo" render with
      | Ok ()   -> say "metrics pushed to %s" url
      | Error e -> Printf.eprintf "[demo] push failed: %s\n%!" e));

  (* ── Assertions ─────────────────────────────────────────────────────────── *)
  Printf.printf "\n%s\n" sep;
  Printf.printf "  Assertions\n";
  Printf.printf "%s\n" sep;

  let fails = ref 0 in
  let check label ok detail =
    if ok then Printf.printf "  \xe2\x9c\x93 %s\n%!" label
    else begin
      Printf.printf "  \xe2\x9c\x97 %s — %s\n%!" label detail;
      incr fails
    end
  in

  check "HTTP: all orders accepted (202)"
    (List.for_all (( = ) 202) http_statuses)
    ("got [" ^ String.concat "; " (List.map string_of_int http_statuses) ^ "]");

  let metrics_text = render () in
  check "Prometheus: sun_svc_requests_total > 0"
    (metric_nonzero metrics_text "sun_svc_requests_total") "metric absent or zero";
  check "Prometheus: sun_worker_messages_total > 0"
    (metric_nonzero metrics_text "sun_worker_messages_total") "metric absent or zero";

  (match loki_url with
   | None -> ()
   | Some url ->
     let port = loki_port url in
     let path = "/loki/api/v1/query?query=%7Bservice%3D%22order-svc%22%7D&limit=5" in
     (match (try Some (http_get env ~sw ~port ~path ()) with _ -> None) with
      | None -> check "Loki: logs received" false "connection failed"
      | Some resp ->
        check "Loki: logs received for service=order-svc"
          (str_contains resp {|"values":[[|})
          "no log streams in response"));

  (match db_pool with
   | None -> ()
   | Some pool ->
     (match FulfilledOrders.list pool () with
      | Error e -> check "PostgreSQL" false (Storage_error.to_string e)
      | Ok rows ->
        let n = List.length rows in
        check (Printf.sprintf "PostgreSQL: %d fulfilled orders stored" orders_count)
          (n >= orders_count) (Printf.sprintf "found %d rows" n)));

  Printf.printf "%s\n%!" sep;
  if !fails > 0 then begin
    Printf.printf "\n  %d assertion(s) failed.\n%!" !fails;
    exit 1
  end;

  Printf.printf "\n%s\n" sep;
  Printf.printf "  Done.\n";
  Printf.printf "  Grafana:  http://localhost:3000\n";
  Printf.printf "    Logs:    Explore > Loki > {service=~\".*\"}\n";
  Printf.printf "    Metrics: Explore > Prometheus > sun_svc_requests_total\n";
  Printf.printf "%s\n%!" sep
