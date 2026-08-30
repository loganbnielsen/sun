(lang dune 3.0)
(generate_opam_files true)

(package
 (name sun)
 (allow_empty)
 (synopsis "Sun — open-source OCaml software factory for backend systems")
 (depends
  (ocaml (>= 5.4.0))
  (dune  (>= 3.0))
  eio
  eio_main
  cohttp-eio
  yojson
  cmdliner
  base64
  uri
  cstruct
  kafka-eio
  obs-eio
  obs-loki-eio
  obs-prometheus-eio
  https-eio
  mtime
  caqti-eio
  caqti-driver-postgresql
  pg-eio
  digestif
  aws-eio
  s3-eio
  dynamodb-eio
  lambda-eio
  otoml
  jose
  ptime
  (alcotest :with-test)
  (mirage-crypto-pk :with-test)
  (mirage-crypto-rng :with-test)))
