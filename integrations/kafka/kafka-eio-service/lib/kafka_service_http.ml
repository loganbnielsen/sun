
let http_do_once net ~sw ~meth ~base_url ~path ~content_type_opt ~body_opt =
  let uri = Uri.of_string (base_url ^ path) in
  let https = Some Obs_tls.https_wrapper in
  let client = Cohttp_eio.Client.make ~https net in
  let headers =
    let base = Http.Header.of_list
      [ ("Accept",     "application/json")
      ; ("Connection", "close")
      ] in
    match content_type_opt with
    | None    -> base
    | Some ct -> Http.Header.add base "Content-Type" ct
  in
  let body = match body_opt with
    | None   -> None
    | Some s -> Some (Cohttp_eio.Body.of_string s)
  in
  let resp, resp_body =
    Cohttp_eio.Client.call client ~sw ~headers ?body meth uri
  in
  let status = Http.Status.to_int (Http.Response.status resp) in
  let body_str =
    Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:(4 * 1024 * 1024)
  in
  (status, body_str)

let http_do net ~clock ~meth ~base_url ~path ~content_type_opt ~body_opt =
  try
    Eio.Time.with_timeout_exn clock 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        Ok (http_do_once net ~sw ~meth ~base_url ~path ~content_type_opt ~body_opt)))
  with
  | Eio.Time.Timeout -> Error "HTTP request timed out after 10s"
  | exn -> Error (Printexc.to_string exn)

let http_post net ~clock ~base_url ~path ~content_type ~body =
  http_do net ~clock ~meth:`POST ~base_url ~path
    ~content_type_opt:(Some content_type) ~body_opt:(Some body)

let http_put net ~clock ~base_url ~path ~content_type ~body =
  http_do net ~clock ~meth:`PUT ~base_url ~path
    ~content_type_opt:(Some content_type) ~body_opt:(Some body)

let http_get net ~clock ~base_url ~path =
  http_do net ~clock ~meth:`GET ~base_url ~path
    ~content_type_opt:None ~body_opt:None
