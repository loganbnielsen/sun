FROM ocaml/opam:ubuntu-24.04-ocaml-5.4.1 AS build
RUN sudo apt-get update && sudo apt-get install -y librdkafka-dev libpq-dev libssl-dev
COPY . /workspace
WORKDIR /workspace
RUN opam exec -- dune build examples/pluto/app/payments/charge_svc/bin/main.exe

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y librdkafka1 libpq5 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/_build/default/examples/pluto/app/payments/charge_svc/bin/main.exe /usr/local/bin/pluto-charge-svc
USER 65534
CMD ["/usr/local/bin/pluto-charge-svc"]
