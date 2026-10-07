#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/versions.running.env" <<'VERSIONS'
STACK_RELEASE=test
OLLAMA_IMAGE=evil.example/ollama:latest
OPEN_WEBUI_IMAGE=ghcr.io/open-webui/open-webui:v0.11.4
DOCLING_IMAGE=ghcr.io/docling-project/docling-serve:v1.35.0
MAINTENANCE_IMAGE=alpine:3.22.1
SMOKE_IMAGE=curlimages/curl:8.16.0
VERSIONS
set +e
BACKUP="$work" ./scripts/rollback.sh >"$work/out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -q 'Unsafe or unexpected rollback image reference' "$work/out"
echo 'rollback image validation test passed'
