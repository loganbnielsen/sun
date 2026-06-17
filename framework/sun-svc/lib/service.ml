module type HANDLER = sig
  val routes : Route.t list
end

(* ── Routing ───────────────────────────────────────────────────────────── *)

type route_match =
  | Found             of Route.t * (string * string) list
  | Method_not_allowed
  | Not_found

let find_route routes meth path =
  let path_matched = ref false in
  let rec loop = function
    | [] ->
      if !path_matched then Method_not_allowed else Not_found
    | r :: rest ->
      (match Route.match_path r.Route.pattern path with
       | None -> loop rest
       | Some params ->
         path_matched := true;
         if r.Route.method_ = meth then Found (r, params)
         else loop rest)
  in
  loop routes

(* ── HTTP status conversion ────────────────────────────────────────────── *)

let http_status_of_int = function
  | 200 -> `OK
  | 201 -> `Created
  | 204 -> `No_content
  | 400 -> `Bad_request
  | 401 -> `Unauthorized
  | 403 -> `Forbidden
  | 404 -> `Not_found
  | 405 -> `Method_not_allowed
  | 413 -> `Request_entity_too_large
  | 422 -> `Unprocessable_entity
  | 500 -> `Internal_server_error
  | 501 -> `Not_implemented
  | n   -> `Code n

(* ── Body reading ──────────────────────────────────────────────────────── *)

let read_body_limited headers (body : Cohttp_eio.Body.t) max_bytes =
  let too_large_from_header =
    match Http.Header.get headers "content-length" with
    | None   -> false
    | Some s -> (try int_of_string (String.trim s) > max_bytes with _ -> false)
  in
  if too_large_from_header then None
  else
    match
      let buf = Eio.Buf_read.of_flow body ~max_size:max_bytes in
      Eio.Buf_read.take_all buf
    with
    | exception Eio.Buf_read.Buffer_limit_exceeded -> None
    | s -> Some s

(* ── Dispatch ──────────────────────────────────────────────────────────── *)

let ( let* ) = Result.bind

let auth_result auth_cfg headers =
  match Auth.validate auth_cfg headers with
  | Error (`Unauthorized _)    -> Error Response.unauthorized
  | Error (`Forbidden _)       -> Error Response.forbidden
  | Error (`Server_error msg)  -> Error (Response.internal_error msg)
  | Error (`Not_implemented _) -> Error Response.not_implemented
  | Ok ctx -> Ok ctx

let body_result headers body max_bytes =
  match read_body_limited headers body max_bytes with
  | None   -> Error Response.payload_too_large
  | Some s -> Ok s

let dispatch ~routes ~metrics_renderer ~metrics_auth ~max_body_bytes ?route_observer req body =
  let meth_opt = Route.method_of_http (Http.Request.meth req) in
  match meth_opt with
  | None -> { Response.status = 405; headers = []; body = "" }
  | Some meth ->
    let resource = Http.Request.resource req in
    let uri      = Uri.of_string resource in
    let path     = Uri.path uri in
    let headers  = Http.Request.headers req in
    if Route.parse_request_path path = None then
      { Response.status = 400; headers = []; body = "Bad Request" }
    else
    let observe lbl = match route_observer with Some f -> f lbl | None -> () in
    let builtin =
      match meth, path with
      | `GET, "/healthz" ->
        observe "/healthz";
        Some (Response.json {|{"status":"ok"}|})
      | `GET, "/metrics" ->
        observe "/metrics";
        (match metrics_renderer with
         | None -> Some Response.not_found
         | Some render ->
           let result =
             let* _ = auth_result metrics_auth headers in
             Ok (Response.ok
               ~headers:["content-type","text/plain; version=0.0.4; charset=utf-8"]
               (render ()))
           in
           Some (match result with Ok r | Error r -> r))
      | _ -> None
    in
    (match builtin with
     | Some r -> r
     | None ->
       match find_route routes meth path with
       | Not_found          -> observe "unmatched"; Response.not_found
       | Method_not_allowed -> observe "unmatched"; { Response.status = 405; headers = []; body = "" }
       | Found (route, params) ->
         observe (Route.pattern_to_string route.Route.pattern);
         let result =
           let* auth_ctx = auth_result route.Route.auth headers in
           let* body_str = body_result headers body max_body_bytes in
           let trace_ctx =
             Http.Header.to_list headers
             |> Obs_trace.extract_from_headers
           in
           let sun_req = Request.{
             method_    = meth;
             path;
             headers;
             params;
             uri;
             body       = body_str;
             auth       = auth_ctx;
             trace_ctx;
           } in
           (try Ok (route.Route.handler sun_req)
            with exn ->
              Printf.eprintf "sun-svc: handler exception: %s\n%!"
                (Printexc.to_string exn);
              Ok (Response.internal_error "Internal server error"))
         in
         (match result with Ok r | Error r -> r))

(* ── Signal handling ───────────────────────────────────────────────────── *)

let install_signal_handler ~sw resolver =
  let r, w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock w;
  let handle _ =
    (try ignore (Unix.single_write w (Bytes.make 1 '\x00') 0 1) with _ -> ())
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle handle);
  Sys.set_signal Sys.sigint  (Sys.Signal_handle handle);
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Unix.close r; (try Unix.close w with _ -> ()))
      (fun () ->
        Eio_unix.await_readable r;
        let buf = Bytes.create 1 in
        (try ignore (Unix.read r buf 0 1) with _ -> ());
        (try Eio.Promise.resolve resolver () with _ -> ())))

(* ── Make functor ──────────────────────────────────────────────────────── *)

exception Drain_timeout

module Make (H : HANDLER) = struct

  let run ~(env : < net: _ Eio.Net.t; clock: _ Eio.Time.clock; .. >)
      ?(port=8080) ?metrics_renderer ?(metrics_auth=`Public) ?ot
      ?(max_body_bytes=10_485_760) ?(drain_timeout_s=30.0) ?on_listen () =
    let port =
      match Sys.getenv_opt "PORT" with
      | Some s -> (try int_of_string (String.trim s) with _ -> port)
      | None   -> port
    in
    (* Register per-request metrics once at startup, reuse emitters per request *)
    let metrics_fns = match ot with
      | None -> None
      | Some o ->
        let req_count, req_duration =
          Obs.register_counter_and_histogram o
            ~counter_name:"sun_svc_requests_total"
            ~counter_help:"Total HTTP requests by method, route, and HTTP status class"
            ~counter_labels:["method"; "route"; "status_class"]
            ~histogram_name:"sun_svc_request_duration_seconds"
            ~histogram_help:"HTTP request latency in seconds by method and route"
            ~histogram_labels:["method"; "route"]
        in
        Some (req_count, req_duration)
    in
    let stop, stop_r = Eio.Promise.create () in
    (try Eio.Switch.run (fun sw ->
      install_signal_handler ~sw stop_r;
      let socket =
        Eio.Net.listen ~sw ~reuse_addr:true ~backlog:128
          env#net (`Tcp (Eio.Net.Ipaddr.V4.any, port))
      in
      let actual_port =
        match Eio.Net.listening_addr socket with
        | `Tcp (_, p) -> p
        | _           -> port
      in
      (match on_listen with Some f -> f actual_port | None -> ());
      Printf.eprintf "sun-svc listening on :%d\n%!" actual_port;
      let callback _conn req body =
        let t0 = match metrics_fns with Some _ -> Some (Eio.Time.now env#clock) | None -> None in
        let route_ref = ref "unmatched" in
        let route_observer = match metrics_fns with
          | None -> None
          | Some _ -> Some (fun lbl -> route_ref := lbl)
        in
        let sun_resp =
          dispatch ~routes:H.routes ~metrics_renderer ~metrics_auth
            ~max_body_bytes ?route_observer req body
        in
        (match metrics_fns, t0 with
         | Some (req_count, req_duration), Some t0 ->
           let dt = Eio.Time.now env#clock -. t0 in
           let meth_str = match Http.Request.meth req with
             | `GET -> "GET" | `POST -> "POST" | `PUT -> "PUT"
             | `PATCH -> "PATCH" | `DELETE -> "DELETE" | _ -> "OTHER" in
           let route = !route_ref in
           let sc = string_of_int (sun_resp.Response.status / 100) ^ "xx" in
           req_count ~labels:[("method", meth_str); ("route", route); ("status_class", sc)] 1;
           req_duration ~labels:[("method", meth_str); ("route", route)] dt
         | _ -> ());
        let body_str = sun_resp.Response.body in
        let headers =
          Http.Header.of_list
            (("content-length", string_of_int (String.length body_str))
             :: sun_resp.Response.headers)
        in
        Cohttp_eio.Server.respond
          ~status:(http_status_of_int sun_resp.Response.status)
          ~headers
          ~body:(Cohttp_eio.Body.of_string body_str)
          ()
      in
      let server = Cohttp_eio.Server.make ~callback () in
      (* Race: serve exits naturally when connections drain, or drain guard fires
         after drain_timeout_s and raises Drain_timeout to force cancellation. *)
      Eio.Fiber.first
        (fun () ->
          Cohttp_eio.Server.run ~stop
            ~on_error:(fun e ->
              Printf.eprintf "sun-svc: %s\n%!" (Printexc.to_string e))
            socket server)
        (fun () ->
          Eio.Promise.await stop;
          Eio.Time.sleep env#clock drain_timeout_s;
          raise Drain_timeout)
    ) with Drain_timeout ->
      Printf.eprintf "sun-svc: drain timeout reached, forcing shutdown\n%!")

end

let run routes =
  let module H = struct let routes = routes end in
  let module S = Make(H) in
  S.run
