#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/common.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

cat >"$bin/docker" <<'D'
#!/bin/sh
if [ "${1:-}" = image ] && [ "${2:-}" = inspect ]; then
  [ "${FAKE_IMAGES_PRESENT:-0}" = 1 ] && exit 0
  exit 1
fi
exit 0
D
chmod +x "$bin/docker"

cat >"$bin/colima" <<'C'
#!/bin/sh
if [ "${1:-}" = status ]; then
  if [ "${FAKE_KRUNKIT:-1}" = 1 ]; then
    echo 'INFO colima is running using Krunkit' >&2
  else
    echo 'INFO colima is running using QEMU' >&2
  fi
  exit 0
fi
exit 0
C
chmod +x "$bin/colima"

PATH="$bin:/usr/bin:/bin"
export PATH

FAKE_IMAGES_PRESENT=0
export FAKE_IMAGES_PRESENT
[[ "$(project_required_free_disk_gib a b c)" = 30 ]]
FAKE_IMAGES_PRESENT=1
export FAKE_IMAGES_PRESENT
[[ "$(project_required_free_disk_gib a b c)" = 16 ]]
COLIMA_MIN_FREE_DISK_GIB=22
export COLIMA_MIN_FREE_DISK_GIB
[[ "$(project_required_free_disk_gib a b c)" = 22 ]]
unset COLIMA_MIN_FREE_DISK_GIB

# 100 GiB total / 40 GiB free passes a 30 GiB fresh-install gate.
COLIMA_DISK_TOTAL_KIB_OVERRIDE=$((100*1024*1024)) \
COLIMA_DISK_FREE_KIB_OVERRIDE=$((40*1024*1024)) \
  colima_disk_preflight 30 >"$tmp/pass.out"
grep -Fq '100 GiB total / 40 GiB free' "$tmp/pass.out"

# 100 GiB total / 5 GiB free fails early and gives non-destructive recovery guidance.
if COLIMA_DISK_TOTAL_KIB_OVERRIDE=$((100*1024*1024)) \
   COLIMA_DISK_FREE_KIB_OVERRIDE=$((5*1024*1024)) \
   colima_disk_preflight 30 >"$tmp/fail.out" 2>&1; then
  echo 'disk preflight unexpectedly accepted an almost-full VM' >&2
  exit 1
fi
grep -Fq 'only about 5 GiB free' "$tmp/fail.out"
grep -Fq 'docker image prune -af' "$tmp/fail.out"
grep -Fq 'docker builder prune -af' "$tmp/fail.out"
grep -Fq 'sudo fstrim -a' "$tmp/fail.out"
grep -Fq 'colima start --memory 10 --root-disk 140' "$tmp/fail.out"
! grep -Fq 'volume prune' "$tmp/fail.out"

# Non-Krunkit profiles keep Colima's normal secondary-disk growth guidance.
if FAKE_KRUNKIT=0 \
   COLIMA_DISK_TOTAL_KIB_OVERRIDE=$((100*1024*1024)) \
   COLIMA_DISK_FREE_KIB_OVERRIDE=$((5*1024*1024)) \
   colima_disk_preflight 30 >"$tmp/nonkrun.out" 2>&1; then
  echo 'disk preflight unexpectedly accepted an almost-full non-Krunkit VM' >&2
  exit 1
fi
grep -Fq 'colima start --memory 10 --disk 140' "$tmp/nonkrun.out"

echo 'disk preflight test passed'
