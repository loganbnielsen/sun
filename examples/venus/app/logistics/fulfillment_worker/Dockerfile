# sun up compiles locally with dune, then runs:
#   docker build -t <image> -f examples/venus/app/logistics/fulfillment_worker/Dockerfile <repo_root>
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y librdkafka1 libpq5 ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY _build/default/examples/venus/app/logistics/fulfillment_worker/bin/main.exe /usr/local/bin/venus-fulfillment-worker
CMD ["/usr/local/bin/venus-fulfillment-worker"]
