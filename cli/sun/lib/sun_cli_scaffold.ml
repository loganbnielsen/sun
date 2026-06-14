let replace_all ~pat ~with_ s =
  let pl = String.length pat in
  let sl = String.length s in
  let buf = Buffer.create (sl + 64) in
  let i = ref 0 in
  while !i < sl do
    if !i + pl <= sl && String.sub s !i pl = pat then begin
      Buffer.add_string buf with_;
      i := !i + pl
    end else begin
      Buffer.add_char buf s.[!i];
      incr i
    end
  done;
  Buffer.contents buf

let subst vars s =
  List.fold_left (fun acc (k, v) ->
    replace_all ~pat:("{{" ^ k ^ "}}") ~with_:v acc
  ) s vars

let mkdir_p dir =
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote dir)))

let write_file ~path ~content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Printf.printf "  created  %s\n%!" path

let link_dir ~path ~target =
  mkdir_p (Filename.dirname path);
  (try Unix.symlink target path
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Printf.printf "  linked   %s -> %s\n%!" path target

let normalize s =
  String.map (function '-' -> '_' | c -> c) (String.lowercase_ascii s)

let capitalize_name s =
  let s = normalize s in
  if String.length s = 0 then s
  else begin
    let b = Bytes.of_string s in
    Bytes.set b 0 (Char.uppercase_ascii (Bytes.get b 0));
    Bytes.to_string b
  end

(* ── Shared scaffold templates ────────────────────────────────────────── *)

let tpl_sun_toml = {tpl|# Sun service configuration — all fields are optional.

[infra.scale]
# replicas = 1
# cpu      = "250m"
# memory   = "256Mi"

[infra.env]
# secrets = []
# config  = {}

[infra.rollout]
# strategy = "canary"       # or "blue-green"
# steps    = [10, 40, 100]  # canary only
|tpl}

let tpl_dockerfile = {tpl|# Stage 1: compile inside ubuntu-24.04 so the binary links against glibc 2.39.
# sun up resolves vendor/ symlinks into the build context before running docker build.
FROM ocaml/opam:ubuntu-24.04-ocaml-5.4 AS build
RUN sudo apt-get update && sudo apt-get install -y \
    librdkafka-dev libpq-dev libssl-dev libgmp-dev pkg-config && \
    sudo rm -rf /var/lib/apt/lists/*
RUN opam install -y --no-self-upgrade \
    eio eio_main cohttp-eio yojson cmdliner base64 uri cstruct mtime \
    tls-eio x509 domain-name ptime otoml \
    caqti-eio caqti-driver-postgresql
COPY --chown=opam:opam . /workspace
WORKDIR /workspace
RUN opam exec -- dune build {{repo_dir}}/bin/main.exe

# Stage 2: minimal runtime image
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y librdkafka1 libpq5 ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/_build/default/{{repo_dir}}/bin/main.exe /usr/local/bin/{{binary}}
# Run as nobody (uid 65534) — matches securityContext in generated k8s manifests
USER 65534
CMD ["/usr/local/bin/{{binary}}"]
|tpl}

(* ── Shared command helpers ───────────────────────────────────────────── *)

let ws_of_cwd () = normalize (Filename.basename (Sys.getcwd ()))

let parse_domain_name arg =
  match String.split_on_char '/' arg with
  | [domain; name] -> (normalize domain, normalize name)
  | _ ->
    Printf.eprintf "error: expected domain/name (e.g. payments/charge), got %S\n" arg;
    exit 1
