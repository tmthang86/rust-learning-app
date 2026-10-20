# Shared settings for the runner deployment. Sourced by the other scripts
# (on the laptop and on the VM), never run on its own.
# shellcheck shell=bash disable=SC2034

# ---- Where the VM lives (laptop side) -------------------------------------
# Set PROJECT in your shell, or leave it empty and push.sh uses
# `gcloud config get-value project`.
PROJECT="${PROJECT:-}"
REGION="${REGION:-asia-southeast1}"
ZONE="${ZONE:-asia-southeast1-b}"
VM="${VM:-rust-runner}"
MACHINE_TYPE=e2-medium
BOOT_DISK_SIZE=20GB
IMAGE_FAMILY=ubuntu-2404-lts-amd64
IMAGE_PROJECT=ubuntu-os-cloud
NETWORK_TAG=rust-runner

# ---- Pinned packages (VM side) --------------------------------------------
# Upgrade once a month: see "Monthly upgrade" in README.md.
#
# gVisor: the .deb from the release pool. The apt index only ever lists the
# newest release, so a pinned version must come from the pool. The sha256 is
# the one in
# https://storage.googleapis.com/gvisor/releases/dists/release/main/binary-amd64/Packages
RUNSC_VERSION=20261012.0
RUNSC_DEB_URL="https://storage.googleapis.com/gvisor/releases/pool/${RUNSC_VERSION}/binary-amd64/runsc.deb"
RUNSC_DEB_SHA256=7a440a035128a52f489b0bb76f60ac4df9cabe7cdf31dd5fd79a3e80f8a707ca

# Docker CE from download.docker.com (Ubuntu noble). DOCKER_SEMVER is what
# `docker version` prints for the same release.
DOCKER_VERSION='5:29.9.1-1~ubuntu.24.04~noble'
DOCKER_SEMVER=29.9.1
CONTAINERD_VERSION='2.4.2-2~ubuntu.24.04~noble'

# runc ships inside containerd.io. Jobs don't use it, but old versions have
# known container-escape bugs, so smoke.sh refuses anything older.
MIN_RUNC_VERSION=1.2.8

# Newest glibc symbol version the binaries may need (Ubuntu 24.04 has 2.39).
MAX_GLIBC_VERSION=2.39

# ---- Paths on the VM -------------------------------------------------------
BASE_DIR=/opt/rust-runner
RELEASES_DIR="$BASE_DIR/releases"
CURRENT_LINK="$BASE_DIR/current"
PREVIOUS_LINK="$BASE_DIR/previous"
TOOLS_DIR="$BASE_DIR/deploy"          # copy of this directory, kept up to date
PACKAGES_PREV="$BASE_DIR/packages.prev"
CACHE_DIR=/var/cache/rust-runner      # pinned .deb files, for package rollback
KEEP_RELEASES=3
