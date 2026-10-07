#!/bin/sh
set -eu

ensure_model() {
  model="$1"
  if [ "${FORCE_MODEL_UPDATE:-0}" = "1" ]; then
    echo "Refreshing model: ${model}"
    ollama pull "${model}"
  elif ollama show "${model}" >/dev/null 2>&1; then
    echo "Model already present: ${model}"
  else
    echo "Pulling model: ${model}"
    ollama pull "${model}"
  fi
}

create_agent_model() {
  target_model="$1"
  base_model="$2"
  prompt_file="${AGENT_PROMPT_FILE:-/config/agent/system-prompt.md}"

  if [ "${target_model}" = "${base_model}" ]; then
    echo "Agent target ${target_model} must differ from its base model ${base_model}." >&2
    exit 1
  fi
  if [ ! -s "$prompt_file" ]; then
    echo "Agent prompt file is missing or empty: $prompt_file" >&2
    exit 1
  fi

  modelfile="$(mktemp)"
  trap 'rm -f "$modelfile"' EXIT INT TERM

  {
    printf 'FROM %s\n' "${base_model}"
    printf 'SYSTEM """\n'
    cat "$prompt_file"
    printf '\n"""\n'
  } >"$modelfile"

  echo "Creating/updating local agent model: ${target_model} (base: ${base_model})"
  ollama create "${target_model}" -f "$modelfile"
  rm -f "$modelfile"
  trap - EXIT INT TERM
}

: "${CHAT_MODEL:=qwen3.5:9b-q4_K_M}"
: "${VISION_CHAT_MODEL:=qwen3-vl:4b-instruct}"
: "${KNOWLEDGE_CHAT_MODEL:=qwen2.5:7b}"
: "${EMBEDDING_MODEL:=bge-m3}"
: "${AGENT_MODEL:=polyglot-agent:latest}"
: "${KNOWLEDGE_AGENT_MODEL:=polyglot-agent-knowledge:latest}"
: "${VISION_AGENT_MODEL:=polyglot-agent-vision:latest}"

if [ "${AGENT_MODEL}" = "${VISION_AGENT_MODEL}" ] || [ "${AGENT_MODEL}" = "${KNOWLEDGE_AGENT_MODEL}" ] || [ "${VISION_AGENT_MODEL}" = "${KNOWLEDGE_AGENT_MODEL}" ]; then
  echo "AGENT_MODEL, KNOWLEDGE_AGENT_MODEL, and VISION_AGENT_MODEL must use distinct tags." >&2
  exit 1
fi

ensure_model "${CHAT_MODEL}"
if [ "${KNOWLEDGE_CHAT_MODEL}" != "${CHAT_MODEL}" ]; then
  ensure_model "${KNOWLEDGE_CHAT_MODEL}"
fi
if [ "${VISION_CHAT_MODEL}" != "${CHAT_MODEL}" ] && [ "${VISION_CHAT_MODEL}" != "${KNOWLEDGE_CHAT_MODEL}" ]; then
  ensure_model "${VISION_CHAT_MODEL}"
fi
ensure_model "${EMBEDDING_MODEL}"
create_agent_model "${AGENT_MODEL}" "${CHAT_MODEL}"
create_agent_model "${KNOWLEDGE_AGENT_MODEL}" "${KNOWLEDGE_CHAT_MODEL}"
create_agent_model "${VISION_AGENT_MODEL}" "${VISION_CHAT_MODEL}"

echo "Models and routed local translation/knowledge/vision agents are ready."
