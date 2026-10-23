# Image each job runs in. It only needs the Rust toolchain and bash; the
# server starts it with no network, a read-only root and an unprivileged
# user. Pinned by digest (rust:1.99.1-slim-bookworm, served by Google's
# Docker Hub mirror to avoid Docker Hub's anonymous pull limits), so every
# job uses a known toolchain. Kept as a Dockerfile for adding crates later.
#
# Bump the version in three places together: here, in Dockerfile (the
# RUST_IMAGE digest), and the `lessons` job's `toolchain:` in
# .github/workflows/ci.yml. tool/check_lessons.py grades lessons with that
# toolchain and `rr-grade`, so a lesson is judged as the sandbox will judge it.
FROM mirror.gcr.io/library/rust@sha256:a24e292b4af7bdee351a31d3a6379972a5652f0ea22a1b6d6883324ac4f5097c
WORKDIR /tmp
