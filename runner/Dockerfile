# Development image for the runner. Production does not use it: the runner
# runs as a systemd service on the VM, built by deploy/Dockerfile.build
# (cross-build to glibc 2.36, no QEMU; see deploy/README.md).
#
#   docker build -t rust-runner .
#
# The image needs the host's Docker socket and a daemon with gVisor (runsc)
# if you want production-like isolation.

# rust:1.99.1-slim-bookworm, pinned by index digest (multi-arch). Same digest
# as the sandbox image's base (sandbox.Dockerfile).
ARG RUST_IMAGE=mirror.gcr.io/library/rust:1.99.1-slim-bookworm@sha256:a24e292b4af7bdee351a31d3a6379972a5652f0ea22a1b6d6883324ac4f5097c

# Native build for the development image below.
FROM ${RUST_IMAGE} AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked

# Only the Docker CLI is needed, not the daemon.
FROM mirror.gcr.io/library/docker:29-cli AS docker-cli

FROM mirror.gcr.io/library/debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=build /app/target/release/rust-runner /usr/local/bin/rust-runner
# Development mode: App Check off. Also pass RUNNER_DOCKER_RUNTIME=runsc, or
# RUNNER_ALLOW_RUNC=1 to use Docker's default runtime, and the Docker socket.
ENV RUNNER_ENV=development RUNNER_ADDR=0.0.0.0:8080
EXPOSE 8080
CMD ["rust-runner"]
