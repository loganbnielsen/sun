(* Shared system-CA TLS wrapper for Cohttp-eio clients that need HTTPS.
   Reads the CA bundle once (lazy) and provides a certified HTTPS connector. *)

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
      "obs_tls: no system CA bundle found; \
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
    | Error (`Msg m) -> failwith ("obs_tls: TLS config error: " ^ m)
  in
  fun uri raw ->
    let host =
      Uri.host uri
      |> Option.map (fun h -> Domain_name.(host_exn (of_string_exn h)))
    in
    Tls_eio.client_of_flow ?host tls_config raw

let https_wrapper uri raw = make_https_wrapper () uri raw
