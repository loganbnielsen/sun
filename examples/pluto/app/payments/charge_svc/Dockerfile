# sun up compiles locally with dune, then runs:
#   docker build -t <image> -f examples/pluto/app/payments/charge_svc/Dockerfile <repo_root>
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y librdkafka1 libpq5 ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY _build/default/examples/pluto/app/payments/charge_svc/bin/main.exe /usr/local/bin/pluto-charge-svc
CMD ["/usr/local/bin/pluto-charge-svc"]
