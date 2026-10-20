#!/usr/bin/env bash
# Installs a release of the runner on the VM. Run as root, normally through
# push.sh, which uploads the build next to this directory first:
#
#   install.sh <release-id> [--acme-staging]   install a new release
#   install.sh --rollback                      go back to the previous release
#   install.sh --upgrade-packages              install the versions in vars.sh
#
# A release is a directory /opt/rust-runner/releases/<id> with the binary, the
# env file and the sandbox image reference. `current` points at one release
# and the systemd unit reads everything through it, so switching the link
# switches binary, settings and image together.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vars.sh
. "$DEPLOY_DIR/vars.sh"
# shellcheck source=lib.sh
. "$DEPLOY_DIR/lib.sh"

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE=deploy
RELEASE_ID=
ACME_STAGING=0
while (($#)); do
  case $1 in
    --rollback) MODE=rollback ;;
    --upgrade-packages) MODE=upgrade ;;
    --acme-staging) ACME_STAGING=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option: $1" ;;
    *)
      [[ -z $RELEASE_ID ]] || die "only one release id, please"
      RELEASE_ID=$1
      ;;
  esac
  shift
done

require_root
command -v jq > /dev/null || die "jq is missing: run setup-host.sh first"
id rust-runner > /dev/null 2>&1 || die "user rust-runner is missing: run setup-host.sh first"

WORK="$(mktemp -d)"
chmod 0755 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# ---- Helpers ---------------------------------------------------------------

# The newest glibc symbol version a binary needs.
max_glibc() {
  { objdump -T "$1" 2> /dev/null || true; } | grep -o 'GLIBC_[0-9.]*' \
    | sed 's/^GLIBC_//' | sort -uV | tail -n 1
}

check_glibc() {
  local file=$1 need
  need="$(max_glibc "$file")"
  [[ -n $need ]] || die "$file has no glibc symbols: is it the right build?"
  version_ge "$MAX_GLIBC_VERSION" "$need" \
    || die "$file needs glibc $need, but the VM only provides $MAX_GLIBC_VERSION"
  log "  $(basename "$file") needs glibc <= $need"
}

# Points `current` at a release directory, atomically.
switch_current() {
  ln -sfn "$1" "$CURRENT_LINK.new"
  mv -T "$CURRENT_LINK.new" "$CURRENT_LINK"
}

set_previous() {
  ln -sfn "$1" "$PREVIOUS_LINK.new"
  mv -T "$PREVIOUS_LINK.new" "$PREVIOUS_LINK"
}

# Makes the systemd unit match this directory's copy.
install_unit() {
  if ! cmp -s "$DEPLOY_DIR/rust-runner.service" /etc/systemd/system/rust-runner.service; then
    install -m 0644 "$DEPLOY_DIR/rust-runner.service" /etc/systemd/system/rust-runner.service
    systemctl daemon-reload
  fi
}

# Starts the release `current` points to: Caddy config from its env file,
# then the runner, then waits until it is healthy.
activate_current() {
  local acme=$1
  render_caddyfile "$CURRENT_LINK/env" "$WORK/Caddyfile.active" "$acme"
  systemctl restart rust-runner || return 1
  install_caddyfile "$WORK/Caddyfile.active" || return 1
  wait_for_health 120
}

# Deletes old release directories and the sandbox images only they used.
prune_old() {
  local keep=() id
  while IFS= read -r id; do
    keep+=("$id")
  done < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' \
    | sort -rn | awk '{print $2}' | grep -E '^[0-9a-f]{7,40}$' | head -n "$KEEP_RELEASES")
  local cur prev
  cur="$(basename "$(readlink -f "$CURRENT_LINK")")"
  prev="$(basename "$(readlink -f "$PREVIOUS_LINK" 2> /dev/null || echo none)")"
  keep+=("$cur" "$prev")
  local dir name k found
  for dir in "$RELEASES_DIR"/*/; do
    name="$(basename "$dir")"
    [[ $name =~ ^[0-9a-f]{7,40}$ ]] || continue
    found=0
    for k in "${keep[@]}"; do [[ $k == "$name" ]] && found=1; done
    if ((!found)); then
      log "  removing old release $name"
      rm -rf "${RELEASES_DIR:?}/$name"
    fi
  done
  rm -rf "$RELEASES_DIR"/.*.new "$RELEASES_DIR"/*.old 2> /dev/null || true

  # Sandbox images that no kept release names. Images are only removed when
  # the list can be trusted (the current release's image is in it).
  local wanted listed
  wanted="$(cat "$RELEASES_DIR"/*/image 2> /dev/null | sort -u)"
  listed="$(docker images --digests --format '{{.Repository}}@{{.Digest}} {{.Tag}}' 'mirror.gcr.io/library/rust' 2> /dev/null || true)"
  if [[ -n $listed ]] && grep -qxF "$(cat "$CURRENT_LINK/image") <none>" <<< "$listed"; then
    local ref tag
    while read -r ref tag; do
      [[ $tag == '<none>' ]] || continue # never touch tagged images
      grep -qxF "$ref" <<< "$wanted" && continue
      log "  removing unused sandbox image $ref"
      docker image rm "$ref" > /dev/null 2>&1 || true
    done <<< "$listed"
  else
    log "  not pruning images: could not match the current image in 'docker images'"
  fi
}

# ---- Rollback --------------------------------------------------------------

do_rollback() {
  [[ -L $PREVIOUS_LINK && -d $PREVIOUS_LINK ]] || die "there is no previous release to go back to"
  local target now
  target="$(readlink -f "$PREVIOUS_LINK")"
  now="$(readlink -f "$CURRENT_LINK" 2> /dev/null || true)"
  log "Rolling back to $(basename "$target")"
  install_unit
  assert_daemon_json
  switch_current "$target"
  [[ -n $now ]] && set_previous "$now"
  activate_current "$(caddy_acme_mode)" || die "the previous release did not become healthy; look at: journalctl -u rust-runner -n 50"
  log "Rolled back. Now running: $(basename "$target")"
}

# ---- Package upgrade -------------------------------------------------------

record_packages() {
  {
    echo "PREV_RUNSC=$(installed_version runsc)"
    echo "PREV_DOCKER=$(installed_version docker-ce)"
    echo "PREV_DOCKER_CLI=$(installed_version docker-ce-cli)"
    echo "PREV_CONTAINERD=$(installed_version containerd.io)"
  } > "$PACKAGES_PREV"
}

restore_packages() {
  [[ -s $PACKAGES_PREV ]] || die "no $PACKAGES_PREV: cannot restore the old packages"
  # shellcheck disable=SC1090
  . "$PACKAGES_PREV"
  log "Restoring runsc $PREV_RUNSC, docker $PREV_DOCKER, containerd $PREV_CONTAINERD"
  apt-mark unhold runsc docker-ce docker-ce-cli containerd.io > /dev/null 2>&1 || true
  local deb="$CACHE_DIR/runsc_${PREV_RUNSC}_amd64.deb"
  if [[ -f $deb ]]; then
    apt_get install --allow-downgrades "$deb"
  else
    apt_get install --allow-downgrades "runsc=$PREV_RUNSC" \
      || die "the old runsc .deb is not cached ($deb) and not in apt"
  fi
  apt_get install --no-install-recommends --allow-downgrades \
    "docker-ce=$PREV_DOCKER" "docker-ce-cli=$PREV_DOCKER_CLI" "containerd.io=$PREV_CONTAINERD"
  apt-mark hold runsc docker-ce docker-ce-cli containerd.io
  systemctl restart docker
  if [[ -d $CURRENT_LINK ]]; then
    systemctl restart rust-runner
    wait_for_health 120 || true
  fi
}

do_upgrade() {
  log "Upgrading to runsc $RUNSC_VERSION, docker $DOCKER_SEMVER (containerd.io $CONTAINERD_VERSION)"
  record_packages
  docker_repo_setup
  write_daemon_json
  install_docker_packages
  install_runsc
  assert_daemon_json
  systemctl restart docker
  local ok=1
  if [[ -d $CURRENT_LINK ]]; then
    systemctl restart rust-runner
    wait_for_health 120 || ok=0
    if ((ok)); then
      local smoke_opts=(--release-dir "$CURRENT_LINK")
      [[ $(caddy_acme_mode) == staging ]] && smoke_opts+=(--insecure-tls)
      "$DEPLOY_DIR/smoke.sh" "${smoke_opts[@]}" || ok=0
    fi
  else
    "$DEPLOY_DIR/smoke.sh" --host-only || ok=0
  fi
  if ((!ok)); then
    log "The smoke test failed after the upgrade."
    restore_packages
    die "upgrade rolled back to the previous packages"
  fi
  sync_tools_dir
  log "Packages upgraded. Previous versions are in $PACKAGES_PREV."
}

# ---- New release -----------------------------------------------------------

do_deploy() {
  [[ $RELEASE_ID =~ ^[0-9a-f]{7,40}$ ]] || die "release id must be a git commit hash, got '$RELEASE_ID'"
  local incoming env_src final stage image domain bad
  incoming="$(dirname "$DEPLOY_DIR")"
  env_src="$DEPLOY_DIR/production.env"
  final="$RELEASES_DIR/$RELEASE_ID"
  stage="$RELEASES_DIR/.$RELEASE_ID.new"

  log "== Checking release $RELEASE_ID"
  bad="$(grep -n 'REPLACE' "$env_src" || true)"
  if [[ -n $bad ]]; then
    log "$bad"
    die "production.env still has REPLACE values: fill it in and commit it"
  fi
  image="$(env_get "$env_src" RUNNER_IMAGE)"
  domain="$(env_get "$env_src" RUNNER_DOMAIN)"
  [[ -n $image && -n $domain ]] || die "production.env needs RUNNER_IMAGE and RUNNER_DOMAIN"
  [[ $image == *@sha256:* ]] || die "RUNNER_IMAGE must be pinned by digest (name@sha256:...)"

  (cd "$incoming" && sha256sum --check --quiet SHA256SUMS) || die "SHA256SUMS does not match: the upload is damaged"
  log "  SHA256SUMS ok (this only guards the upload, not where the build came from)"
  local version
  version="$(env -i "$incoming/rust-runner" --version)" \
    || die "rust-runner --version failed: this binary does not start on this VM"
  log "  rust-runner --version: $version"
  env -i "$incoming/rust-runner-tests" --list > /dev/null \
    || die "rust-runner-tests does not start on this VM"
  check_glibc "$incoming/rust-runner"
  check_glibc "$incoming/rust-runner-tests"

  render_caddyfile "$env_src" "$WORK/Caddyfile.new" "$([[ $ACME_STAGING == 1 ]] && echo staging || echo production)"
  validate_caddyfile "$WORK/Caddyfile.new"
  assert_daemon_json
  if ! docker image inspect "$image" > /dev/null 2>&1; then
    log "== Pulling the sandbox image"
    docker pull "$image" > /dev/null || die "could not pull $image"
  fi

  log "== Creating release directory"
  install -d -m 0755 "$RELEASES_DIR"
  rm -rf "$stage"
  install -d -m 0755 "$stage"
  install -m 0755 "$incoming/rust-runner" "$incoming/rust-runner-tests" "$stage/"
  install -m 0644 "$env_src" "$stage/env"
  install -m 0644 "$incoming/SHA256SUMS" "$stage/SHA256SUMS"
  printf '%s\n' "$image" > "$stage/image"
  chmod 0644 "$stage/image"

  # Where `current` points now, so a failed deploy can go back to it.
  local old_dir=
  if [[ -L $CURRENT_LINK ]]; then
    old_dir="$(readlink -f "$CURRENT_LINK")"
  fi
  rm -rf "$final.old"
  if [[ -e $final ]]; then
    mv "$final" "$final.old"
    [[ $old_dir == "$final" ]] && old_dir="$final.old"
  fi
  mv "$stage" "$final"

  log "== Switching to $RELEASE_ID"
  install_unit
  switch_current "$final"
  local ok=1 acme
  acme="$([[ $ACME_STAGING == 1 ]] && echo staging || echo production)"
  activate_current "$acme" || ok=0
  if ((ok)); then
    log "== Smoke test"
    local smoke_opts=(--release-dir "$CURRENT_LINK")
    [[ $acme == staging ]] && smoke_opts+=(--insecure-tls)
    "$DEPLOY_DIR/smoke.sh" "${smoke_opts[@]}" || ok=0
  fi

  if ((!ok)); then
    log
    log "!! The release did not pass. Going back."
    if [[ -n $old_dir && -d $old_dir ]]; then
      if [[ $old_dir == "$final.old" ]]; then
        rm -rf "$final"
        mv "$final.old" "$final"
        old_dir="$final"
      fi
      switch_current "$old_dir"
      [[ $old_dir == "$final" ]] || rm -rf "${RELEASES_DIR:?}/$RELEASE_ID"
      if activate_current "$(caddy_acme_mode)"; then
        die "release $RELEASE_ID failed; the previous release is running again ($(basename "$old_dir")). See: journalctl -u rust-runner -n 100"
      fi
      die "release $RELEASE_ID failed and the previous release is not healthy either. See: journalctl -u rust-runner -n 100"
    fi
    die "release $RELEASE_ID failed and there is no earlier release to go back to. See: journalctl -u rust-runner -n 100"
  fi

  if [[ -n $old_dir && -d $old_dir && $old_dir != "$final" && $old_dir != "$final.old" ]]; then
    set_previous "$old_dir"
  fi
  rm -rf "$final.old"
  sync_tools_dir
  prune_old
  log
  log "Release $RELEASE_ID is live ($version)."
  if [[ $ACME_STAGING == 1 ]]; then
    log "Caddy uses the Let's Encrypt STAGING certificate. Run push.sh again without --acme-staging."
  fi
}

case $MODE in
  deploy)
    [[ -n $RELEASE_ID ]] || { usage >&2; exit 2; }
    do_deploy
    ;;
  rollback) do_rollback ;;
  upgrade) do_upgrade ;;
esac
