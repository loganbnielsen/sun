let tls_authenticator = lazy (
  let time () = Ptime.of_float_s (Unix.gettimeofday ()) in
  let ca_paths =
    [ "/etc/ssl/certs/ca-certificates.crt"
    ; "/etc/pki/tls/certs/ca-bundle.crt"
    ; "/etc/ssl/ca-bundle.pem"
    ; "/etc/ssl/cert.pem"
    ]
  in
  let cas = List.find_map (fun path ->
    let ic = ref None in
    try
      let ch = open_in path in
      ic := Some ch;
      let n  = in_channel_length ch in
      let s  = Bytes.create n in
      really_input ch s 0 n;
      close_in ch;
      ic := None;
      match X509.Certificate.decode_pem_multiple (Bytes.to_string s) with
      | Ok certs when certs <> [] -> Some (path, certs)
      | _ -> None
    with _ ->
      Option.iter close_in_noerr !ic;
      None
  ) ca_paths in
  match cas with
  | Some (_path, certs) -> Ok (X509.Authenticator.chain_of_trust ~time certs)
  | None ->
    Error
      "kafka_service: no system CA bundle found for HTTPS schema registry; \
       refusing to connect without certificate verification"
)

let make_https_wrapper () =
  let authenticator =
    match Lazy.force tls_authenticator with
    | Ok a -> a
    | Error msg -> failwith msg
  in
  let tls_config =
    match Tls.Config.client ~authenticator () with
    | Ok c -> c
    | Error (`Msg m) -> failwith ("kafka_service: TLS config error: " ^ m)
  in
  fun uri raw ->
    let host =
      Uri.host uri
      |> Option.map (fun h -> Domain_name.(host_exn (of_string_exn h)))
    in
    Tls_eio.client_of_flow ?host tls_config raw

let https_wrapper = lazy (make_https_wrapper ())

type body_request =
  { content_type : string
  ; body : string
  }

type request =
  | Get of { base_url : string; path : string }
  | With_body of
      { meth : [ `POST | `PUT ]
      ; base_url : string
      ; path : string
      ; body_request : body_request
      }

let request_uri = function
  | Get { base_url; path }
  | With_body { base_url; path; _ } ->
    Uri.of_string (base_url ^ path)

let request_method = function
  | Get _ -> `GET
  | With_body { meth; _ } -> (meth :> Http.Method.t)

let request_headers request =
  let base = Http.Header.of_list
    [ ("Accept",     "application/json")
    ; ("Connection", "close")
    ] in
  match request with
  | Get _ -> base
  | With_body { body_request = { content_type; _ }; _ } ->
    Http.Header.add base "Content-Type" content_type

let request_body = function
  | Get _ -> None
  | With_body { body_request = { body; _ }; _ } ->
    Some (Cohttp_eio.Body.of_string body)

let http_do_once net ~sw request =
  let meth = request_method request in
  let uri = request_uri request in
  let https = Some (Lazy.force https_wrapper) in
  let client = Cohttp_eio.Client.make ~https net in
  let headers = request_headers request in
  let body = request_body request in
  let resp, resp_body =
    Cohttp_eio.Client.call client ~sw ~headers ?body meth uri
  in
  let status = Http.Status.to_int (Http.Response.status resp) in
  let body_str =
    Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:(4 * 1024 * 1024)
  in
  (status, body_str)

let http_do net ~clock request =
  try
    Eio.Time.with_timeout_exn clock 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        Ok (http_do_once net ~sw request)))
  with
  | Eio.Time.Timeout -> Error "HTTP request timed out after 10s"
  | exn -> Error (Printexc.to_string exn)

let http_post net ~clock ~base_url ~path ~content_type ~body =
  http_do net ~clock
    (With_body
       { meth = `POST
       ; base_url
       ; path
       ; body_request = { content_type; body }
       })

let http_put net ~clock ~base_url ~path ~content_type ~body =
  http_do net ~clock
    (With_body
       { meth = `PUT
       ; base_url
       ; path
       ; body_request = { content_type; body }
       })

let http_get net ~clock ~base_url ~path =
  http_do net ~clock (Get { base_url; path })
