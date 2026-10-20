#!/usr/bin/env bash
# One-time (and safe to repeat) setup of the runner VM. Run as root on the VM,
# normally through `push.sh --setup`:
#
#   sudo ~/incoming/<id>/deploy/setup-host.sh
#
# It installs the pinned Docker and gVisor packages, the Docker daemon
# settings, Caddy, the service user, journald and unattended-upgrades
# settings and the systemd unit. It does not start the runner: that happens
# in install.sh once there is a release. It ends with `smoke.sh --host-only`.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vars.sh
. "$DEPLOY_DIR/vars.sh"
# shellcheck source=lib.sh
. "$DEPLOY_DIR/lib.sh"

require_root

[[ "$(uname -m)" == x86_64 ]] || die "this setup is for x86_64 machines"
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_CODENAME:-} == noble ]] \
  || die "this setup is for Ubuntu 24.04 (noble), found ${PRETTY_NAME:-unknown}"

log "== 1/9 Base packages"
apt_get update
apt_get install --no-install-recommends \
  ca-certificates curl gnupg binutils jq unattended-upgrades

log "== 2/9 Docker $DOCKER_SEMVER (pinned, held)"
docker_repo_setup
install_docker_packages

log "== 3/9 Docker daemon settings"
write_daemon_json

log "== 4/9 gVisor runsc $RUNSC_VERSION (pinned, held)"
# The .deb's postinst runs `runsc install --clobber=false` because
# daemon.json exists now. That keeps our entry. deploy/daemon.json is written
# in the exact format runsc writes, so the file stays byte-identical.
install_runsc
assert_daemon_json
systemctl enable docker
systemctl restart docker

log "== 5/9 Caddy"
caddy_repo_setup
apt_get update
apt_get install --no-install-recommends caddy
# Until the first deploy there is nothing to serve. The stock Caddyfile would
# publish a welcome page, so replace it with an empty one.
if ! grep -q 'Managed by rust-runner' /etc/caddy/Caddyfile 2> /dev/null; then
  printf '# Replaced by rust-runner install.sh on the first deploy.\n' > /etc/caddy/Caddyfile
fi
systemctl enable --now caddy
systemctl reload caddy

log "== 6/9 Service user and directories"
if ! id rust-runner > /dev/null 2>&1; then
  useradd --system --user-group --no-create-home \
    --home-dir /nonexistent --shell /usr/sbin/nologin rust-runner
fi
install -d -m 0755 "$BASE_DIR" "$RELEASES_DIR" "$CACHE_DIR"
sync_tools_dir

log "== 7/9 Journal and automatic security updates"
install -d -m 0755 /etc/systemd/journald.conf.d
install -m 0644 "$DEPLOY_DIR/journald-runner.conf" /etc/systemd/journald.conf.d/runner.conf
systemctl restart systemd-journald
install -m 0644 "$DEPLOY_DIR/52unattended-upgrades-runner" \
  /etc/apt/apt.conf.d/52unattended-upgrades-runner

log "== 8/9 systemd unit"
install -m 0644 "$DEPLOY_DIR/rust-runner.service" /etc/systemd/system/rust-runner.service
systemctl daemon-reload
systemctl enable rust-runner

log "== 9/9 Checks"
"$DEPLOY_DIR/smoke.sh" --host-only

log
log "Host setup finished. Next: push.sh --acme-staging (see README.md)."
