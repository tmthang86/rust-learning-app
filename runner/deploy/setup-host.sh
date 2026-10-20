#!/usr/bin/env bash
# One-time (and safe to repeat) setup of the runner VM. Run as root on the VM,
# normally through `push.sh --setup`:
#
#   sudo ~/incoming/<id>/deploy/setup-host.sh
#
# It installs the pinned Docker and gVisor packages, the Docker daemon
# settings, Caddy, the service user, journald and unattended-upgrades
# settings and the systemd unit. On Oracle Cloud it also opens ports 80/443 in
# the VM's firewall, blocks the metadata service for the runner's user and
# turns off SSH passwords. It does not start the runner: that happens in
# install.sh once there is a release. It ends with `smoke.sh --host-only`.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vars.sh
. "$DEPLOY_DIR/vars.sh"
# shellcheck source=lib.sh
. "$DEPLOY_DIR/lib.sh"

require_root
take_lock

# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_CODENAME:-} == noble ]] \
  || die "this setup is for Ubuntu 24.04 (noble), found ${PRETTY_NAME:-unknown}"

log "== Host: $HOST_PROVIDER, CPU $ARCH"

log "== 1/10 Base packages"
apt_get update
apt_get install --no-install-recommends \
  ca-certificates curl gnupg binutils jq unattended-upgrades
if [[ $HOST_PROVIDER == oracle ]]; then
  # Answer the "save current rules?" question before the package asks it:
  # saved rules would include Docker's chains.
  echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections
  echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections
  apt_get install --no-install-recommends iptables iptables-persistent
fi

log "== 2/10 Docker $DOCKER_SEMVER (pinned, held)"
docker_repo_setup
install_docker_packages

log "== 3/10 Docker daemon settings"
write_daemon_json

log "== 4/10 gVisor runsc $RUNSC_VERSION (pinned, held)"
# The .deb's postinst runs `runsc install --clobber=false` because
# daemon.json exists now. That keeps our entry. deploy/daemon.json is written
# in the exact format runsc writes, so the file stays byte-identical.
install_runsc
assert_daemon_json
systemctl enable docker
systemctl restart docker

log "== 5/10 Caddy"
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

log "== 6/10 Service user and directories"
if ! id rust-runner > /dev/null 2>&1; then
  useradd --system --user-group --no-create-home \
    --home-dir /nonexistent --shell /usr/sbin/nologin rust-runner
fi
install -d -m 0755 "$BASE_DIR" "$RELEASES_DIR" "$CACHE_DIR"
sync_tools_dir

log "== 7/10 Provider settings ($HOST_PROVIDER)"
case $HOST_PROVIDER in
  oracle)
    oracle_firewall
    oracle_ssh_hardening
    ;;
  gce) log "  nothing to do: the firewall is the VPC rule, the VM has no service account" ;;
  *) log "  unknown cloud: open ports 80 and 443 yourself and keep the metadata service away from the runner" ;;
esac

log "== 8/10 Journal and automatic security updates"
install -d -m 0755 /etc/systemd/journald.conf.d
install -m 0644 "$DEPLOY_DIR/journald-runner.conf" /etc/systemd/journald.conf.d/runner.conf
systemctl restart systemd-journald
install -m 0644 "$DEPLOY_DIR/52unattended-upgrades-runner" \
  /etc/apt/apt.conf.d/52unattended-upgrades-runner

log "== 9/10 systemd unit"
install -m 0644 "$DEPLOY_DIR/rust-runner.service" /etc/systemd/system/rust-runner.service
systemctl daemon-reload
systemctl enable rust-runner

log "== 10/10 Checks"
"$DEPLOY_DIR/smoke.sh" --host-only

log
log "Host setup finished. Next: push.sh --acme-staging (see README.md)."
