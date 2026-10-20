# Helpers for the scripts that run on the VM (setup-host.sh, install.sh,
# smoke.sh). Sourced, never run on its own.
# shellcheck shell=bash

# The VM works out its own CPU architecture and cloud, so the same scripts run
# on Oracle (arm64) and on Compute Engine (amd64). `use_arch` is in vars.sh.
use_arch "$(dpkg --print-architecture)" || exit 1

log() { printf '%s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [[ $EUID -eq 0 ]] || die "run this as root (use sudo)"
}

# take_lock: only one setup, deploy, rollback or upgrade at a time. The lock
# is held until the script exits.
take_lock() {
  install -d -m 0755 "$(dirname "$LOCK_FILE")"
  exec 9> "$LOCK_FILE"
  flock -n 9 || die "another setup, deploy, rollback or upgrade is running on this VM: wait for it to finish"
}

# detect_provider: oracle, gce or other. Reads the firmware strings that the
# cloud sets. No network call. HOST_PROVIDER overrides it (for tests).
detect_provider() {
  local tag product
  tag="$(cat /sys/class/dmi/id/chassis_asset_tag 2> /dev/null || true)"
  product="$(cat /sys/class/dmi/id/product_name 2> /dev/null || true)"
  if [[ $tag == *OracleCloud.com* ]]; then
    echo oracle
  elif [[ $product == 'Google Compute Engine' ]]; then
    echo gce
  else
    echo other
  fi
}
HOST_PROVIDER="${HOST_PROVIDER:-$(detect_provider)}"

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
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable\n' \
    "$ARCH" > /etc/apt/sources.list.d/docker.list
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
  local deb="$CACHE_DIR/runsc_${RUNSC_VERSION}_${ARCH}.deb"
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
    # The upload belongs to the login user. The copy that root runs must
    # belong to root, or that user could edit scripts that run as root.
    cp -R --no-preserve=ownership "$DEPLOY_DIR/." "$TOOLS_DIR/"
  fi
  chown -R root:root "$TOOLS_DIR"
  chmod -R u+rwX,go+rX,go-w "$TOOLS_DIR"
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

# release_file DIR NAME: the file NAME stored in a release directory. Releases
# keep their own copy of the systemd unit and the Caddyfile template, so a
# rollback brings those back too. Falls back to this directory's copy.
release_file() {
  if [[ -f $1/$2 ]]; then
    printf '%s\n' "$1/$2"
  else
    printf '%s\n' "$DEPLOY_DIR/$2"
  fi
}

# render_caddyfile ENV_FILE TEMPLATE OUT_FILE [staging]
render_caddyfile() {
  local env_file=$1 template=$2 out=$3 staging=${4:-}
  local domain acme_line=''
  domain="$(env_get "$env_file" RUNNER_DOMAIN)"
  [[ $domain =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] \
    || die "RUNNER_DOMAIN '$domain' is not a plain lower-case host name"
  if [[ $staging == staging ]]; then
    acme_line='acme_ca https://acme-staging-v02.api.letsencrypt.org/directory'
  fi
  sed -e "s|{{ACME_CA_LINE}}|$acme_line|" -e "s|{{RUNNER_DOMAIN}}|$domain|" \
    "$template" > "$out"
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
# When the certificate authority changes (Let's Encrypt staging <-> production)
# Caddy is restarted, not reloaded: a reload can keep using the certificate it
# already has.
install_caddyfile() {
  local old_mode new_mode
  validate_caddyfile "$1"
  old_mode="$(caddy_acme_mode)"
  install -m 0644 "$1" /etc/caddy/Caddyfile
  new_mode="$(caddy_acme_mode)"
  if ! systemctl is-active --quiet caddy; then
    systemctl enable --now caddy
  elif [[ $old_mode != "$new_mode" ]]; then
    systemctl restart caddy
  else
    systemctl reload caddy
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

# ---- Oracle Cloud: SSH, firewall, metadata ---------------------------------
# Oracle's Ubuntu image has its own iptables rules in /etc/iptables/rules.v4:
# they allow SSH and reject everything else new. Ports 80 and 443 have to be
# opened there as well as in the VCN security list. The same file is the
# place to block the instance metadata service for the runner's user.
#
# These rules are tagged with a comment starting "rust-runner-". Every run
# removes the tagged lines and writes them again, so repeating is safe, and
# Oracle's own rules (SSH, iSCSI to 169.254.0.2, ...) are never touched.

RULES_V4="${RULES_V4:-/etc/iptables/rules.v4}"
IMDS_ADDR=169.254.169.254

# edit_rules_v4 IN OUT RUNNER_UID: writes IN to OUT with our three rules.
#  - 80 and 443 are accepted just before the filter table's final
#    `-A INPUT -j REJECT` (or at the end of the table without one);
#  - traffic from the runner's user to the metadata address is rejected at
#    the top of OUTPUT, so no earlier ACCEPT can skip it.
edit_rules_v4() {
  local in=$1 out=$2 uid=$3
  local http='-A INPUT -p tcp -m state --state NEW -m tcp --dport 80 -m comment --comment "rust-runner-http" -j ACCEPT'
  local https='-A INPUT -p tcp -m state --state NEW -m tcp --dport 443 -m comment --comment "rust-runner-https" -j ACCEPT'
  local imds="-A OUTPUT -d $IMDS_ADDR/32 -m owner --uid-owner $uid -m comment --comment \"rust-runner-imds\" -j REJECT --reject-with icmp-port-unreachable"
  grep -v -e 'comment --comment "rust-runner-' "$in" \
    | awk -v http="$http" -v https="$https" -v imds="$imds" '
      /^\*filter/ { in_filter = 1 }
      in_filter && !done_in && /^-A INPUT -j (REJECT|DROP)/ { print http; print https; done_in = 1 }
      in_filter && !done_out && /^-A OUTPUT / { print imds; done_out = 1 }
      in_filter && /^COMMIT/ {
        if (!done_in) { print http; print https; done_in = 1 }
        if (!done_out) { print imds; done_out = 1 }
        in_filter = 0
      }
      { print }
    ' > "$out"
  grep -q 'rust-runner-imds' "$out" \
    || die "$in has no *filter table: not changing it (see README, step 13)"
}

# oracle_firewall: opens 80/443 and blocks the metadata service for the
# runner's user, in the file (for the next boot) and live (now).
oracle_firewall() {
  local uid tmp
  uid="$(id -u rust-runner)"
  command -v iptables > /dev/null || die "iptables is missing"
  if [[ ! -f $RULES_V4 ]]; then
    install -d -m 0755 "$(dirname "$RULES_V4")"
    printf '*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\nCOMMIT\n' > "$RULES_V4"
  fi
  [[ -e $RULES_V4.before-rust-runner ]] || cp -p "$RULES_V4" "$RULES_V4.before-rust-runner"
  tmp="$(mktemp)"
  edit_rules_v4 "$RULES_V4" "$tmp" "$uid"
  # --test parses the whole file and applies nothing.
  iptables-restore --test < "$tmp" || { rm -f "$tmp"; die "the edited $RULES_V4 does not parse: left as it was"; }
  install -m 0644 "$tmp" "$RULES_V4"
  rm -f "$tmp"
  # Live: one rule at a time. Never iptables-restore here: it would flush the
  # chains Docker keeps for its networks.
  iptables -C INPUT -p tcp -m state --state NEW -m tcp --dport 80 -m comment --comment rust-runner-http -j ACCEPT 2> /dev/null \
    || iptables -I INPUT 1 -p tcp -m state --state NEW -m tcp --dport 80 -m comment --comment rust-runner-http -j ACCEPT
  iptables -C INPUT -p tcp -m state --state NEW -m tcp --dport 443 -m comment --comment rust-runner-https -j ACCEPT 2> /dev/null \
    || iptables -I INPUT 1 -p tcp -m state --state NEW -m tcp --dport 443 -m comment --comment rust-runner-https -j ACCEPT
  iptables -C OUTPUT -d "$IMDS_ADDR/32" -m owner --uid-owner "$uid" -m comment --comment rust-runner-imds -j REJECT --reject-with icmp-port-unreachable 2> /dev/null \
    || iptables -I OUTPUT 1 -d "$IMDS_ADDR/32" -m owner --uid-owner "$uid" -m comment --comment rust-runner-imds -j REJECT --reject-with icmp-port-unreachable
}

# oracle_ssh_hardening: key-only SSH. The file name sorts before cloud-init's
# 50-cloud-init.conf, because sshd keeps the FIRST value it reads.
oracle_ssh_hardening() {
  local conf=/etc/ssh/sshd_config.d/00-rust-runner.conf
  install -d -m 0755 /etc/ssh/sshd_config.d
  cat > "$conf.part" <<'EOS'
# Managed by rust-runner setup-host.sh.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
MaxAuthTries 3
EOS
  mv "$conf.part" "$conf"
  chmod 0644 "$conf"
  sshd -t || { rm -f "$conf"; die "sshd rejected the SSH settings; removed them"; }
  systemctl reload ssh || systemctl restart ssh
}
