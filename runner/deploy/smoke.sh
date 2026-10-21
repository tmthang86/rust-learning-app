#!/usr/bin/env bash
# Checks that this VM really runs learner code in gVisor, and that the
# runner works. Run as root on the VM. install.sh runs it after every
# deploy; you can run it by hand too:
#
#   sudo /opt/rust-runner/deploy/smoke.sh
#
# Options:
#   --host-only        only check Docker, gVisor and the host (no runner yet)
#   --release-dir DIR  release to test (default: /opt/rust-runner/current)
#   --insecure-tls     accept the Let's Encrypt staging certificate
#
# Every check prints PASS, FAIL or SKIP. The exit status is 1 if any FAIL.
set -uo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vars.sh
. "$DEPLOY_DIR/vars.sh"
# shellcheck source=lib.sh
. "$DEPLOY_DIR/lib.sh"

HOST_ONLY=0
RELEASE_DIR=$CURRENT_LINK
INSECURE_TLS=0
while (($#)); do
  case $1 in
    --host-only) HOST_ONLY=1 ;;
    --release-dir)
      RELEASE_DIR=${2:?--release-dir needs a directory}
      shift
      ;;
    --insecure-tls) INSECURE_TLS=1 ;;
    -h | --help)
      sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

require_root

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

FAILS=0
pass() { printf 'PASS  %s\n' "$1"; }
skip() { printf 'SKIP  %s\n' "$1"; }
note() { printf 'NOTE  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  FAILS=$((FAILS + 1))
}

# Where the settings come from: the release under test, else this directory.
if [[ -f $RELEASE_DIR/env ]]; then
  ENV_FILE=$RELEASE_DIR/env
else
  ENV_FILE=$DEPLOY_DIR/production.env
  ((HOST_ONLY)) || die "no release at $RELEASE_DIR (use --host-only before the first deploy)"
fi
IMAGE="$(env_get "$ENV_FILE" RUNNER_IMAGE)"
DOMAIN="$(env_get "$ENV_FILE" RUNNER_DOMAIN)"
[[ -n $IMAGE ]] || die "RUNNER_IMAGE is not set in $ENV_FILE"

echo "== Host: gVisor, Docker, runc"

# 1. gVisor
runsc_out="$(runsc --version 2>&1 | head -n 1 || true)"
if [[ $runsc_out == *"release-$RUNSC_VERSION" ]]; then
  pass "runsc is exactly $RUNSC_VERSION ($runsc_out)"
else
  fail "runsc version: wanted $RUNSC_VERSION, got '${runsc_out:-nothing}'"
fi
if [[ -x /usr/bin/gvisor-bin/gvisor_sentry ]]; then
  pass "gvisor_sentry is installed and executable"
else
  fail "/usr/bin/gvisor-bin/gvisor_sentry is missing or not executable"
fi

# 2. Docker uses runsc by default
if docker info --format '{{json .Runtimes}}' 2> /dev/null | jq -e 'has("runsc")' > /dev/null 2>&1; then
  pass "docker lists the runsc runtime"
else
  fail "docker does not list the runsc runtime"
fi
default_runtime="$(docker info --format '{{.DefaultRuntime}}' 2> /dev/null || true)"
if [[ $default_runtime == runsc ]]; then
  pass "docker's default runtime is runsc"
else
  fail "docker's default runtime is '${default_runtime:-unknown}', wanted runsc"
fi
docker_version="$(docker version --format '{{.Server.Version}}' 2> /dev/null || true)"
if [[ $docker_version == "$DOCKER_SEMVER" ]]; then
  pass "docker server is $DOCKER_SEMVER"
else
  fail "docker server is '${docker_version:-unknown}', wanted $DOCKER_SEMVER"
fi

# 3. daemon.json
if cmp -s "$DEPLOY_DIR/daemon.json" /etc/docker/daemon.json; then
  pass "/etc/docker/daemon.json is identical to deploy/daemon.json"
else
  fail "/etc/docker/daemon.json differs from deploy/daemon.json"
fi

# 4. runc (inside containerd.io; not used for jobs, but kept patched)
runc_version="$(runc --version 2> /dev/null | sed -n 's/^runc version \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
if [[ -n $runc_version ]] && version_ge "$runc_version" "$MIN_RUNC_VERSION"; then
  pass "runc $runc_version >= $MIN_RUNC_VERSION"
else
  fail "runc version '${runc_version:-unknown}' is older than $MIN_RUNC_VERSION"
fi

# 5. A container really runs under gVisor
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
  echo "     pulling $IMAGE"
  docker pull --quiet "$IMAGE" > /dev/null 2>&1 || true
fi
dmesg_out="$(timeout 120 docker run --rm --runtime runsc --network none "$IMAGE" dmesg 2>&1 || true)"
if grep -q 'Starting gVisor' <<< "$dmesg_out"; then
  pass "a container under runsc shows gVisor's boot messages"
else
  fail "dmesg in a runsc container does not look like gVisor: $(head -c 200 <<< "$dmesg_out" | tr '\n' ' ')"
fi

# 6. The runner must not be able to reach cloud credentials
echo "     cloud: $HOST_PROVIDER, CPU: $ARCH"
case $HOST_PROVIDER in
  oracle)
    # a. Oracle's own firewall file and the live rules let web traffic in.
    for port in 80 443; do
      if grep -q "dport $port .*rust-runner" "${RULES_V4}" 2> /dev/null \
        && iptables -S INPUT 2> /dev/null | grep -q -- "--dport $port .*-j ACCEPT"; then
        pass "iptables accepts new connections on port $port (file and live)"
      else
        fail "iptables does not accept port $port in both $RULES_V4 and the live rules: run setup-host.sh again"
      fi
    done
    # b. The runner's user cannot reach the instance metadata service. Root
    #    can: that is what proves the test would notice an open door.
    imds_url="http://$IMDS_ADDR/opc/v2/instance/"
    root_code="$(curl -s --noproxy '*' --max-time 3 -o /dev/null -w '%{http_code}' \
      -H 'Authorization: Bearer Oracle' "$imds_url" 2> /dev/null || true)"
    user_code="$(runuser -u rust-runner -- curl -s --noproxy '*' --max-time 3 -o /dev/null -w '%{http_code}' \
      -H 'Authorization: Bearer Oracle' "$imds_url" 2> /dev/null || true)"
    if [[ $user_code == 000 || -z $user_code ]]; then
      pass "the rust-runner user cannot reach the metadata service ($IMDS_ADDR)"
    else
      fail "the rust-runner user reached the metadata service (HTTP $user_code)"
    fi
    if [[ $root_code == 000 || -z $root_code ]]; then
      note "root cannot reach the metadata service either, so the check above proves little"
    else
      note "root reaches the metadata service (HTTP $root_code); only the rust-runner user is blocked"
    fi
    legacy_code="$(curl -s --noproxy '*' --max-time 3 -o /dev/null -w '%{http_code}' \
      "http://$IMDS_ADDR/opc/v1/instance/" 2> /dev/null || true)"
    if [[ $legacy_code == 200 ]]; then
      note "the old metadata endpoint (/opc/v1) still answers: create the instance with areLegacyImdsEndpointsDisabled (README, step 6)"
    fi
    ;;
  gce)
    meta_code="$(curl -s --noproxy '*' --max-time 3 -o "$TMPD"/metadata -w '%{http_code}' \
      -H 'Metadata-Flavor: Google' \
      http://169.254.169.254/computeMetadata/v1/instance/service-accounts/ 2> /dev/null || true)"
    meta_body="$(tr -d '[:space:]' < "$TMPD"/metadata 2> /dev/null || true)"
    rm -f "$TMPD"/metadata
    if [[ $meta_code == 000 || -z $meta_code ]]; then
      skip "metadata server not reachable"
    elif [[ $meta_code == 404 || ( $meta_code == 200 && -z $meta_body ) ]]; then
      pass "the VM has no service accounts"
    else
      fail "metadata server lists service accounts (HTTP $meta_code): $meta_body"
    fi
    ;;
  *)
    skip "unknown cloud: the metadata check is only done on Oracle and Compute Engine"
    ;;
esac

if ((HOST_ONLY)); then
  echo
  if ((FAILS)); then
    echo "$FAILS check(s) FAILED (host only)"
    exit 1
  fi
  echo "All host checks passed (the runner was not checked)."
  exit 0
fi

echo
echo "== Runner: $(readlink -f "$RELEASE_DIR")"

# 7. The full ignored Docker suite, under runsc
PREFIX="rr-smoke-$(date +%s)-"
if [[ -x $RELEASE_DIR/rust-runner-tests ]]; then
  echo "     running the ignored Docker tests (this takes a few minutes)"
  if (
    cd "$RELEASE_DIR" || exit 1
    RUNNER_DOCKER_RUNTIME=runsc RUNNER_IMAGE="$IMAGE" RUNNER_TEST_CONTAINER_PREFIX="$PREFIX" \
      timeout 1200 ./rust-runner-tests --ignored --test-threads=1 > "$TMPD"/tests.log 2>&1
  ); then
    pass "ignored Docker test suite under runsc: $(grep -E '^test result:' "$TMPD"/tests.log | tail -n 1)"
  else
    fail "ignored Docker test suite failed (last lines below)"
    tail -n 40 "$TMPD"/tests.log | sed 's/^/     | /'
  fi
  rm -f "$TMPD"/tests.log
  leftovers="$(docker ps -a --filter "name=^$PREFIX" --format '{{.Names}}' 2> /dev/null || true)"
  if [[ -z $leftovers ]]; then
    pass "no containers left over from the test run"
  else
    fail "containers left over from the test run: $leftovers"
  fi
else
  fail "$RELEASE_DIR/rust-runner-tests is missing"
fi

# 8. The service, through Caddy
if curl -fsS --noproxy '*' --max-time 5 http://127.0.0.1:8080/health 2> /dev/null | jq -e '.status == "ok"' > /dev/null 2>&1; then
  pass "http://127.0.0.1:8080/health reports status ok"
else
  fail "http://127.0.0.1:8080/health does not report status ok"
fi

curl_opts=(-s --noproxy '*' --max-time 10 --resolve "$DOMAIN:443:127.0.0.1")
((INSECURE_TLS)) && curl_opts+=(-k)
no_header_code=000
for _ in $(seq 1 30); do
  no_header_code="$(curl "${curl_opts[@]}" -o /dev/null -w '%{http_code}' -X POST \
    -H 'content-type: application/json' -d '{"code":"fn main() {}"}' \
    "https://$DOMAIN/run" 2> /dev/null || true)"
  [[ $no_header_code != 000 ]] && break
  sleep 3 # Caddy may still be getting its certificate
done
if [[ $no_header_code == 401 ]]; then
  pass "POST https://$DOMAIN/run without an App Check header gets 401"
else
  fail "POST https://$DOMAIN/run without a header got HTTP $no_header_code (wanted 401)"
fi
other_code="$(curl "${curl_opts[@]}" -o /dev/null -w '%{http_code}' "https://$DOMAIN/" 2> /dev/null || true)"
if [[ $other_code == 404 ]]; then
  pass "other paths get 404"
else
  fail "GET https://$DOMAIN/ got HTTP $other_code (wanted 404)"
fi

echo "     systemd-analyze security rust-runner (information only):"
systemd-analyze security rust-runner --no-pager 2> /dev/null | tail -n 3 | sed 's/^/     | /' || true

# 9. Latency baseline
echo "     --self-check x5 (compile + run hello world in the sandbox):"
selfcheck_fail=0
for i in 1 2 3 4 5; do
  start=${EPOCHREALTIME/./}
  if (
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
    "$RELEASE_DIR/rust-runner" --self-check > /dev/null 2>&1
  ); then
    status=ok
  else
    status=FAILED
    selfcheck_fail=1
  fi
  end=${EPOCHREALTIME/./}
  echo "     | run $i: $(((end - start) / 1000)) ms $status"
done
if ((selfcheck_fail)); then
  fail "rust-runner --self-check failed"
else
  pass "rust-runner --self-check works"
fi

echo
echo "caddy: $(caddy version 2> /dev/null | head -n 1 || echo unknown)"
if ((FAILS)); then
  echo "$FAILS check(s) FAILED"
  exit 1
fi
echo "All checks passed."
