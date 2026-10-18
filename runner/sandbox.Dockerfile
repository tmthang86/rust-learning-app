# Image each job runs in. It only needs the Rust toolchain and bash;
# the server starts it with no network, a read-only root and an
# unprivileged user. When deploying, pin the base image by digest
# (rust:1-slim@sha256:...) so every job uses a known toolchain.
FROM rust:1-slim
RUN rustup component remove rust-docs 2>/dev/null || true
WORKDIR /tmp
