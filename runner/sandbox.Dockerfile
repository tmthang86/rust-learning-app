# Image each job runs in. It only needs the Rust toolchain and bash; the
# server starts it with no network, a read-only root and an unprivileged
# user. Pinned by digest (rust:1.99.1-slim-bookworm, served by Google's
# Docker Hub mirror to avoid Docker Hub's anonymous pull limits), so every
# job uses a known toolchain. Kept as a Dockerfile for adding crates later.
FROM mirror.gcr.io/library/rust@sha256:a24e292b4af7bdee351a31d3a6379972a5652f0ea22a1b6d6883324ac4f5097c
WORKDIR /tmp
