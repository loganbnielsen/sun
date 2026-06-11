open Eio.Std

let contains needle s =
  let nl = String.length needle and sl = String.length s in
  if nl > sl then false
  else begin
    let found = ref false in
    for i = 0 to sl - nl do
      if not !found then begin
        let rec eq j =
          j >= nl ||
          (String.unsafe_get s (i + j) = String.unsafe_get needle j && eq (j + 1))
        in
        if eq 0 then found := true
      end
    done;
    !found
  end

(* ── Test handler fixtures ───────────────────────────────────────────── *)

let get_json _req = Response.json {|{"ok":true}|}
let echo_body req = Response.ok req.Request.body

let jwt_cfg scopes =
  `Jwt Auth.{ scopes; allow_unverified_v1_unsafe = true }

let make_jwt ?(scopes=["read"]) () =
  let header  = Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet
                  {|{"alg":"HS256","typ":"JWT"}|} in
  let now     = Unix.gettimeofday () in
  let exp     = int_of_float (now +. 3600.0) in
  let scope   = String.concat " " scopes in
  let payload = Printf.sprintf {|{"sub":"u1","scope":"%s","exp":%d}|} scope exp in
  let b64     = Base64.encode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet payload in
  header ^ "." ^ b64 ^ ".sig"

module H = struct
  let routes = [
    Route.get  "/hello"     ~auth:`Public           get_json;
    Route.post "/echo"      ~auth:`Public           echo_body;
    Route.get  "/protected" ~auth:(jwt_cfg ["read"]) get_json;
    Route.get  "/users/:id" ~auth:`Public
      (fun req ->
        Response.json (Printf.sprintf {|{"id":"%s"}|}
          (Request.param_exn req "id")));
  ]
end

(* ── HTTP over raw TCP ───────────────────────────────────────────────── *)

(* Start the server in a background fiber; resolve the port via on_listen. *)
let with_server env ~sw f =
  let port_p, port_r = Promise.create () in
  Fiber.fork_daemon ~sw (fun () ->
    let module S = Service.Make(H) in
    S.run ~env ~port:0 ~on_listen:(fun p -> Promise.resolve port_r p) ();
    `Stop_daemon
  );
  let port = Promise.await port_p in
  f port

(* Server with obs handle wired in; callback receives port + renderer. *)
let with_server_obs env ~sw f =
  let port_p, port_r = Promise.create () in
  let backend, render = Obs_prometheus.create () in
  let ot = Obs.create ~service:"test-svc" ~mono_clock:env#mono_clock ~backend in
  Fiber.fork_daemon ~sw (fun () ->
    let module S = Service.Make(H) in
    S.run ~env ~port:0 ~ot ~metrics_renderer:render
      ~on_listen:(fun p -> Promise.resolve port_r p) ();
    `Stop_daemon
  );
  let port = Promise.await port_p in
  f port render

(* Send a minimal HTTP/1.1 request over a raw TCP socket and return
   the status line + body as raw strings. *)
let raw_request env ~sw ~port ~meth ~path ?(headers=[]) ?(body="") () =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let flow = Eio.Net.connect ~sw env#net addr in
  let content_length =
    if body = "" then "" else
    Printf.sprintf "content-length: %d\r\n" (String.length body)
  in
  let extra_headers =
    List.map (fun (k, v) -> Printf.sprintf "%s: %s\r\n" k v) headers
    |> String.concat ""
  in
  let req =
    Printf.sprintf "%s %s HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n%s%s\r\n%s"
      meth path extra_headers content_length body
  in
  Eio.Flow.copy_string req flow;
  Eio.Flow.shutdown flow `Send;
  let buf = Eio.Buf_read.of_flow flow ~max_size:65536 in
  Eio.Buf_read.take_all buf

let status_of response =
  (* Extract status code from "HTTP/1.1 200 OK\r\n..." *)
  match String.split_on_char ' ' response with
  | _ :: code :: _ -> (try int_of_string (String.trim code) with _ -> 0)
  | _              -> 0

let body_of response =
  (* Body follows the double CRLF *)
  match String.split_on_char '\n' response with
  | lines ->
    let rec find_empty = function
      | [] -> ""
      | line :: rest ->
        if String.trim line = "" then String.concat "\n" rest
        else find_empty rest
    in
    find_empty lines

(* ── Tests ───────────────────────────────────────────────────────────── *)

let test_healthz env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let resp = raw_request env ~sw ~port ~meth:"GET" ~path:"/healthz" () in
      Alcotest.(check int) "status 200" 200 (status_of resp);
      let b = body_of resp in
      Alcotest.(check bool) "body ok" true
        (let s = String.trim b in s = {|{"status":"ok"}|})))

let test_not_found env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let resp = raw_request env ~sw ~port ~meth:"GET" ~path:"/does-not-exist" () in
      Alcotest.(check int) "status 404" 404 (status_of resp)))

let test_method_not_allowed env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      (* /hello is GET only *)
      let resp = raw_request env ~sw ~port ~meth:"DELETE" ~path:"/hello" () in
      Alcotest.(check int) "status 405" 405 (status_of resp)))

let test_public_route env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let resp = raw_request env ~sw ~port ~meth:"GET" ~path:"/hello" () in
      Alcotest.(check int) "status 200" 200 (status_of resp)))

let test_path_param env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let resp = raw_request env ~sw ~port ~meth:"GET" ~path:"/users/42" () in
      Alcotest.(check int) "status 200" 200 (status_of resp);
      Alcotest.(check bool) "contains id" true
        (let b = body_of resp in
         try let _ = String.index b '4' in true
         with Not_found -> false)))

let test_echo_body env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let resp = raw_request env ~sw ~port ~meth:"POST" ~path:"/echo"
                   ~body:"hello world" () in
      Alcotest.(check int) "status 200" 200 (status_of resp);
      Alcotest.(check bool) "body echoed" true
        (let b = body_of resp in
         let b = String.trim b in
         b = "hello world")))

let test_jwt_no_token env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let resp = raw_request env ~sw ~port ~meth:"GET" ~path:"/protected" () in
      Alcotest.(check int) "status 401" 401 (status_of resp)))

let test_jwt_valid_token env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let tok  = make_jwt ~scopes:["read"] () in
      let resp = raw_request env ~sw ~port ~meth:"GET" ~path:"/protected"
                   ~headers:["authorization", "Bearer " ^ tok] () in
      Alcotest.(check int) "status 200" 200 (status_of resp)))

let test_jwt_missing_scope env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let tok  = make_jwt ~scopes:["other"] () in
      let resp = raw_request env ~sw ~port ~meth:"GET" ~path:"/protected"
                   ~headers:["authorization", "Bearer " ^ tok] () in
      Alcotest.(check int) "status 403" 403 (status_of resp)))

let test_metrics_no_renderer env () =
  Switch.run (fun sw ->
    with_server env ~sw (fun port ->
      let resp = raw_request env ~sw ~port ~meth:"GET" ~path:"/metrics" () in
      Alcotest.(check int) "status 404" 404 (status_of resp)))

let test_handler_exception env () =
  (* Handler that raises; server should return 500 and stay alive *)
  let module Hx = struct
    let routes = [
      Route.get "/boom" ~auth:`Public (fun _ -> raise (Failure "boom"));
      Route.get "/ok"   ~auth:`Public (fun _ -> Response.json {|"ok"|});
    ]
  end in
  let port_p, port_r = Promise.create () in
  Switch.run (fun sw ->
    Fiber.fork_daemon ~sw (fun () ->
      let module S = Service.Make(Hx) in
      S.run ~env ~port:0 ~on_listen:(fun p -> Promise.resolve port_r p) ();
      `Stop_daemon
    );
    let port = Promise.await port_p in
    let r1 = raw_request env ~sw ~port ~meth:"GET" ~path:"/boom" () in
    Alcotest.(check int) "500 on exception" 500 (status_of r1);
    let r2 = raw_request env ~sw ~port ~meth:"GET" ~path:"/ok" () in
    Alcotest.(check int) "server still up" 200 (status_of r2))

let test_metrics_counter env () =
  Switch.run (fun sw ->
    with_server_obs env ~sw (fun port render ->
      let _resp = raw_request env ~sw ~port ~meth:"GET" ~path:"/hello" () in
      let output = render () in
      Alcotest.(check bool) "requests_total counter present"
        true (contains "sun_svc_requests_total" output);
      Alcotest.(check bool) "route label in output"
        true (contains {|route="/hello"|} output);
      Alcotest.(check bool) "status_class label in output"
        true (contains {|status_class="2xx"|} output)))

let test_metrics_duration env () =
  Switch.run (fun sw ->
    with_server_obs env ~sw (fun port render ->
      let _resp = raw_request env ~sw ~port ~meth:"GET" ~path:"/hello" () in
      let output = render () in
      Alcotest.(check bool) "duration histogram present"
        true (contains "sun_svc_request_duration_seconds" output)))

let test_metrics_route_pattern_label env () =
  (* Route label must use the pattern ("/users/:id"), not the actual path
     value ("/users/42"), so label cardinality stays bounded. *)
  Switch.run (fun sw ->
    with_server_obs env ~sw (fun port render ->
      let _r1 = raw_request env ~sw ~port ~meth:"GET" ~path:"/users/42" () in
      let _r2 = raw_request env ~sw ~port ~meth:"GET" ~path:"/users/999" () in
      let output = render () in
      Alcotest.(check bool) "pattern label present"
        true  (contains {|route="/users/:id"|} output);
      Alcotest.(check bool) "concrete value 42 not a label"
        false (contains {|route="/users/42"|} output);
      Alcotest.(check bool) "concrete value 999 not a label"
        false (contains {|route="/users/999"|} output)))

let () =
  Eio_main.run (fun env ->
    Alcotest.run "service" [
      "built-ins", [
        Alcotest.test_case "GET /healthz → 200"     `Quick (test_healthz env);
        Alcotest.test_case "GET /metrics, no renderer → 404" `Quick (test_metrics_no_renderer env);
      ];
      "routing", [
        Alcotest.test_case "unknown path → 404"     `Quick (test_not_found env);
        Alcotest.test_case "wrong method → 405"     `Quick (test_method_not_allowed env);
        Alcotest.test_case "public route → 200"     `Quick (test_public_route env);
        Alcotest.test_case "path param extracted"   `Quick (test_path_param env);
        Alcotest.test_case "POST body echoed"       `Quick (test_echo_body env);
      ];
      "auth", [
        Alcotest.test_case "JWT route, no token → 401"    `Quick (test_jwt_no_token env);
        Alcotest.test_case "JWT route, valid token → 200" `Quick (test_jwt_valid_token env);
        Alcotest.test_case "JWT route, wrong scope → 403" `Quick (test_jwt_missing_scope env);
      ];
      "resilience", [
        Alcotest.test_case "handler exception → 500, server survives"
          `Quick (test_handler_exception env);
      ];
      "metrics", [
        Alcotest.test_case "requests counter with route label" `Quick (test_metrics_counter env);
        Alcotest.test_case "duration histogram present"        `Quick (test_metrics_duration env);
        Alcotest.test_case "route label uses pattern not path" `Quick (test_metrics_route_pattern_label env);
      ];
    ])
