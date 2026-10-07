#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source scripts/common.sh

require_docker_daemon || exit 1
dc -f compose.yaml -f compose.macos-gpu.yaml down 2>/dev/null || dc -f compose.yaml down
