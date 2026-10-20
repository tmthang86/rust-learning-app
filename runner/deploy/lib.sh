# Helpers for the scripts that run on the VM (setup-host.sh, install.sh,
# smoke.sh). Sourced, never run on its own.
# shellcheck shell=bash

log() { printf '%s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [[ $EUID -eq 0 ]] || die "run this as root (use sudo)"
}

# env_get FILE KEY: the value of KEY=value in an env file. The last
# assignment wins, and nothing in the file is run.
env_get() {
  sed -n "s/^$2=//p" "$1" | tail -n 1 | tr -d '\r'
}

# version_ge A B: true when A >= B (dotted versions).
version_ge() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$2" ]]
}

sha256_of() {
  sha256sum "$1" | cut -d ' ' -f 1
}

apt_get() {
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -y -o Dpkg::Options::=--force-confold "$@"
}

# The installed version of a Debian package, or nothing.
installed_version() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

# ---- Docker and gVisor -----------------------------------------------------

docker_repo_setup() {
  local key=/etc/apt/keyrings/docker.asc
  local want=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
  install -d -m 0755 /etc/apt/keyrings
  if [[ ! -s $key ]]; then
    curl -fsSL --retry 3 -o "$key.part" https://download.docker.com/linux/ubuntu/gpg
    # Check the key against Docker's published fingerprint before trusting it.
    gpg --show-keys --with-colons "$key.part" | grep -q "^fpr:::::::::$want:" \
      || { rm -f "$key.part"; die "Docker apt key has an unexpected fingerprint"; }
    mv "$key.part" "$key"
    chmod 0644 "$key"
  fi
  cat > /etc/apt/sources.list.d/docker.list <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable
EOF
}

caddy_repo_setup() {
  local key=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
  if [[ ! -s $key ]]; then
    curl -fsSL --retry 3 https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      | gpg --dearmor -o "$key.part"
    mv "$key.part" "$key"
    chmod 0644 "$key"
  fi
  cat > /etc/apt/sources.list.d/caddy-stable.list <<'EOF'
deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main
EOF
}

# Installs the pinned Docker packages and holds them.
install_docker_packages() {
  apt-mark unhold docker-ce docker-ce-cli containerd.io > /dev/null 2>&1 || true
  apt_get update
  apt_get install --no-install-recommends --allow-downgrades \
    "docker-ce=$DOCKER_VERSION" "docker-ce-cli=$DOCKER_VERSION" \
    "containerd.io=$CONTAINERD_VERSION"
  apt-mark hold docker-ce docker-ce-cli containerd.io
}

# Downloads the pinned runsc .deb, checks its sha256 and prints its path.
# Kept in $CACHE_DIR so a package rollback doesn't depend on the network.
fetch_runsc_deb() {
  local deb="$CACHE_DIR/runsc_${RUNSC_VERSION}_amd64.deb"
  install -d -m 0755 "$CACHE_DIR"
  if [[ ! -f $deb || "$(sha256_of "$deb")" != "$RUNSC_DEB_SHA256" ]]; then
    log "Downloading runsc $RUNSC_VERSION"
    curl -fsSL --retry 3 -o "$deb.part" "$RUNSC_DEB_URL"
    if [[ "$(sha256_of "$deb.part")" != "$RUNSC_DEB_SHA256" ]]; then
      rm -f "$deb.part"
      die "runsc .deb does not match the sha256 in vars.sh"
    fi
    mv "$deb.part" "$deb"
    chmod 0644 "$deb"
  fi
  printf '%s\n' "$deb"
}

# Installs the pinned runsc and holds it. The .deb's postinst runs
# `runsc install --clobber=false` when /etc/docker/daemon.json exists, and
# reloads Docker.
install_runsc() {
  local deb
  deb="$(fetch_runsc_deb)"
  apt-mark unhold runsc > /dev/null 2>&1 || true
  if [[ "$(installed_version runsc)" == "$RUNSC_VERSION" ]]; then
    log "runsc $RUNSC_VERSION is already installed"
  else
    apt_get install --allow-downgrades "$deb"
  fi
  apt-mark hold runsc
}

# Writes the daemon.json from this directory, if it is not there already.
write_daemon_json() {
  install -d -m 0755 /etc/docker
  if ! cmp -s "$DEPLOY_DIR/daemon.json" /etc/docker/daemon.json; then
    install -m 0644 "$DEPLOY_DIR/daemon.json" /etc/docker/daemon.json
  fi
}

# Fails loudly when /etc/docker/daemon.json differs from deploy/daemon.json
# (for example because something else changed the default runtime).
assert_daemon_json() {
  if ! cmp -s "$DEPLOY_DIR/daemon.json" /etc/docker/daemon.json; then
    diff -u "$DEPLOY_DIR/daemon.json" /etc/docker/daemon.json >&2 || true
    die "/etc/docker/daemon.json differs from deploy/daemon.json"
  fi
}

# ---- The running service ---------------------------------------------------

# Keeps a copy of this directory in $TOOLS_DIR, so rollbacks can run without
# uploading anything.
sync_tools_dir() {
  install -d -m 0755 "$TOOLS_DIR"
  if [[ "$(realpath "$DEPLOY_DIR")" != "$(realpath "$TOOLS_DIR")" ]]; then
    cp -a "$DEPLOY_DIR/." "$TOOLS_DIR/"
  fi
}

# wait_for_health SECONDS: waits until /health says "status":"ok".
wait_for_health() {
  local timeout=$1 deadline=$((SECONDS + $1))
  while ((SECONDS < deadline)); do
    if curl -fsS --max-time 5 http://127.0.0.1:8080/health 2> /dev/null \
      | jq -e '.status == "ok"' > /dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  log "/health did not report ok within ${timeout}s"
  return 1
}

# render_caddyfile ENV_FILE OUT_FILE [staging]
render_caddyfile() {
  local env_file=$1 out=$2 staging=${3:-}
  local domain acme_line=''
  domain="$(env_get "$env_file" RUNNER_DOMAIN)"
  [[ $domain =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] \
    || die "RUNNER_DOMAIN '$domain' is not a plain lower-case host name"
  if [[ $staging == staging ]]; then
    acme_line='acme_ca https://acme-staging-v02.api.letsencrypt.org/directory'
  fi
  sed -e "s|{{ACME_CA_LINE}}|$acme_line|" -e "s|{{RUNNER_DOMAIN}}|$domain|" \
    "$DEPLOY_DIR/Caddyfile.template" > "$out"
}

# validate_caddyfile FILE: checks a Caddyfile as the caddy user.
validate_caddyfile() {
  local file=$1 out
  chmod 0644 "$file"
  if ! out="$(HOME=/var/lib/caddy runuser -u caddy -- \
    caddy validate --config "$file" --adapter caddyfile 2>&1)"; then
    log "$out"
    die "the rendered Caddyfile is not valid"
  fi
}

# install_caddyfile FILE: validates, installs and reloads (or starts) Caddy.
install_caddyfile() {
  validate_caddyfile "$1"
  install -m 0644 "$1" /etc/caddy/Caddyfile
  if systemctl is-active --quiet caddy; then
    systemctl reload caddy
  else
    systemctl enable --now caddy
  fi
}

# "staging" when the installed Caddyfile uses the Let's Encrypt staging CA.
caddy_acme_mode() {
  if grep -q 'acme-staging' /etc/caddy/Caddyfile 2> /dev/null; then
    echo staging
  else
    echo production
  fi
}
