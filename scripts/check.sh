#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source scripts/common.sh

require_docker_daemon || exit 1

WEBUI_PORT="$(env_get WEBUI_PORT 3000)"
DOCLING_API_KEY="$(env_get DOCLING_API_KEY)"
CHAT_MODEL="$(effective_env_get CHAT_MODEL qwen3.5:9b-q4_K_M)"
KNOWLEDGE_CHAT_MODEL="$(effective_env_get KNOWLEDGE_CHAT_MODEL qwen2.5:7b)"
VISION_CHAT_MODEL="$(effective_env_get VISION_CHAT_MODEL qwen3-vl:4b-instruct)"
AGENT_MODEL="$(env_get AGENT_MODEL polyglot-agent:latest)"
KNOWLEDGE_AGENT_MODEL="$(effective_env_get KNOWLEDGE_AGENT_MODEL polyglot-agent-knowledge:latest)"
VISION_AGENT_MODEL="$(effective_env_get VISION_AGENT_MODEL polyglot-agent-vision:latest)"
EMBEDDING_MODEL="$(env_get EMBEDDING_MODEL bge-m3)"
LITERATURE_CORPUS_MIN_WORKS="$(env_get LITERATURE_CORPUS_MIN_WORKS 100000)"

fail=0

dcurl() {
  dc -f compose.yaml -f compose.test.yaml --profile test \
    run --rm --no-deps -T smoke-helper "$@"
}

if curl -fsS --max-time 10 "http://localhost:${WEBUI_PORT}/health" >/dev/null; then
  echo "[ok] Open WebUI"
else
  echo "[fail] Open WebUI health -> http://localhost:${WEBUI_PORT}/health" >&2
  fail=1
fi

if dcurl -fsS --max-time 10 http://ollama:11434/api/tags >/dev/null; then
  echo "[ok] Ollama (Compose internal network)"
else
  echo "[fail] Ollama internal API" >&2
  fail=1
fi

router_health="$(dcurl -fsS --max-time 10 http://model-router:11434/health 2>/dev/null || true)"
if grep -Fq '"external_tools":"disabled"' <<<"$router_health"; then
  echo "[ok] model router (sticky text: Chinese-first ${KNOWLEDGE_CHAT_MODEL} / other-text ${CHAT_MODEL}; context-resolved translation ${CHAT_MODEL}; vision ${VISION_CHAT_MODEL}; external tools stripped)"
else
  echo "[fail] model router internal API/tool policy" >&2
  printf '       health: %.300s\n' "$router_health" >&2
  fail=1
fi

webui_tool_env="$(dc -f compose.yaml exec -T open-webui sh -lc 'printf "%s\n%s\n" "${DEFAULT_MODEL_METADATA:-}" "${ENABLE_PLUGINS:-}"' 2>/dev/null || true)"
if grep -Fq '"builtin_tools":false' <<<"$webui_tool_env" && grep -Fxq 'false' <<<"$webui_tool_env"; then
  echo "[ok] Open WebUI built-in/plugin tool surface disabled; file-context RAG remains separate"
else
  echo "[fail] Open WebUI tool surface is not disabled by deployment policy" >&2
  printf '       env: %.500s\n' "$webui_tool_env" >&2
  fail=1
fi

corpus_count="$(dc -f compose.yaml exec -T model-router python3 -c 'import os,sqlite3; p=os.environ.get("LITERATURE_CORPUS_DB","/corpus/poetry.sqlite3"); c=sqlite3.connect("file:"+p+"?mode=ro", uri=True); print(c.execute("SELECT COUNT(*) FROM works").fetchone()[0]); c.close()' 2>/dev/null || true)"
if [[ "$corpus_count" =~ ^[0-9]+$ ]] && (( corpus_count >= LITERATURE_CORPUS_MIN_WORKS )); then
  echo "[ok] local literature corpus: ${corpus_count} works"
else
  echo "[fail] local literature corpus unavailable or undersized (got ${corpus_count:-no count}; need >= ${LITERATURE_CORPUS_MIN_WORKS})" >&2
  fail=1
fi

if dcurl -fsS --max-time 10 -H "X-Api-Key: ${DOCLING_API_KEY}" http://docling:5001/ready >/dev/null; then
  echo "[ok] Docling (Compose internal network)"
else
  echo "[fail] Docling internal API" >&2
  fail=1
fi

model_check() {
  local model="$1"
  if dcurl -fsS --max-time 10 \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${model}\"}" \
    http://ollama:11434/api/show >/dev/null; then
    echo "[ok] model present: ${model}"
  else
    echo "[warn] model not found yet: ${model}" >&2
  fi
}

model_check "$CHAT_MODEL"
if [[ "$KNOWLEDGE_CHAT_MODEL" != "$CHAT_MODEL" ]]; then model_check "$KNOWLEDGE_CHAT_MODEL"; fi
if [[ "$VISION_CHAT_MODEL" != "$CHAT_MODEL" && "$VISION_CHAT_MODEL" != "$KNOWLEDGE_CHAT_MODEL" ]]; then model_check "$VISION_CHAT_MODEL"; fi
model_check "$EMBEDDING_MODEL"
model_check "$AGENT_MODEL"
model_check "$KNOWLEDGE_AGENT_MODEL"
model_check "$VISION_AGENT_MODEL"

# The curated endpoint must expose exactly the public agent and no base/hidden
# models. This is what keeps the Open WebUI selector clean.
router_tags="$(dcurl -fsS --max-time 10 http://model-router:11434/api/tags 2>/dev/null || true)"
if curated_tags_expose_only_public_model \
  "$router_tags" "$AGENT_MODEL" \
  "$KNOWLEDGE_AGENT_MODEL" "$VISION_AGENT_MODEL" "$CHAT_MODEL" "$KNOWLEDGE_CHAT_MODEL" "$VISION_CHAT_MODEL" "$EMBEDDING_MODEL"; then
  echo "[ok] curated model list exposes only ${AGENT_MODEL}"
else
  echo "[fail] curated model list leaked an internal model or omitted ${AGENT_MODEL}" >&2
  printf '       tags: %.500s\n' "$router_tags" >&2
  fail=1
fi

exit "$fail"
