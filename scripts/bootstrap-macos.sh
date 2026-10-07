#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This bootstrap script is for macOS." >&2
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Apple Silicon (arm64) is required for the Krunkit GPU path." >&2
  exit 1
fi

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "${macos_major}" -lt 14 ]]; then
  echo "Krunkit currently requires macOS 14 or newer. CPU mode can still be used with another Docker/Colima setup." >&2
  exit 1
fi

command -v brew >/dev/null || {
  echo "Homebrew is required. Install it first from https://brew.sh" >&2
  exit 1
}

brew install colima docker docker-compose

# Homebrew's docker-compose formula installs a Docker CLI plugin, but the Docker
# CLI does not always discover Homebrew's plugin directory automatically.
# Prefer the user's standard plugin directory so we do not overwrite config.json.
if ! docker compose version >/dev/null 2>&1; then
  plugin_src="$(brew --prefix)/lib/docker/cli-plugins/docker-compose"
  plugin_dst="${HOME}/.docker/cli-plugins/docker-compose"
  if [[ ! -x "$plugin_src" ]]; then
    echo "docker-compose was installed, but its Docker CLI plugin was not found at: $plugin_src" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$plugin_dst")"
  ln -sfn "$plugin_src" "$plugin_dst"
fi

docker compose version >/dev/null || {
  echo "Docker Compose plugin is installed but 'docker compose' is still unavailable." >&2
  exit 1
}

# Homebrew 6+ requires explicit trust for third-party taps. krunkit depends on
# other formulae from the same tap (currently gvproxy -> libkrun ->
# libkrunfw/virglrenderer). Trust the transitive formula dependency closure
# without granting trust to every current/future formula in the tap.
brew tap libkrun/krun
if brew help trust >/dev/null 2>&1; then
  tap_repo="$(brew --repository libkrun/krun)"
  # macOS still ships Bash 3.2, so avoid associative arrays here.
  trusted_formulae="|"

  trust_tap_formula_tree() {
    local formula="$1" file dep
    case "$trusted_formulae" in
      *"|${formula}|"*) return 0 ;;
    esac
    trusted_formulae="${trusted_formulae}${formula}|"

    echo "Trusting required formula: libkrun/krun/${formula}"
    brew trust --formula "libkrun/krun/${formula}"

    file="${tap_repo}/Formula/${formula}.rb"
    [[ -f "$file" ]] || return 0

    while IFS= read -r dep; do
      [[ -f "${tap_repo}/Formula/${dep}.rb" ]] || continue
      trust_tap_formula_tree "$dep"
    done < <(sed -nE 's/^[[:space:]]*depends_on[[:space:]]+"([^"]+)".*$/\1/p' "$file")
  }

  trust_tap_formula_tree krunkit
fi
brew install libkrun/krun/krunkit

for cmd in colima docker krunkit; do
  command -v "$cmd" >/dev/null || {
    echo "Required command was not installed successfully: $cmd" >&2
    exit 1
  }
done

CPU="${COLIMA_CPU:-6}"
if [[ -n "${COLIMA_MEMORY:-}" ]]; then
  MEMORY="$COLIMA_MEMORY"
else
  total_bytes="$(sysctl -n hw.memsize)"
  total_gb=$(( total_bytes / 1024 / 1024 / 1024 ))
  if (( total_gb <= 16 )); then
    MEMORY=10
  elif (( total_gb <= 24 )); then
    MEMORY=16
  elif (( total_gb <= 32 )); then
    MEMORY=20
  else
    MEMORY=24
  fi
fi
ROOT_DISK="${COLIMA_ROOT_DISK:-${COLIMA_DISK:-120}}"

# Colima 0.10.3 has a Krunkit mount negotiation bug where an explicit
# --mount-type virtiofs can still reach Lima/Krunkit as 9p. The stable
# workaround is to ask Colima for sshfs, which its Lima adapter translates to
# reverse-sshfs (accepted by the Krunkit driver). Keep this overrideable so a
# future Colima release containing the upstream fix can opt back into virtiofs.
MOUNT_TYPE="${COLIMA_MOUNT_TYPE:-sshfs}"
case "$MOUNT_TYPE" in
  sshfs|virtiofs) ;;
  *)
    echo "Unsupported COLIMA_MOUNT_TYPE: $MOUNT_TYPE (use sshfs or virtiofs)." >&2
    exit 1
    ;;
esac

echo "Colima resources: CPU=${CPU}, memory=${MEMORY}GiB, root-disk=${ROOT_DISK}GiB, mount=${MOUNT_TYPE}"

if colima status >/dev/null 2>&1; then
  if ! colima_uses_krunkit; then
    cat >&2 <<MSG
An existing running Colima VM is not using Krunkit.
The VM type cannot be changed in-place.
Back up anything important, then run:
  colima stop
  colima delete
and rerun this script.
MSG
    exit 2
  fi
else
  start_log="$(mktemp)"
  if ! colima start --runtime docker --vm-type krunkit --mount-type "$MOUNT_TYPE" \
      --cpu "$CPU" --memory "$MEMORY" --root-disk "$ROOT_DISK" 2>&1 | tee "$start_log"; then
    if grep -Eq 'mountType.*(9p|virtiofs|reverse-sshfs)' "$start_log"; then
      cat >&2 <<MSG
Colima/Krunkit failed while negotiating the VM mount driver.

This project requested mount type: ${MOUNT_TYPE}
Colima 0.10.3 is affected by an upstream Krunkit mount bug that can pass 9p
through even when virtiofs was requested. The default workaround in this
release is COLIMA_MOUNT_TYPE=sshfs, which maps to reverse-sshfs in Krunkit.

If this profile was partially created by an earlier failed bootstrap, retry:
  colima delete -f
  COLIMA_MOUNT_TYPE=sshfs make bootstrap

Do not add --data unless you intentionally want to delete Colima container data.
MSG
    fi
    rm -f "$start_log"
    exit 1
  fi
  rm -f "$start_log"
fi

# Sanity-check the Docker context after Colima startup.
docker info >/dev/null || {
  echo "Docker CLI cannot reach the Colima Docker daemon." >&2
  exit 1
}

echo "Colima/Krunkit is ready."
