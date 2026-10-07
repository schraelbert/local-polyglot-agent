#!/usr/bin/env bash
set -u

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
SMOKE_HTTP_TIMEOUT="$(env_get SMOKE_HTTP_TIMEOUT 20)"
SMOKE_MODEL_TIMEOUT="$(env_get SMOKE_MODEL_TIMEOUT 300)"
SMOKE_DOCLING_TIMEOUT="$(env_get SMOKE_DOCLING_TIMEOUT 600)"
SMOKE_REQUIRE_GPU="${SMOKE_REQUIRE_GPU:-$(env_get SMOKE_REQUIRE_GPU 0)}"
LITERATURE_CORPUS_MIN_WORKS="$(env_get LITERATURE_CORPUS_MIN_WORKS 100000)"

VISION_FIXTURE="tests/fixtures/vision-42.png"
PDF_FIXTURE="/fixtures/docling-smoke.pdf"

fail=0
warn=0

ok() { printf '[ok] %s\n' "$*"; }
warning() { printf '[warn] %s\n' "$*" >&2; warn=$((warn + 1)); }
failed() { printf '[fail] %s\n' "$*" >&2; fail=$((fail + 1)); }

need_cmd() {
  if command -v "$1" >/dev/null 2>&1; then ok "command available: $1"; else failed "required command missing: $1"; fi
}

dcurl() {
  dc -f compose.yaml -f compose.test.yaml --profile test \
    run --rm --no-deps -T smoke-helper "$@"
}

ollama_show() {
  local model="$1"
  dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${model}\"}" \
    http://ollama:11434/api/show >/dev/null
}

language_test() {
  local label="$1" prompt="$2" expected="$3" response
  response="$(dcurl -fsS --max-time "$SMOKE_MODEL_TIMEOUT" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${AGENT_MODEL}\",\"prompt\":\"${prompt}\",\"stream\":false,\"think\":false,\"options\":{\"temperature\":0,\"num_predict\":24}}" \
    http://model-router:11434/api/generate 2>/dev/null)" || {
      failed "$label inference request failed"
      return
    }
  response_field="$(printf '%s\n' "$response" | ollama_generate_response_field || true)"
  if ollama_response_is_exact_marker_ci "$response_field" "$expected"; then ok "$label language inference"; else
    failed "$label inference did not return marker $expected in the response field"
    printf '       response field: %.300s\n' "$response_field" >&2
  fi
}

need_cmd curl
need_cmd docker
if [[ ${#DOCLING_API_KEY} -lt 32 ]]; then failed "DOCLING_API_KEY is missing or too short in .env"; fi
if (( fail > 0 )); then exit 1; fi

printf '\n== Services ==\n'
if dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" http://ollama:11434/api/tags >/dev/null; then ok "Ollama reachable internally"; else failed "Ollama internal API unreachable"; fi
router_health="$(dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" http://model-router:11434/health 2>/dev/null || true)"
if grep -Fq '"external_tools":"disabled"' <<<"$router_health"; then ok "model router reachable internally; external tool schemas are stripped"; else failed "model router internal API/tool policy unavailable"; fi
if dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" -H "X-Api-Key: ${DOCLING_API_KEY}" http://docling:5001/ready >/dev/null; then ok "Docling reachable internally"; else failed "Docling internal API unreachable"; fi
if curl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" "http://localhost:${WEBUI_PORT}/health" >/dev/null; then ok "Open WebUI reachable on localhost"; else failed "Open WebUI not reachable"; fi

printf '\n== Open WebUI tool surface ==\n'
webui_tool_env="$(dc -f compose.yaml exec -T open-webui sh -lc 'printf "%s\n%s\n" "${DEFAULT_MODEL_METADATA:-}" "${ENABLE_PLUGINS:-}"' 2>/dev/null || true)"
if grep -Fq '"builtin_tools":false' <<<"$webui_tool_env" && grep -Fxq 'false' <<<"$webui_tool_env"; then
  ok "built-in agentic tools and workspace plugins disabled; File Context/RAG remains enabled"
else
  failed "Open WebUI agentic tool surface is not disabled"
  printf '       env: %.500s\n' "$webui_tool_env" >&2
fi

printf '\n== Local exact-text corpus ==\n'
corpus_count="$(dc -f compose.yaml exec -T model-router python3 -c 'import os,sqlite3; p=os.environ.get("LITERATURE_CORPUS_DB","/corpus/poetry.sqlite3"); c=sqlite3.connect("file:"+p+"?mode=ro", uri=True); print(c.execute("SELECT COUNT(*) FROM works").fetchone()[0]); c.close()' 2>/dev/null || true)"
if [[ "$corpus_count" =~ ^[0-9]+$ ]] && (( corpus_count >= LITERATURE_CORPUS_MIN_WORKS )); then
  ok "local literature corpus ready: ${corpus_count} works"
else
  failed "local literature corpus unavailable or undersized (got ${corpus_count:-no count}; need >= ${LITERATURE_CORPUS_MIN_WORKS})"
fi

printf '\n== Backend host isolation ==\n'
OLLAMA_PORT="$(env_get OLLAMA_PORT 11434)"
DOCLING_PORT="$(env_get DOCLING_PORT 5001)"
if curl -fsS --max-time 2 "http://localhost:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1; then
  warning "Ollama is published on localhost; default profile should keep it internal (debug profile may be active)"
else
  ok "Ollama is not published to the host"
fi
if curl -fsS --max-time 2 -H "X-Api-Key: ${DOCLING_API_KEY}" "http://localhost:${DOCLING_PORT}/ready" >/dev/null 2>&1; then
  warning "Docling is published on localhost; default profile should keep it internal (debug profile may be active)"
else
  ok "Docling is not published to the host"
fi

printf '\n== Models ==\n'
models=("$CHAT_MODEL" "$KNOWLEDGE_CHAT_MODEL" "$VISION_CHAT_MODEL" "$EMBEDDING_MODEL" "$AGENT_MODEL" "$KNOWLEDGE_AGENT_MODEL" "$VISION_AGENT_MODEL")
for model in "${models[@]}"; do
  if ollama_show "$model"; then ok "model available: $model"; else failed "model unavailable: $model"; fi
done

if (( fail == 0 )); then
  agent_show="$(dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" -H 'Content-Type: application/json' \
    -d "{\"model\":\"${AGENT_MODEL}\"}" http://ollama:11434/api/show 2>/dev/null || true)"
  knowledge_agent_show="$(dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" -H 'Content-Type: application/json' \
    -d "{\"model\":\"${KNOWLEDGE_AGENT_MODEL}\"}" http://ollama:11434/api/show 2>/dev/null || true)"
  vision_agent_show="$(dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" -H 'Content-Type: application/json' \
    -d "{\"model\":\"${VISION_AGENT_MODEL}\"}" http://ollama:11434/api/show 2>/dev/null || true)"
  if grep -Fq 'Local Polyglot Agent' <<<"$agent_show" && grep -Fq 'Local Polyglot Agent' <<<"$knowledge_agent_show" && grep -Fq 'Local Polyglot Agent' <<<"$vision_agent_show"; then
    ok "multilingual, Chinese-conversation, and vision agents contain repository system prompt"
  else
    failed "derived agent system prompt missing"
  fi
fi

router_tags="$(dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" http://model-router:11434/api/tags 2>/dev/null || true)"
if curated_tags_expose_only_public_model \
  "$router_tags" "$AGENT_MODEL" \
  "$KNOWLEDGE_AGENT_MODEL" "$VISION_AGENT_MODEL" "$CHAT_MODEL" "$KNOWLEDGE_CHAT_MODEL" "$VISION_CHAT_MODEL" "$EMBEDDING_MODEL"; then
  ok "Open WebUI model endpoint exposes only $AGENT_MODEL"
else
  failed "curated model endpoint leaked internal model tags"
  printf '       tags: %.500s\n' "$router_tags" >&2
fi

if (( fail == 0 )); then
  printf '\n== Chinese / English / Bokmål / Nynorsk ==\n'
  language_test "Chinese" "只回复 CHINESE_OK，不要添加其他内容。" "CHINESE_OK"
  language_test "English" "Reply with exactly ENGLISH_OK and nothing else." "ENGLISH_OK"
  language_test "Norwegian Bokmål" "Svar kun BOKMAL_OK og ingenting annet." "BOKMAL_OK"
  language_test "Norwegian Nynorsk" "Svar berre NYNORSK_OK og ingenting anna." "NYNORSK_OK"
  text_ps="$(dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" http://ollama:11434/api/ps 2>/dev/null || true)"
  if grep -Fq "$AGENT_MODEL" <<<"$text_ps" && ! grep -Fq "$KNOWLEDGE_AGENT_MODEL" <<<"$text_ps" && ! grep -Fq "$VISION_AGENT_MODEL" <<<"$text_ps"; then
    ok "non-Chinese conversations anchor to multilingual agent: $AGENT_MODEL (base: $CHAT_MODEL)"
  else
    failed "non-Chinese conversation anchor did not leave the multilingual agent loaded (base: $CHAT_MODEL)"
    printf '       /api/ps: %.500s\n' "$text_ps" >&2
  fi

  knowledge_probe="$(dcurl -fsS --max-time "$SMOKE_MODEL_TIMEOUT" -H 'Content-Type: application/json' \
    -d "{\"model\":\"${AGENT_MODEL}\",\"prompt\":\"只回复 ROUTE_OK，不要添加其他内容。\",\"stream\":false,\"options\":{\"temperature\":0,\"num_predict\":24}}" \
    http://model-router:11434/api/generate 2>/dev/null || true)"
  knowledge_ps="$(dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" http://ollama:11434/api/ps 2>/dev/null || true)"
  if [[ -n "$knowledge_probe" ]] && grep -Fq "$KNOWLEDGE_AGENT_MODEL" <<<"$knowledge_ps" && ! grep -Fq "$VISION_AGENT_MODEL" <<<"$knowledge_ps"; then
    ok "Chinese-first conversations anchor to: $KNOWLEDGE_AGENT_MODEL (base: $KNOWLEDGE_CHAT_MODEL)"
  else
    failed "Chinese conversation anchor did not leave the Chinese agent loaded (base: $KNOWLEDGE_CHAT_MODEL)"
    printf '       /api/ps: %.500s\n' "$knowledge_ps" >&2
  fi

  translation_probe="$(dcurl -fsS --max-time "$SMOKE_MODEL_TIMEOUT" -H 'Content-Type: application/json' \
    -d "{\"model\":\"${AGENT_MODEL}\",\"prompt\":\"Translate into English and output only the translation: 你好。\",\"stream\":false,\"think\":false,\"options\":{\"temperature\":0,\"num_predict\":24}}" \
    http://model-router:11434/api/generate 2>/dev/null || true)"
  translation_ps="$(dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" http://ollama:11434/api/ps 2>/dev/null || true)"
  if [[ -n "$translation_probe" ]] && grep -Fq "$AGENT_MODEL" <<<"$translation_ps" && ! grep -Fq "$KNOWLEDGE_AGENT_MODEL" <<<"$translation_ps"; then
    ok "self-contained translation requests bypass to multilingual agent: $AGENT_MODEL (base: $CHAT_MODEL)"
  else
    failed "self-contained translation bypass did not leave the multilingual agent loaded (base: $CHAT_MODEL)"
    printf '       /api/ps: %.500s\n' "$translation_ps" >&2
  fi

  # Context-dependent translation uses a controlled handoff. Explicit numbered
  # sentences are resolved deterministically from prior user text, then the
  # multilingual model translates the exact recovered source. This keeps smoke
  # focused on routing/integration instead of probabilistic resolver quality.
  contextual_payload='{"model":"'"${AGENT_MODEL}"'","messages":[{"role":"user","content":"第一句是天气很好，第二句是我明天去奥斯陆。"},{"role":"assistant","content":"记住了。"},{"role":"user","content":"把第二句翻成英文，只输出译文。"}],"stream":false,"think":false,"options":{"num_predict":48}}'
  # Do not use curl -f here. If the router/upstream returns an HTTP error, keep
  # its JSON body so release diagnostics show the real failure instead of an
  # empty "response:" line.
  contextual_probe="$(printf '%s' "$contextual_payload" | dcurl -sS --max-time "$SMOKE_MODEL_TIMEOUT" \
    -H 'Content-Type: application/json' --data-binary @- http://model-router:11434/api/chat 2>/dev/null || true)"
  contextual_ps="$(dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" http://ollama:11434/api/ps 2>/dev/null || true)"
  if [[ -n "$contextual_probe" ]] && grep -Eq 'Oslo|tomorrow' <<<"$contextual_probe" && grep -Fq "$AGENT_MODEL" <<<"$contextual_ps" && ! grep -Fq "$VISION_AGENT_MODEL" <<<"$contextual_ps"; then
    ok "context-dependent translation resolves exact prior-user source and hands off deterministically to multilingual translation"
  else
    failed "context-dependent translation resolve/translate handoff failed"
    printf '       response: %.500s\n' "$contextual_probe" >&2
    printf '       /api/ps: %.500s\n' "$contextual_ps" >&2
    contextual_router_logs="$(dc logs --tail=40 model-router 2>/dev/null || true)"
    if [[ -n "$contextual_router_logs" ]]; then
      printf '       model-router logs (tail):\n%s\n' "$contextual_router_logs" >&2
    fi
  fi

  # A bare translation command has a recoverable referent but no target language.
  # The lightweight UX guard must ask only for the missing parameter and must not
  # burn a model turn guessing or merely echoing the prior source text.
  ux_guard_payload='{"model":"'"${AGENT_MODEL}"'","messages":[{"role":"user","content":"相看两不厌，唯有敬亭山。"},{"role":"assistant","content":"这是李白《独坐敬亭山》中的诗句。"},{"role":"user","content":"翻译"}],"stream":false}'
  ux_guard_probe="$(printf '%s' "$ux_guard_payload" | dcurl -sS --max-time "$SMOKE_HTTP_TIMEOUT" \
    -H 'Content-Type: application/json' --data-binary @- http://model-router:11434/api/chat 2>/dev/null || true)"
  if grep -Fq '哪种语言' <<<"$ux_guard_probe"; then
    ok "underspecified bare translation asks for the missing target language"
  else
    failed "bare translation UX guard did not ask for a target language"
    printf '       response: %.500s\n' "$ux_guard_probe" >&2
  fi
fi

printf '\n== Local embeddings ==\n'
embed_response="$(dcurl -fsS --max-time "$SMOKE_MODEL_TIMEOUT" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${EMBEDDING_MODEL}\",\"input\":\"中文 English norsk\"}" \
  http://ollama:11434/api/embed 2>/dev/null)" || embed_response=""
if grep -Fq '"embeddings"' <<<"$embed_response"; then ok "embedding inference: $EMBEDDING_MODEL"; else failed "embedding inference failed: $EMBEDDING_MODEL"; fi

printf '\n== Vision ==\n'
if [[ ! -s "$VISION_FIXTURE" ]]; then
  failed "vision fixture missing: $VISION_FIXTURE"
else
  img64="$(base64 <"$VISION_FIXTURE" | tr -d '\r\n')"
  payload="$(printf '{"model":"%s","prompt":"Read the large number in this image. Reply with only the number.","images":["%s"],"stream":false,"think":false,"options":{"temperature":0,"num_predict":32}}' "$AGENT_MODEL" "$img64")"
  # Do not use curl -f here: on an Ollama 4xx/5xx we want the JSON error body
  # in smoke output rather than collapsing it to an uninformative empty string.
  vision_response="$(printf '%s' "$payload" | dcurl -sS --max-time "$SMOKE_MODEL_TIMEOUT" \
    -H 'Content-Type: application/json' --data-binary @- http://model-router:11434/api/generate 2>/dev/null)" || vision_response=""
  if grep -Eq '"response"[[:space:]]*:[[:space:]]*"[^"]*42' <<<"$vision_response"; then
    ok "vision input works through $AGENT_MODEL"
    vision_ps="$(dcurl -fsS --max-time "$SMOKE_HTTP_TIMEOUT" http://ollama:11434/api/ps 2>/dev/null || true)"
    if grep -Fq "$VISION_AGENT_MODEL" <<<"$vision_ps" && ! grep -Fq "$AGENT_MODEL" <<<"$vision_ps" && ! grep -Fq "$KNOWLEDGE_AGENT_MODEL" <<<"$vision_ps"; then
      ok "image requests route to 4B vision agent: $VISION_AGENT_MODEL"
    else
      failed "vision route did not leave the hidden 4B agent loaded"
      printf '       /api/ps: %.500s\n' "$vision_ps" >&2
    fi
  else
    failed "vision inference did not identify fixture marker 42"
    printf '       response: %.500s\n' "$vision_response" >&2
  fi
fi

printf '\n== PDF / Docling ==\n'
docling_response="$(dcurl -fsS --max-time "$SMOKE_DOCLING_TIMEOUT" \
  -X POST http://docling:5001/v1/convert/file \
  -H 'accept: application/json' -H "X-Api-Key: ${DOCLING_API_KEY}" \
  -F 'from_formats=pdf' -F 'to_formats=text' -F 'do_ocr=false' \
  -F "files=@${PDF_FIXTURE};type=application/pdf" 2>/dev/null)" || docling_response=""
if grep -Fq 'POLYGLOT PDF SMOKE 2026' <<<"$docling_response"; then ok "Docling PDF extraction"; else failed "Docling PDF extraction marker missing"; fi

printf '\n== GPU ==\n'
gpu_device=0
if command -v colima >/dev/null 2>&1 && colima status >/dev/null 2>&1; then
  if colima_uses_krunkit; then
    colima ssh -- sudo modprobe virtio_gpu >/dev/null 2>&1 || true
    colima ssh -- sudo udevadm settle >/dev/null 2>&1 || true
  fi
  if colima ssh -- sh -lc 'test -e /dev/dri/renderD128' >/dev/null 2>&1; then gpu_device=1; ok "GPU/DRI device exposed inside Colima VM"; else warning "no /dev/dri/renderD128 detected in Colima VM; CPU fallback active (run make gpu-diagnose)"; fi
else
  warning "Colima not running/detected; GPU bridge check skipped"
fi

container_gpu=0
vulkan_payload=0
if dc -f compose.yaml ps -q ollama | grep -q .; then
  if dc -f compose.yaml exec -T ollama sh -lc 'test -e /dev/dri/renderD128 || test -d /dev/dri' >/dev/null 2>&1; then container_gpu=1; ok "GPU/DRI visible inside Ollama container"; else warning "GPU/DRI not visible inside Ollama container"; fi
  if ollama_container_has_vulkan_runner; then vulkan_payload=1; ok "Ollama Vulkan runner payload is installed"; else warning "Ollama ARM64 container has no Vulkan runner payload"; fi
  ps_output="$(dc -f compose.yaml exec -T ollama ollama ps 2>/dev/null || true)"
  if grep -qi 'GPU' <<<"$ps_output"; then ok "Ollama reports GPU-backed loaded model"; else warning "Ollama did not report GPU in ollama ps"; fi
else
  failed "Ollama container not found"
fi

if [[ "$SMOKE_REQUIRE_GPU" == "1" ]] && (( gpu_device == 0 || container_gpu == 0 || vulkan_payload == 0 )); then failed "SMOKE_REQUIRE_GPU=1 but Apple GPU/Vulkan path is not fully available"; fi

printf '\n== Summary ==\n'
printf 'hard failures: %d; warnings: %d\n' "$fail" "$warn"
if (( fail > 0 )); then
  printf '\nDiagnostics:\n' >&2
  dc -f compose.yaml ps >&2 2>/dev/null || true
  printf '\nOllama logs (tail):\n' >&2
  dc -f compose.yaml logs --tail 60 ollama >&2 2>/dev/null || true
  printf '\nDocling logs (tail):\n' >&2
  dc -f compose.yaml logs --tail 60 docling >&2 2>/dev/null || true
  exit 1
fi
ok "smoke test passed"
