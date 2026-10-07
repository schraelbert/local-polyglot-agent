#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source scripts/common.sh

[[ -f .env ]] || { echo ".env not found; run 'make up' first." >&2; exit 1; }
[[ -f "$VERSION_LOCK_FILE" ]] || { echo "Version lock not found: $VERSION_LOCK_FILE" >&2; exit 1; }

result_file="$(mktemp)"
trap 'rm -f "$result_file"' EXIT

backup_kind="${UPGRADE_BACKUP_KIND:-full}"
case "$backup_kind" in full|user-data) ;; *) echo "UPGRADE_BACKUP_KIND must be full or user-data." >&2; exit 2 ;; esac
echo "Creating a pre-upgrade ${backup_kind} backup from the currently running stack..."
BACKUP_RESULT_FILE="$result_file" ./scripts/backup.sh "$backup_kind"
backup_rel="$(cat "$result_file")"
[[ -n "$backup_rel" ]] || { echo "Upgrade backup did not return a path." >&2; exit 1; }

echo "Pulling images from tracked version lock: $VERSION_LOCK_FILE"
dc -f compose.yaml -f compose.test.yaml --profile maintenance --profile test pull

echo "Starting target runtime versions..."
./scripts/up.sh

set +e
./scripts/check.sh
check_rc=$?
smoke_rc=0
if [[ "${UPGRADE_RUN_SMOKE:-1}" == "1" && $check_rc -eq 0 ]]; then
  ./scripts/smoke-test.sh
  smoke_rc=$?
fi
set -e

if (( check_rc != 0 || smoke_rc != 0 )); then
  cat >&2 <<MSG
Upgrade validation failed.
Pre-upgrade backup: ${backup_rel}

The backup records the actual images that were running before the upgrade.
To restore the old database/data and start those recorded runtime versions:
  BACKUP=${backup_rel} RESTORE_CONFIRM=RESTORE make rollback

Do not repeatedly start the new Open WebUI against the old backup before
rollback; database migrations can be one-way.
MSG
  exit 1
fi

echo "Upgrade validation passed. Pre-upgrade backup retained at: ${backup_rel}"
echo "Run 'make benchmark' separately when translation/OCR quality is a release gate."
