(lang dune 3.0)
(generate_opam_files true)

(package
 (name sun)
 (allow_empty)
 (synopsis "Sun — opinionated OCaml 5 production platform for startups")
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
  mtime
  caqti-eio
  caqti-driver-postgresql
  otoml
  (alcotest :with-test)))
