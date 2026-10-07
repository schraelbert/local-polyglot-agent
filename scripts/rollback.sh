#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

backup_input="${BACKUP:-${1:-}}"
if [[ -z "$backup_input" ]]; then
  echo "Set BACKUP to a v2 backup directory, e.g. BACKUP=backups/... make rollback" >&2
  exit 2
fi
if [[ "$backup_input" = /* ]]; then backup_abs="$backup_input"; else backup_abs="${ROOT_DIR}/${backup_input}"; fi
[[ -d "$backup_abs" ]] || { echo "Backup directory not found: $backup_abs" >&2; exit 1; }
[[ -s "$backup_abs/versions.running.env" ]] || {
  echo "Rollback requires a v2 backup containing versions.running.env." >&2
  exit 1
}

# A rollback version file is data from a backup, not trusted shell code. Restrict
# image references to the upstream repositories this project intentionally uses
# before Compose is allowed to consume them.
# shellcheck disable=SC1091
source scripts/common.sh
runtime_versions="$backup_abs/versions.running.env"
validate_image_ref() {
  local key="$1" repo_re="$2" value
  value="$(env_get "$key" "" "$runtime_versions")"
  if ! [[ "$value" =~ ^${repo_re}(:[A-Za-z0-9._-]+|@sha256:[0-9a-fA-F]{64})$ ]]; then
    echo "Unsafe or unexpected rollback image reference for $key: $value" >&2
    exit 1
  fi
}
validate_image_ref OLLAMA_IMAGE 'ollama/ollama'
validate_image_ref OPEN_WEBUI_IMAGE 'ghcr\.io/open-webui/open-webui'
validate_image_ref DOCLING_IMAGE 'ghcr\.io/docling-project/docling-serve'
validate_image_ref MAINTENANCE_IMAGE 'alpine'
validate_image_ref SMOKE_IMAGE 'curlimages/curl'

export VERSION_LOCK_FILE="$runtime_versions"
export BACKUP="$backup_abs"

# restore.sh compares the backup's recorded runtime to VERSION_LOCK_FILE; using
# versions.running.env makes the compatibility guard exact instead of bypassed.
./scripts/restore.sh

VERSION_LOCK_FILE="$VERSION_LOCK_FILE" ./scripts/check.sh || {
  echo "Rollback data restore completed, but health checks failed." >&2
  exit 1
}

cat <<MSG
Rollback completed using the runtime versions recorded in:
  ${VERSION_LOCK_FILE}

Important: this is an emergency runtime pin for this invocation. A later plain
'make up' uses the repository's tracked versions.env again. For a durable code
rollback, check out the repository release/commit that matches the backup and
then run its normal validation.
MSG
