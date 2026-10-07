#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source scripts/common.sh

require_docker_daemon || exit 1
[[ -f "$VERSION_LOCK_FILE" ]] || { echo "Version lock not found: $VERSION_LOCK_FILE" >&2; exit 1; }

if ! command -v colima >/dev/null 2>&1 || ! colima status >/dev/null 2>&1; then
  echo "Colima is not running; disk-check is available for the Colima runtime used by this project." >&2
  exit 1
fi

OLLAMA_IMAGE="$(version_get OLLAMA_IMAGE)"
OPEN_WEBUI_IMAGE="$(version_get OPEN_WEBUI_IMAGE)"
DOCLING_IMAGE="$(version_get DOCLING_IMAGE)"
required="$(project_required_free_disk_gib "$OLLAMA_IMAGE" "$OPEN_WEBUI_IMAGE" "$DOCLING_IMAGE")"

if colima_disk_preflight "$required"; then
  echo "[ok] Colima disk preflight passed (required free space: ${required} GiB)."
fi
