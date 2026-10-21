# Shared settings for the runner deployment. Sourced by the other scripts
# (on the laptop and on the VM), never run on its own.
# shellcheck shell=bash disable=SC2034

# ---- Which cloud ------------------------------------------------------------
# oracle: Oracle Cloud Always Free, Ampere A1 (arm64). The main path.
# gce:    Google Compute Engine e2-medium (x86_64). The fallback.
# Only the laptop side (push.sh) needs this. The VM works it out itself.
PROVIDER="${PROVIDER:-oracle}"

# ---- How push.sh reaches the VM ------------------------------------------------
# oracle: plain SSH with a key. SSH_HOST defaults to RUNNER_DOMAIN from
# production.env. SSH_KEY is optional (your normal ssh key is used if empty).
SSH_USER="${SSH_USER:-ubuntu}"
SSH_HOST="${SSH_HOST:-}"
SSH_KEY="${SSH_KEY:-}"
# gce: gcloud over IAP.
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
# Upgrade once a month: see "Monthly" in README.md.
#
# Docker CE from download.docker.com (Ubuntu noble). The same version string
# is used on amd64 and arm64. DOCKER_SEMVER is what `docker version` prints.
DOCKER_VERSION='5:29.9.1-1~ubuntu.24.04~noble'
DOCKER_SEMVER=29.9.1
CONTAINERD_VERSION='2.4.2-2~ubuntu.24.04~noble'

# gVisor: the .deb from the release pool. The apt index only ever lists the
# newest release, so a pinned version must come from the pool. The sha256s are
# the ones in
# https://storage.googleapis.com/gvisor/releases/dists/release/main/binary-<arch>/Packages
RUNSC_VERSION=20261012.0
RUNSC_DEB_SHA256_amd64=7a440a035128a52f489b0bb76f60ac4df9cabe7cdf31dd5fd79a3e80f8a707ca
RUNSC_DEB_SHA256_arm64=09b5956219f44810cc62218692e3418b83b2f9263f4c64661ac59068ec39c056

# runc ships inside containerd.io. Jobs don't use it, but old versions have
# known container-escape bugs, so smoke.sh refuses anything older.
MIN_RUNC_VERSION=1.2.8

# Newest glibc symbol version the binaries may need. Ubuntu 24.04 has 2.39 on
# both amd64 and arm64.
MAX_GLIBC_VERSION=2.39

# ---- Paths on the VM -------------------------------------------------------
BASE_DIR=/opt/rust-runner
RELEASES_DIR="$BASE_DIR/releases"
CURRENT_LINK="$BASE_DIR/current"
PREVIOUS_LINK="$BASE_DIR/previous"
TOOLS_DIR="$BASE_DIR/deploy"          # copy of this directory, kept up to date
PACKAGES_PREV="$BASE_DIR/packages.prev"
CACHE_DIR=/var/cache/rust-runner      # pinned .deb files, for package rollback
LOCK_FILE=/run/lock/rust-runner-deploy.lock
KEEP_RELEASES=3

# ---- CPU architecture -----------------------------------------------------
# provider_arch NAME: the Debian architecture of the VM the provider gives us.
provider_arch() {
  case $1 in
    oracle) echo arm64 ;;
    gce) echo amd64 ;;
    *) echo "unknown provider '$1' (use oracle or gce)" >&2; return 1 ;;
  esac
}

# use_arch amd64|arm64: sets ARCH, RUST_TARGET and the runsc download.
use_arch() {
  ARCH=$1
  case $ARCH in
    amd64)
      RUST_TARGET=x86_64-unknown-linux-gnu
      RUNSC_DEB_SHA256=$RUNSC_DEB_SHA256_amd64
      ;;
    arm64)
      RUST_TARGET=aarch64-unknown-linux-gnu
      RUNSC_DEB_SHA256=$RUNSC_DEB_SHA256_arm64
      ;;
    *)
      echo "unsupported CPU architecture '$ARCH' (use amd64 or arm64)" >&2
      return 1
      ;;
  esac
  RUNSC_DEB_URL="https://storage.googleapis.com/gvisor/releases/pool/${RUNSC_VERSION}/binary-${ARCH}/runsc.deb"
}
