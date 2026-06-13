(* Shared TLS/HTTPS client helpers for Sun HTTP backends.
   Used by obs-eio-loki and kafka-eio-service to avoid duplicating the
   CA-bundle search logic and cohttp-eio TLS wiring. *)

(* Cached TLS authenticator — reads the system CA bundle once.
   Returns Ok authenticator or Error message if no bundle is found.
   Fails closed: HTTPS connections are never made without certificate
   verification. *)
let tls_authenticator = lazy (
  let time () = Ptime.of_float_s (Unix.gettimeofday ()) in
  let ca_paths =
    [ "/etc/ssl/certs/ca-certificates.crt"   (* Debian/Ubuntu/WSL *)
    ; "/etc/pki/tls/certs/ca-bundle.crt"     (* RHEL/CentOS/Fedora *)
    ; "/etc/ssl/ca-bundle.pem"               (* OpenSUSE *)
    ; "/etc/ssl/cert.pem"                    (* macOS/Alpine *)
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
      "no system CA bundle found for HTTPS endpoint; \
       refusing to connect without certificate verification"
)

(* Build the https wrapper for Cohttp_eio.Client.make.
   Raises Failure if no CA bundle is found. *)
let make_https_wrapper () =
  let authenticator =
    match Lazy.force tls_authenticator with
    | Ok a -> a
    | Error msg -> failwith msg
  in
  let tls_config =
    match Tls.Config.client ~authenticator () with
    | Ok c -> c
    | Error (`Msg m) -> failwith ("TLS config error: " ^ m)
  in
  fun uri raw ->
    let host =
      Uri.host uri
      |> Option.map (fun h -> Domain_name.(host_exn (of_string_exn h)))
    in
    Tls_eio.client_of_flow ?host tls_config raw

(* Callers should define their own lazy wrapper:
     let https_wrapper = lazy (Eio_http.make_https_wrapper ())
   This keeps the type variable local to the calling module where it is unified
   with the concrete Eio socket type at the Cohttp_eio.Client.make call site. *)
