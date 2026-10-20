#!/usr/bin/env bash
# Creates the runner VM on Oracle Cloud (Always Free Ampere A1: 2 OCPU,
# 12 GB, Ubuntu 24.04, 50 GB boot volume) with the OCI command line tool, and
# keeps trying while Oracle answers "Out of capacity". Run it on your laptop:
#
#   runner/deploy/oracle-launch.sh --subnet-id ocid1.subnet.oc1... \
#       --ssh-key-file ~/.ssh/id_ed25519.pub
#
# Options:
#   --subnet-id OCID        the public subnet of your VCN (required)
#   --ssh-key-file FILE     the PUBLIC key that may log in as "ubuntu" (required)
#   --compartment-id OCID   default: your tenancy (the root compartment)
#   --name NAME             instance name (default: rust-runner)
#   --ad NAME               availability domain (default: try each one)
#   --retry-minutes N       give up after N minutes (default: 720; 0 = one try)
#   --interval SECONDS      pause between tries (default: 90)
#
# Needs the OCI CLI, set up with `oci setup config` (README, step 6).
# The VM is created with the old metadata endpoint switched off and a public
# IP address that Oracle picks. It can be launched only once: if an instance
# with the same name is alive, the script stops.
set -euo pipefail

OCI="${OCI:-oci}"
SHAPE=VM.Standard.A1.Flex
OCPUS=2
MEMORY_GB=12
BOOT_GB=50 # inside the free 200 GB of block volume

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}
say() { printf '%s\n' "$*" >&2; }

usage() {
  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

SUBNET=
KEY_FILE=
COMPARTMENT="${OCI_COMPARTMENT_ID:-}"
NAME=rust-runner
AD=
RETRY_MINUTES=720
INTERVAL=90
while [ $# -gt 0 ]; do
  case $1 in
    --subnet-id) SUBNET=${2:?--subnet-id needs a value}; shift ;;
    --ssh-key-file) KEY_FILE=${2:?--ssh-key-file needs a value}; shift ;;
    --compartment-id) COMPARTMENT=${2:?--compartment-id needs a value}; shift ;;
    --name) NAME=${2:?--name needs a value}; shift ;;
    --ad) AD=${2:?--ad needs a value}; shift ;;
    --retry-minutes) RETRY_MINUTES=${2:?--retry-minutes needs a value}; shift ;;
    --interval) INTERVAL=${2:?--interval needs a value}; shift ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done
[ -n "$SUBNET" ] || die "--subnet-id is required (README, steps 5 and 6)"
[ -n "$KEY_FILE" ] || die "--ssh-key-file is required"
[ -f "$KEY_FILE" ] || die "$KEY_FILE does not exist"
case $(cat "$KEY_FILE") in
  ssh-* | ecdsa-*) ;;
  *) die "$KEY_FILE does not look like a PUBLIC ssh key (it should start with ssh-ed25519 or ssh-rsa)" ;;
esac
case $RETRY_MINUTES$INTERVAL in
  *[!0-9]*) die "--retry-minutes and --interval must be whole numbers" ;;
esac
command -v "$OCI" > /dev/null 2>&1 || die "the OCI command line tool ('oci') is not installed (README, step 6)"

if [ -z "$COMPARTMENT" ]; then
  COMPARTMENT="$(sed -n 's/^tenancy *= *//p' "${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}" 2> /dev/null | head -n 1)"
fi
[ -n "$COMPARTMENT" ] || die "no compartment: pass --compartment-id (the tenancy OCID from ~/.oci/config works)"

say "== Checking that '$NAME' does not exist yet"
# shellcheck disable=SC2016 # the backticks are JMESPath, not a command
alive_query='data[?"lifecycle-state" != `TERMINATED`].id'
alive="$("$OCI" compute instance list --compartment-id "$COMPARTMENT" --display-name "$NAME" \
  --query "$alive_query" 2> /dev/null | grep -o 'ocid1[^"]*' || true)"
[ -z "$alive" ] || die "an instance named '$NAME' already exists ($alive). Delete it in the console first, or pass another --name."

say "== Looking up the Ubuntu 24.04 (aarch64) image"
IMAGE="$("$OCI" compute image list --compartment-id "$COMPARTMENT" \
  --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' \
  --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --limit 1 \
  --query 'data[0].id' --raw-output)" || die "could not list images"
case $IMAGE in
  ocid1.image.*) ;;
  *) die "no Ubuntu 24.04 image for $SHAPE found (got '$IMAGE')" ;;
esac
say "   $IMAGE"

if [ -n "$AD" ]; then
  ADS=$AD
else
  ADS="$("$OCI" iam availability-domain list --compartment-id "$COMPARTMENT" --query 'data[].name' \
    | grep -o '"[^"]*"' | tr -d '"')" || die "could not list availability domains"
fi
[ -n "$ADS" ] || die "no availability domain found"

# try_launch AD: prints the new instance's OCID and returns 0, or prints the
# error text and returns 1.
try_launch() {
  "$OCI" compute instance launch \
    --availability-domain "$1" --compartment-id "$COMPARTMENT" \
    --display-name "$NAME" --shape "$SHAPE" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --image-id "$IMAGE" --subnet-id "$SUBNET" --assign-public-ip true \
    --boot-volume-size-in-gbs "$BOOT_GB" \
    --ssh-authorized-keys-file "$KEY_FILE" \
    --instance-options '{"areLegacyImdsEndpointsDisabled": true}' \
    --wait-for-state RUNNING --query 'data.id' --raw-output 2>&1
}

DEADLINE=$((SECONDS + RETRY_MINUTES * 60))
ATTEMPT=0
INSTANCE=
while :; do
  for ad in $ADS; do
    ATTEMPT=$((ATTEMPT + 1))
    say "== Try $ATTEMPT in $ad ($(date '+%H:%M:%S'))"
    if out="$(try_launch "$ad")"; then
      INSTANCE="$(printf '%s\n' "$out" | grep -o 'ocid1\.instance[^" ]*' | tail -n 1)"
      break 2
    fi
    if printf '%s' "$out" | grep -qi -e 'out of .*capacity' -e 'TooManyRequests' -e '"status": 429'; then
      say "   Oracle has no free A1 capacity right now (or says slow down)."
    else
      printf '%s\n' "$out" >&2
      die "the launch failed for a reason other than capacity: read the message above"
    fi
  done
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    die "no capacity after $ATTEMPT tries. Run this script again later, or see README, step 6 (Out of capacity)."
  fi
  say "   Waiting $INTERVAL s, then trying again."
  sleep "$INTERVAL"
done

[ -n "$INSTANCE" ] || die "the launch printed no instance id"
say "== Instance created: $INSTANCE"
IP="$("$OCI" compute instance list-vnics --instance-id "$INSTANCE" --query 'data[0]."public-ip"' --raw-output)" \
  || die "could not read the public IP"
printf '\nPublic IP: %s\n' "$IP"
printf 'Next: point your DNS name at %s (README, step 7), then run push.sh --setup (step 13).\n' "$IP"
