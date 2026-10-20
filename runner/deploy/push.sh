#!/usr/bin/env bash
# Deploys the runner from your laptop. Needs git, Docker with buildx, and
# gcloud (signed in, with IAP access to the VM). Works with the bash 3.2 that
# macOS ships.
#
#   runner/deploy/push.sh --setup             one-time VM setup (packages, Docker, Caddy)
#   runner/deploy/push.sh --acme-staging      build + deploy, with a test TLS certificate
#   runner/deploy/push.sh                     build + deploy (the normal way)
#   runner/deploy/push.sh --upgrade-packages  install the versions pinned in vars.sh
#   runner/deploy/push.sh --rollback          go back to the previous release
#
# It always builds from the last commit (`git archive HEAD`), never from your
# working copy, and refuses to run when there are uncommitted changes.
# Nothing is compiled on the VM.
set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE=deploy
STAGING=0
for arg in "$@"; do
  case $arg in
    --setup) MODE=setup ;;
    --upgrade-packages) MODE=upgrade ;;
    --rollback) MODE=rollback ;;
    --acme-staging) STAGING=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $arg (try --help)" ;;
  esac
done
if [ "$STAGING" = 1 ] && [ "$MODE" != deploy ]; then
  die "--acme-staging only goes with a normal deploy"
fi

need() { command -v "$1" > /dev/null 2>&1 || die "$1 is not installed"; }
need git
need gcloud
need tar

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=vars.sh
. runner/deploy/vars.sh
if [ -z "$PROJECT" ]; then
  PROJECT="$(gcloud config get-value project 2> /dev/null || true)"
fi
[ -n "$PROJECT" ] || die "no Google Cloud project: run 'gcloud config set project <id>' or set PROJECT"

# Remote commands run over IAP, so the VM needs no public SSH port.
remote() {
  gcloud compute ssh "$VM" --project "$PROJECT" --zone "$ZONE" \
    --tunnel-through-iap --quiet --command "$1"
}

sha256_file() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

check_clean() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "there are uncommitted changes: commit first (the build uses the last commit)"
  fi
  if [ -n "$(git ls-files --others --exclude-standard runner)" ]; then
    die "there are untracked files under runner/: commit them or remove them"
  fi
}

check_env_file() {
  if grep -n 'REPLACE' runner/deploy/production.env; then
    die "runner/deploy/production.env still has REPLACE values: fill it in and commit it"
  fi
}

ID="$(git rev-parse --short=12 HEAD)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export COPYFILE_DISABLE=1 # keep macOS tar from adding ._ files

# Copies a tar stream (stdin) to ~/incoming/<name> on the VM.
upload() {
  remote "rm -rf ~/incoming/$1 && mkdir -p ~/incoming/$1 && tar -x -C ~/incoming/$1"
}

# Keeps the three newest upload folders on the VM.
tidy_incoming() {
  remote 'ls -1dt ~/incoming/*/ 2> /dev/null | tail -n +4 | xargs -r rm -rf' || true
}

case $MODE in
  setup)
    check_clean
    check_env_file
    echo "== Uploading deploy/ ($ID) and setting up the VM"
    git archive --format=tar --prefix=deploy/ "HEAD:runner/deploy" | upload "setup-$ID"
    remote "sudo ~/incoming/setup-$ID/deploy/setup-host.sh"
    tidy_incoming
    ;;

  upgrade)
    check_clean
    echo "== Uploading deploy/ ($ID) and upgrading packages"
    git archive --format=tar --prefix=deploy/ "HEAD:runner/deploy" | upload "upgrade-$ID"
    remote "sudo ~/incoming/upgrade-$ID/deploy/install.sh --upgrade-packages"
    tidy_incoming
    ;;

  rollback)
    echo "== Rolling back"
    remote "sudo /opt/rust-runner/deploy/install.sh --rollback"
    ;;

  deploy)
    check_clean
    check_env_file
    need docker
    docker buildx version > /dev/null 2>&1 || die "docker buildx is not available"

    echo "== Building $ID from git (cross-build for x86_64 Linux, glibc 2.36)"
    mkdir -p "$TMP/stage"
    git archive --format=tar HEAD runner \
      | docker buildx build -f runner/deploy/Dockerfile.build --target export \
        -o "type=local,dest=$TMP/stage" -
    [ -f "$TMP/stage/rust-runner" ] || die "the build did not produce rust-runner"
    [ -f "$TMP/stage/rust-runner-tests" ] || die "the build did not produce rust-runner-tests"

    (cd "$TMP/stage" && sha256_file rust-runner rust-runner-tests > SHA256SUMS)
    git archive --format=tar --prefix=deploy/ "HEAD:runner/deploy" | tar -x -C "$TMP/stage"

    echo "== Uploading to the VM"
    tar -C "$TMP/stage" -c . | upload "$ID"

    echo "== Installing on the VM"
    if [ "$STAGING" = 1 ]; then
      remote "sudo ~/incoming/$ID/deploy/install.sh $ID --acme-staging"
    else
      remote "sudo ~/incoming/$ID/deploy/install.sh $ID"
    fi
    tidy_incoming
    ;;
esac

echo "Done."
