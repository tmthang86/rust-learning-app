# The runner HTTP server. It starts one sandbox container per job, so it
# needs the Docker CLI and access to a Docker daemon (mount the socket,
# ideally of a dedicated host or VM used only for running learner code).
FROM rust:1-slim AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends docker.io ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/target/release/rust-runner /usr/local/bin/rust-runner
ENV RUNNER_ADDR=0.0.0.0:8080
EXPOSE 8080
CMD ["rust-runner"]
