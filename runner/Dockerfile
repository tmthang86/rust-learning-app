# The runner HTTP server. It starts one sandbox container per job, so it
# needs the Docker CLI and access to a Docker daemon. Mount the socket of a
# dedicated host or VM used only for running learner code, with gVisor
# (runsc) installed and RUNNER_DOCKER_RUNTIME=runsc. See README.md.
FROM rust:1-slim AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release

# Only the Docker CLI is needed, not the daemon.
FROM docker:28-cli AS docker-cli

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=build /app/target/release/rust-runner /usr/local/bin/rust-runner
ENV RUNNER_ADDR=0.0.0.0:8080 RUNNER_DOCKER_RUNTIME=runsc
EXPOSE 8080
CMD ["rust-runner"]
