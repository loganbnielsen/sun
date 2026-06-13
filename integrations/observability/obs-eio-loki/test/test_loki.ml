(** obs-eio-loki integration tests.

    Mock-server tests run without any external infrastructure and verify
    the exact HTTP payload sent to Loki.

    Live Loki tests require [LOKI_URL] to be set (e.g. http://localhost:3100)
    and are marked [Slow].  They push spans and query back to confirm ingestion. *)

(* ------------------------------------------------------------------ *)
(* Mock Loki server                                                    *)
(* ------------------------------------------------------------------ *)

let mock_port = 19301
let mock_port_error = 19302

(* Spin up a one-shot HTTP server on [mock_port].  Accepts a single POST,
   records the request body, sends 204, then the fiber exits.
   Returns the promise that resolves with the captured body. *)
let start_mock_server ~sw env =
  let (promise, resolver) = Eio.Promise.create () in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, mock_port) in
  let sock =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 env#net addr
  in
  Eio.Fiber.fork ~sw (fun () ->
    let conn, _addr = Eio.Net.accept ~sw sock in
    Fun.protect
      ~finally:(fun () -> Eio.Net.close conn)
      (fun () ->
        let buf = Eio.Buf_read.of_flow ~max_size:(256 * 1024) conn in
        ignore (Eio.Buf_read.line buf);       (* skip request line *)
        let content_length = ref 0 in
        let rec read_headers () =
          let line = Eio.Buf_read.line buf in
          if line = "" then ()
          else begin
            let lower = String.lowercase_ascii line in
            if String.length lower > 15
            && String.sub lower 0 15 = "content-length:" then
              (match int_of_string_opt
                       (String.trim
                          (String.sub line 15 (String.length line - 15))) with
               | Some n -> content_length := n
               | None   -> ());
            read_headers ()
          end
        in
        read_headers ();
        let body = Eio.Buf_read.take !content_length buf in
        Eio.Promise.resolve resolver body;
        Eio.Flow.copy_string
          "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n" conn));
  promise

(* Spin up a one-shot HTTP server on [mock_port_error].  Accepts a single
   POST, records the request body, sends [status_code] with [resp_body],
   then exits.  Returns a promise resolving with the captured request body. *)
let start_mock_error_server ~sw ~status_code ~resp_body env =
  let (promise, resolver) = Eio.Promise.create () in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, mock_port_error) in
  let sock =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 env#net addr
  in
  Eio.Fiber.fork ~sw (fun () ->
    let conn, _addr = Eio.Net.accept ~sw sock in
    Fun.protect
      ~finally:(fun () -> Eio.Net.close conn)
      (fun () ->
        let buf = Eio.Buf_read.of_flow ~max_size:(256 * 1024) conn in
        ignore (Eio.Buf_read.line buf);
        let content_length = ref 0 in
        let rec read_headers () =
          let line = Eio.Buf_read.line buf in
          if line = "" then ()
          else begin
            let lower = String.lowercase_ascii line in
            if String.length lower > 15
            && String.sub lower 0 15 = "content-length:" then
              (match int_of_string_opt
                       (String.trim
                          (String.sub line 15 (String.length line - 15))) with
               | Some n -> content_length := n
               | None   -> ());
            read_headers ()
          end
        in
        read_headers ();
        let body = Eio.Buf_read.take !content_length buf in
        Eio.Promise.resolve resolver body;
        let resp_len = String.length resp_body in
        Eio.Flow.copy_string
          (Printf.sprintf
             "HTTP/1.1 %d Error\r\nContent-Length: %d\r\n\r\n%s"
             status_code resp_len resp_body)
          conn));
  promise

(* ------------------------------------------------------------------ *)
(* Mock server tests                                                   *)
(* ------------------------------------------------------------------ *)

let test_push_contains_service () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let body_promise = start_mock_server ~sw env in
  let loki = Obs_loki.create ~net:env#net ~clock:env#clock
               ~url:(Printf.sprintf "http://localhost:%d" mock_port) () in
  let ot = Obs.create ~service:"test-svc" ~mono_clock:env#mono_clock
             ~backend:loki in
  Obs.with_span ot "op" (fun sp ->
    Obs.log sp Obs.Info "hello from test");
  let body = Eio.Promise.await body_promise in
  Alcotest.(check bool) "contains streams key"
    true (String.length body > 0 && String.sub body 0 1 = "{");
  Alcotest.(check bool) "service label present"
    true (let pat = "\"service\":\"test-svc\"" in
          let n = String.length body - String.length pat in
          let rec find i = if i > n then false
            else if String.sub body i (String.length pat) = pat then true
            else find (i+1)
          in find 0)

let contains s sub =
  let ls = String.length s and lp = String.length sub in
  if lp = 0 then true
  else if ls < lp then false
  else begin
    let rec go i =
      if i > ls - lp then false
      else if String.sub s i lp = sub then true
      else go (i + 1)
    in
    go 0
  end

let test_log_message_in_payload () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let body_promise = start_mock_server ~sw env in
  let loki = Obs_loki.create ~net:env#net ~clock:env#clock
               ~url:(Printf.sprintf "http://localhost:%d" mock_port) () in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
  Obs.with_span ot "work" (fun sp ->
    Obs.log sp Obs.Info ~fields:[("key", "val")] "my-unique-message");
  let body = Eio.Promise.await body_promise in
  Alcotest.(check bool) "log message present" true
    (contains body "my-unique-message");
  Alcotest.(check bool) "extra field present" true
    (contains body "val");
  Alcotest.(check bool) "trace_id present" true
    (contains body "trace_id");
  Alcotest.(check bool) "span_id present" true
    (contains body "span_id")

let test_span_name_in_payload () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let body_promise = start_mock_server ~sw env in
  let loki = Obs_loki.create ~net:env#net ~clock:env#clock
               ~url:(Printf.sprintf "http://localhost:%d" mock_port) () in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
  Obs.with_span ot "my-span-name" (fun _sp -> ());
  let body = Eio.Promise.await body_promise in
  Alcotest.(check bool) "span name in payload" true
    (contains body "my-span-name")

let test_context_fields_become_labels () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let body_promise = start_mock_server ~sw env in
  let loki = Obs_loki.create ~net:env#net ~clock:env#clock
               ~url:(Printf.sprintf "http://localhost:%d" mock_port)
               ~label_names:["env"; "region"] () in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
  let ot = Obs.with_context ot [("env", "prod"); ("region", "eu-west-1")] in
  Obs.with_span ot "op" (fun _sp -> ());
  let body = Eio.Promise.await body_promise in
  Alcotest.(check bool) "env label present" true
    (contains body "\"env\":\"prod\"");
  Alcotest.(check bool) "region label present" true
    (contains body "\"region\":\"eu-west-1\"")

let test_multiple_log_calls () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let body_promise = start_mock_server ~sw env in
  let loki = Obs_loki.create ~net:env#net ~clock:env#clock
               ~url:(Printf.sprintf "http://localhost:%d" mock_port) () in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
  Obs.with_span ot "multi" (fun sp ->
    Obs.log sp Obs.Info  "first";
    Obs.log sp Obs.Warn  "second";
    Obs.log sp Obs.Error "third");
  let body = Eio.Promise.await body_promise in
  Alcotest.(check bool) "first present"  true (contains body "first");
  Alcotest.(check bool) "second present" true (contains body "second");
  Alcotest.(check bool) "third present"  true (contains body "third")

let test_loki_unreachable_does_not_raise () =
  Eio_main.run @@ fun env ->
  (* Point at a port nothing is listening on — should log to stderr and return. *)
  let loki = Obs_loki.create ~net:env#net ~clock:env#clock
               ~url:"http://localhost:19399" () in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
  Obs.with_span ot "op" (fun sp -> Obs.log sp Obs.Info "test")
  (* If this returns without raising, the test passes. *)

(* Verify the JSON payload has the correct Loki push shape:
   {"streams":[{"stream":{...},"values":[[ts,line],...]}]} *)
let test_payload_json_shape () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let body_promise = start_mock_server ~sw env in
  let loki = Obs_loki.create ~net:env#net ~clock:env#clock
               ~url:(Printf.sprintf "http://localhost:%d" mock_port) () in
  let ot = Obs.create ~service:"shape-svc" ~mono_clock:env#mono_clock ~backend:loki in
  Obs.with_span ot "check" (fun sp -> Obs.log sp Obs.Info "shape-test");
  let body = Eio.Promise.await body_promise in
  let json = Yojson.Safe.from_string body in
  (match json with
   | `Assoc fields ->
     (match List.assoc_opt "streams" fields with
      | Some (`List (stream :: _)) ->
        (match stream with
         | `Assoc s ->
           Alcotest.(check bool) "stream key present" true
             (List.mem_assoc "stream" s);
           Alcotest.(check bool) "values key present" true
             (List.mem_assoc "values" s);
           (match List.assoc_opt "values" s with
            | Some (`List (v :: _)) ->
              (match v with
               | `List [ `String _ts; `String _line ] ->
                 Alcotest.(check bool) "value is [ts, line] tuple" true true
               | _ ->
                 Alcotest.(check bool) "value is [ts, line] tuple" true false)
            | _ -> Alcotest.(check bool) "values is non-empty list" true false)
         | _ -> Alcotest.(check bool) "stream is object" true false)
      | _ -> Alcotest.(check bool) "streams is non-empty list" true false)
   | _ -> Alcotest.(check bool) "top-level is object" true false)

(* Verify that a non-2xx response is swallowed (logged to stderr, not raised). *)
let test_non_2xx_does_not_raise () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let _body_promise =
    start_mock_error_server ~sw ~status_code:500 ~resp_body:"internal error" env
  in
  let loki = Obs_loki.create ~net:env#net ~clock:env#clock
               ~url:(Printf.sprintf "http://localhost:%d" mock_port_error) () in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
  Obs.with_span ot "op" (fun sp -> Obs.log sp Obs.Info "test")
  (* Must return without raising even though server returned 500. *)

(* Verify that a non-2xx response with a short body is captured without error. *)
let test_non_2xx_short_body () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let _body_promise =
    start_mock_error_server ~sw ~status_code:400 ~resp_body:"bad request" env
  in
  let loki = Obs_loki.create ~net:env#net ~clock:env#clock
               ~url:(Printf.sprintf "http://localhost:%d" mock_port_error) () in
  let ot = Obs.create ~service:"svc" ~mono_clock:env#mono_clock ~backend:loki in
  Obs.with_span ot "op" (fun sp -> Obs.log sp Obs.Warn "test")
  (* Must return without raising even with short error body. *)

(* ------------------------------------------------------------------ *)
(* Live Loki tests (require LOKI_URL env var)                         *)
(* ------------------------------------------------------------------ *)

(* Simple GET helper for Loki query — test-only, no timeout *)
let loki_query_range ~net ~url ~query ~start_ns ~end_ns =
  let (host, port) =
    let s = if String.length url >= 7 && String.sub url 0 7 = "http://"
            then String.sub url 7 (String.length url - 7) else url in
    let hostport = match String.index_opt s '/' with
      | None -> s | Some i -> String.sub s 0 i in
    match String.rindex_opt hostport ':' with
    | None -> (hostport, 3100)
    | Some i ->
      let h = String.sub hostport 0 i in
      let p = String.sub hostport (i+1) (String.length hostport - i - 1) in
      (match int_of_string_opt p with Some n -> (h, n) | None -> (hostport, 3100))
  in
  let pct_encode s =
    let buf = Buffer.create (String.length s * 2) in
    String.iter (fun c ->
      match c with
      | 'A'..'Z' | 'a'..'z' | '0'..'9'
      | '-' | '_' | '.' | '~' -> Buffer.add_char buf c
      | c -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c))
    ) s;
    Buffer.contents buf
  in
  let path =
    Printf.sprintf
      "/loki/api/v1/query_range?query=%s&start=%s&end=%s&limit=50"
      (pct_encode query)
      (Printf.sprintf "%Ld" start_ns)
      (Printf.sprintf "%Ld" end_ns)
  in
  let req = String.concat "\r\n" [
    Printf.sprintf "GET %s HTTP/1.1" path;
    Printf.sprintf "Host: %s:%d" host port;
    "Accept: application/json";
    "Connection: close";
    ""; "";
  ] in
  Eio.Net.with_tcp_connect net ~host ~service:(string_of_int port) (fun flow ->
    Eio.Flow.copy_string req flow;
    let buf = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
    ignore (Eio.Buf_read.line buf);
    let content_length = ref None in
    let is_chunked = ref false in
    let rec read_headers () =
      let line = Eio.Buf_read.line buf in
      if line = "" then ()
      else begin
        let lower = String.lowercase_ascii line in
        if String.length lower > 15 && String.sub lower 0 15 = "content-length:" then
          content_length :=
            int_of_string_opt (String.trim (String.sub line 15 (String.length line - 15)));
        if String.length lower > 18 && String.sub lower 0 18 = "transfer-encoding:" then
          if String.trim (String.sub lower 18 (String.length lower - 18)) = "chunked" then
            is_chunked := true;
        read_headers ()
      end
    in
    read_headers ();
    if !is_chunked then begin
      let buf' = Buffer.create 4096 in
      let rec chunks () =
        let size_line = String.trim (Eio.Buf_read.line buf) in
        let n = try int_of_string ("0x" ^ size_line) with _ -> 0 in
        if n = 0 then ()
        else begin
          Buffer.add_string buf' (Eio.Buf_read.take n buf);
          ignore (Eio.Buf_read.line buf);
          chunks ()
        end
      in
      chunks ();
      Buffer.contents buf'
    end else
      match !content_length with
      | Some n -> Eio.Buf_read.take n buf
      | None   -> Eio.Buf_read.take_all buf)

(* Extract log line values from a Loki query response using yojson. *)
let extract_log_lines json_str =
  match Yojson.Safe.from_string json_str with
  | `Assoc fields ->
    (match List.assoc_opt "data" fields with
     | Some (`Assoc data) ->
       (match List.assoc_opt "result" data with
        | Some (`List streams) ->
          List.concat_map (fun stream ->
            match stream with
            | `Assoc s ->
              (match List.assoc_opt "values" s with
               | Some (`List vals) ->
                 List.filter_map (function
                   | `List [`String _ts; `String line] -> Some line
                   | _ -> None) vals
               | _ -> [])
            | _ -> []
          ) streams
        | _ -> [])
     | _ -> [])
  | _ -> []

let test_live_ingestion () =
  match Sys.getenv_opt "LOKI_URL" with
  | None ->
    Printf.printf "[skip] LOKI_URL not set — skipping live Loki ingestion test\n%!"
  | Some loki_url ->
    Eio_main.run @@ fun env ->
    let unique_service = Printf.sprintf "loki-e2e-test-%d" (int_of_float (Unix.gettimeofday ())) in
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:loki_url () in
    let ot = Obs.create ~service:unique_service
               ~mono_clock:env#mono_clock ~backend:loki in
    let start_ns = Int64.of_float (Unix.gettimeofday () *. 1e9) in
    Obs.with_span ot "e2e-span" (fun sp ->
      Obs.log sp Obs.Info ~fields:[("check", "ingestion")] "loki-e2e-marker");
    Eio.Time.sleep env#clock 0.5;
    let end_ns = Int64.of_float (Unix.gettimeofday () *. 1e9) in
    let query = Printf.sprintf "{service=\"%s\"}" unique_service in
    let resp = loki_query_range ~net:env#net ~url:loki_url
                 ~query ~start_ns ~end_ns in
    let lines = extract_log_lines resp in
    Alcotest.(check bool) "at least one line ingested" true (lines <> []);
    Alcotest.(check bool) "marker present in ingested lines" true
      (List.exists (fun l -> contains l "loki-e2e-marker") lines)

let test_live_trace_id_round_trip () =
  match Sys.getenv_opt "LOKI_URL" with
  | None ->
    Printf.printf "[skip] LOKI_URL not set — skipping live trace-id round-trip test\n%!"
  | Some loki_url ->
    Eio_main.run @@ fun env ->
    let unique_service = Printf.sprintf "loki-trace-test-%d" (int_of_float (Unix.gettimeofday ())) in
    let loki = Obs_loki.create ~net:env#net ~clock:env#clock
                 ~url:loki_url () in
    let ot = Obs.create ~service:unique_service
               ~mono_clock:env#mono_clock ~backend:loki in
    let captured_trace_id = ref "" in
    let start_ns = Int64.of_float (Unix.gettimeofday () *. 1e9) in
    Obs.with_span ot "trace-test" (fun sp ->
      let ctx = Obs.current_trace_ctx sp in
      let (hi, lo) = ctx.Obs_trace.trace_id in
      captured_trace_id := Printf.sprintf "%016Lx%016Lx" hi lo;
      Obs.log sp Obs.Info "trace-id-check");
    Eio.Time.sleep env#clock 0.5;
    let end_ns = Int64.of_float (Unix.gettimeofday () *. 1e9) in
    (* Filter by trace_id in structured metadata — proves Loki indexed it. *)
    let query = Printf.sprintf
      "{service=\"%s\"} | trace_id=\"%s\""
      unique_service !captured_trace_id in
    let resp = loki_query_range ~net:env#net ~url:loki_url
                 ~query ~start_ns ~end_ns in
    let lines = extract_log_lines resp in
    Alcotest.(check bool) "trace_id indexed as structured metadata" true
      (lines <> [])

(* ------------------------------------------------------------------ *)
(* Test runner                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run "obs_loki" [
    "payload", [
      test_case "service label in push body"       `Quick test_push_contains_service;
      test_case "log message in push body"         `Quick test_log_message_in_payload;
      test_case "span name in push body"           `Quick test_span_name_in_payload;
      test_case "context fields become labels"     `Quick test_context_fields_become_labels;
      test_case "multiple log calls all present"   `Quick test_multiple_log_calls;
      test_case "unreachable Loki does not raise"  `Quick test_loki_unreachable_does_not_raise;
      test_case "payload JSON shape"               `Quick test_payload_json_shape;
      test_case "non-2xx response does not raise"  `Quick test_non_2xx_does_not_raise;
      test_case "non-2xx short body does not raise"`Quick test_non_2xx_short_body;
    ];
    "live", [
      test_case "log line ingested and queryable"  `Slow test_live_ingestion;
      test_case "trace_id survives push and query" `Slow test_live_trace_id_round_trip;
    ];
  ]
