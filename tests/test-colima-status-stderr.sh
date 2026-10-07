#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/colima" <<'SH'
#!/bin/sh
if [ "${1:-}" = "status" ]; then
  # Colima 0.10.x emits these INFO lines on stderr.
  printf '%s\n' 'INFO[0000] colima is running using Krunkit' >&2
  printf '%s\n' 'INFO[0000] arch: aarch64' >&2
  printf '%s\n' 'INFO[0000] runtime: docker' >&2
  exit 0
fi
exit 1
SH
chmod +x "$tmp/bin/colima"

PATH="$tmp/bin:/usr/bin:/bin"
export PATH

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/common.sh"

status="$(colima_status_text)"
grep -Fq 'running using Krunkit' <<<"$status"
colima_uses_krunkit

echo 'Colima stderr Krunkit detection test passed'