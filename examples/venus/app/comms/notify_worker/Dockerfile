# sun up compiles locally with dune, then runs:
#   docker build -t <image> -f examples/venus/app/comms/notify_worker/Dockerfile <repo_root>
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y librdkafka1 libpq5 ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY _build/default/examples/venus/app/comms/notify_worker/bin/main.exe /usr/local/bin/venus-notify-worker
CMD ["/usr/local/bin/venus-notify-worker"]
