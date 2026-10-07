#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Reuse normal provisioning/secrets and capability routing first. This also
# writes .runtime.env with the effective chat model/context for this machine.
./scripts/up.sh >/dev/null
# shellcheck disable=SC1091
source scripts/common.sh
require_docker_daemon || exit 1

compose_args=(-f compose.yaml -f compose.debug.yaml)
if [[ "$(effective_env_get OLLAMA_RUNTIME_GPU 0)" == "1" ]]; then
  compose_args+=( -f compose.macos-gpu.yaml )
fi
dc "${compose_args[@]}" up -d
printf 'Debug Ollama API: http://localhost:%s\n' "$(env_get OLLAMA_PORT 11434)"
printf 'Debug Docling UI: http://localhost:%s/ui\n' "$(env_get DOCLING_PORT 5001)"
echo "Run 'make up' to return to the default non-published backend profile."
