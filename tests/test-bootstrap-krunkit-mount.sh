#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT_DIR/scripts/bootstrap-macos.sh"

run_case() {
  local requested="$1" expected="$2"
  local tmp bin argsfile
  tmp="$(mktemp -d)"
  bin="$tmp/bin"
  argsfile="$tmp/colima-args"
  mkdir -p "$bin" "$tmp/home"

  cat > "$bin/uname" <<'SH'
#!/bin/sh
case "$1" in
  -s) echo Darwin ;;
  -m) echo arm64 ;;
  *) /usr/bin/uname "$@" ;;
esac
SH
  cat > "$bin/sw_vers" <<'SH'
#!/bin/sh
echo 26.6
SH
  cat > "$bin/sysctl" <<'SH'
#!/bin/sh
# 24 GiB
printf '%s\n' 25769803776
SH
  cat > "$bin/brew" <<'SH'
#!/bin/sh
if [ "$1" = "help" ] && [ "${2:-}" = "trust" ]; then
  exit 1
fi
exit 0
SH
  cat > "$bin/docker" <<'SH'
#!/bin/sh
case "$1 ${2:-}" in
  "compose version"|"info ") exit 0 ;;
  *) exit 0 ;;
esac
SH
  cat > "$bin/krunkit" <<'SH'
#!/bin/sh
exit 0
SH
  cat > "$bin/colima" <<'SH'
#!/bin/sh
if [ "$1" = "status" ]; then
  exit 1
fi
if [ "$1" = "start" ]; then
  printf '%s\n' "$@" > "$COLIMA_ARGS_FILE"
  exit 0
fi
exit 0
SH
  chmod +x "$bin"/*

  if [ -n "$requested" ]; then
    PATH="$bin:/usr/bin:/bin" HOME="$tmp/home" COLIMA_ARGS_FILE="$argsfile" \
      COLIMA_MOUNT_TYPE="$requested" "$BOOTSTRAP" >/dev/null
  else
    PATH="$bin:/usr/bin:/bin" HOME="$tmp/home" COLIMA_ARGS_FILE="$argsfile" \
      "$BOOTSTRAP" >/dev/null
  fi

  grep -Fx -- '--vm-type' "$argsfile" >/dev/null
  grep -Fx -- 'krunkit' "$argsfile" >/dev/null
  awk 'prev=="--mount-type" {print; exit} {prev=$0}' "$argsfile" | grep -Fx "$expected" >/dev/null
  rm -rf "$tmp"
}

run_case "" sshfs
run_case virtiofs virtiofs

echo 'bootstrap Krunkit mount compatibility test passed'
