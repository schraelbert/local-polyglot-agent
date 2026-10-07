#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source scripts/common.sh
require_docker_daemon || exit 1

ensure_secrets() {
  local generated_admin=0

  if [[ ! -f .env ]]; then
    cp .env.example .env
    chmod 600 .env
  fi

  command -v openssl >/dev/null 2>&1 || {
    echo "openssl is required to generate local secrets." >&2
    exit 1
  }

  replace_placeholder() {
    local key="$1" placeholder="$2" min_len="$3" secret
    if grep -q "^${key}=${placeholder}$" .env; then
      secret="$(openssl rand -hex 32)"
      if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "s/^${key}=.*/${key}=${secret}/" .env
      else
        sed -i "s/^${key}=.*/${key}=${secret}/" .env
      fi
      [[ "$key" == "WEBUI_ADMIN_PASSWORD" ]] && generated_admin=1
    fi
    local line value
    line="$(grep -E "^${key}=" .env | tail -n 1 || true)"
    value="${line#*=}"
    if [[ -z "$line" || ${#value} -lt $min_len ]]; then
      echo "${key} is missing or too short in .env." >&2
      exit 1
    fi
  }

  replace_placeholder WEBUI_SECRET_KEY replace-me-with-a-random-secret 32
  replace_placeholder DOCLING_API_KEY replace-me-with-a-random-secret 32
  replace_placeholder WEBUI_ADMIN_PASSWORD replace-me-with-a-random-admin-password 16

  chmod 600 .env

  if (( generated_admin == 1 )); then
    echo "Generated a strong first-run Open WebUI admin password in .env."
  fi
}

ensure_secrets

# Migrate only known historical project defaults. Explicit custom/thinking
# variants remain untouched. The 16 GB production tier now uses Qwen3.5 9B;
# Qwen3 14B is reserved for higher-memory hosts.
legacy_chat_model="$(env_get CHAT_MODEL)"
case "$legacy_chat_model" in
  qwen3-vl:8b|qwen3-vl:8b-instruct|qwen3:14b)
    if [[ "$(uname -s)" == "Darwin" ]]; then
      sed -i '' 's|^CHAT_MODEL=.*$|CHAT_MODEL=qwen3.5:9b-q4_K_M|' .env
    else
      sed -i 's|^CHAT_MODEL=.*$|CHAT_MODEL=qwen3.5:9b-q4_K_M|' .env
    fi
    echo "Migrated legacy CHAT_MODEL=${legacy_chat_model} to qwen3.5:9b-q4_K_M for the 16 GB production tier."
    ;;
esac

legacy_knowledge_model="$(env_get KNOWLEDGE_CHAT_MODEL)"
case "$legacy_knowledge_model" in
  glm4:9b)
    if [[ "$(uname -s)" == "Darwin" ]]; then
      sed -i '' 's|^KNOWLEDGE_CHAT_MODEL=.*$|KNOWLEDGE_CHAT_MODEL=qwen2.5:7b|' .env
    else
      sed -i 's|^KNOWLEDGE_CHAT_MODEL=.*$|KNOWLEDGE_CHAT_MODEL=qwen2.5:7b|' .env
    fi
    echo "Migrated legacy KNOWLEDGE_CHAT_MODEL=${legacy_knowledge_model} to qwen2.5:7b for stronger Chinese factual knowledge and math."
    ;;
esac

# Parse Compose .env safely for user-facing values; do not source it as shell.
[[ -f "$VERSION_LOCK_FILE" ]] || { echo "Version lock not found: $VERSION_LOCK_FILE" >&2; exit 1; }
if grep -Eq '^(OLLAMA_IMAGE|OPEN_WEBUI_IMAGE|DOCLING_IMAGE|MAINTENANCE_IMAGE|SMOKE_IMAGE)=' .env; then
  echo "Note: legacy *_IMAGE entries remain in .env, but tracked ${VERSION_LOCK_FILE} has higher precedence and controls runtime versions."
fi
WEBUI_PORT="$(env_get WEBUI_PORT 3000)"
WEBUI_ADMIN_EMAIL="$(env_get WEBUI_ADMIN_EMAIL admin@local.invalid)"

OLLAMA_IMAGE="$(version_get OLLAMA_IMAGE)"
OPEN_WEBUI_IMAGE="$(version_get OPEN_WEBUI_IMAGE)"
DOCLING_IMAGE="$(version_get DOCLING_IMAGE)"
CPU_CONTEXT_LENGTH="$(ollama_cpu_context_length)"
STANDARD_CHAT_MODEL="$(env_get CHAT_MODEL qwen3.5:9b-q4_K_M)"
STANDARD_KNOWLEDGE_CHAT_MODEL="$(env_get KNOWLEDGE_CHAT_MODEL qwen2.5:7b)"
HIGH_MEMORY_CHAT_MODEL="$(env_get HIGH_MEMORY_CHAT_MODEL qwen3:14b)"
HIGH_MEMORY_KNOWLEDGE_CHAT_MODEL="$(env_get HIGH_MEMORY_KNOWLEDGE_CHAT_MODEL qwen3:14b)"
STANDARD_VM_THRESHOLD_GIB="$(env_get STANDARD_VM_THRESHOLD_GIB 10)"
HIGH_MEMORY_HOST_THRESHOLD_GIB="$(env_get HIGH_MEMORY_HOST_THRESHOLD_GIB 24)"
HIGH_MEMORY_VM_THRESHOLD_GIB="$(env_get HIGH_MEMORY_VM_THRESHOLD_GIB 14)"
# New installs use VISION_CHAT_MODEL. Legacy .env files may still have
# OLLAMA_CPU_CHAT_MODEL; preserve that value as the vision base so upgrades do
# not require manual edits.
VISION_CHAT_MODEL="$(env_get VISION_CHAT_MODEL "$(env_get OLLAMA_CPU_CHAT_MODEL qwen3-vl:4b-instruct)")"
VISION_AGENT_MODEL="$(env_get VISION_AGENT_MODEL polyglot-agent-vision:latest)"
KNOWLEDGE_AGENT_MODEL="$(env_get KNOWLEDGE_AGENT_MODEL polyglot-agent-knowledge:latest)"
AGENT_MODEL="$(env_get AGENT_MODEL polyglot-agent:latest)"
[[ -n "$STANDARD_CHAT_MODEL" ]] || { echo "CHAT_MODEL must not be empty." >&2; exit 1; }
[[ -n "$STANDARD_KNOWLEDGE_CHAT_MODEL" ]] || { echo "KNOWLEDGE_CHAT_MODEL must not be empty." >&2; exit 1; }
[[ -n "$HIGH_MEMORY_CHAT_MODEL" ]] || { echo "HIGH_MEMORY_CHAT_MODEL must not be empty." >&2; exit 1; }
[[ -n "$HIGH_MEMORY_KNOWLEDGE_CHAT_MODEL" ]] || { echo "HIGH_MEMORY_KNOWLEDGE_CHAT_MODEL must not be empty." >&2; exit 1; }
for threshold_name in STANDARD_VM_THRESHOLD_GIB HIGH_MEMORY_HOST_THRESHOLD_GIB HIGH_MEMORY_VM_THRESHOLD_GIB; do
  threshold_value="${!threshold_name}"
  if [[ ! "$threshold_value" =~ ^[0-9]+$ ]] || (( threshold_value < 8 )); then
    echo "${threshold_name} must be an integer >= 8 (got: ${threshold_value})." >&2
    exit 1
  fi
done
if (( HIGH_MEMORY_HOST_THRESHOLD_GIB < STANDARD_VM_THRESHOLD_GIB || HIGH_MEMORY_VM_THRESHOLD_GIB < STANDARD_VM_THRESHOLD_GIB )); then
  echo "High-memory thresholds must not be lower than STANDARD_VM_THRESHOLD_GIB." >&2
  exit 1
fi
[[ -n "$VISION_CHAT_MODEL" ]] || { echo "VISION_CHAT_MODEL must not be empty." >&2; exit 1; }
[[ -n "$VISION_AGENT_MODEL" ]] || { echo "VISION_AGENT_MODEL must not be empty." >&2; exit 1; }
[[ -n "$KNOWLEDGE_AGENT_MODEL" ]] || { echo "KNOWLEDGE_AGENT_MODEL must not be empty." >&2; exit 1; }
if [[ "$AGENT_MODEL" == "$VISION_AGENT_MODEL" || "$AGENT_MODEL" == "$KNOWLEDGE_AGENT_MODEL" || "$VISION_AGENT_MODEL" == "$KNOWLEDGE_AGENT_MODEL" ]]; then
  echo "AGENT_MODEL, KNOWLEDGE_AGENT_MODEL, and VISION_AGENT_MODEL must use distinct tags." >&2
  exit 1
fi
USE_GPU=0

# Check Colima storage before any capability probe or Compose pull can download
# multi-gigabyte images. Missing core images imply fresh/partial provisioning
# and therefore require more temporary working space.
if command -v colima >/dev/null 2>&1 && colima status >/dev/null 2>&1; then
  REQUIRED_FREE_DISK_GIB="$(project_required_free_disk_gib "$OLLAMA_IMAGE" "$OPEN_WEBUI_IMAGE" "$DOCLING_IMAGE")"
  colima_disk_preflight "$REQUIRED_FREE_DISK_GIB" || exit 1
fi

if command -v colima >/dev/null 2>&1 && colima status >/dev/null 2>&1; then
  if colima_uses_krunkit; then
    # Some guest images have virtio_gpu available as a module but do not load it
    # until a consumer probes the device. Loading it is safe and makes the
    # DRI node appear when Krunkit actually attached the virtual GPU.
    colima ssh -- sudo modprobe virtio_gpu >/dev/null 2>&1 || true
    colima ssh -- sudo udevadm settle >/dev/null 2>&1 || true
    if colima ssh -- test -e /dev/dri/renderD128 >/dev/null 2>&1; then
      if ollama_image_has_vulkan_runner "$OLLAMA_IMAGE"; then
        echo "Apple GPU device and Ollama Vulkan runner detected; enabling GPU device mapping."
        USE_GPU=1
      else
        probe_rc=$?
        if (( probe_rc == 2 )); then
          echo "Unable to inspect/pull the pinned Ollama image: ${OLLAMA_IMAGE}" >&2
          exit 1
        fi
        echo "Apple GPU device detected, but ${OLLAMA_IMAGE} has no Vulkan runner for this platform."
        echo "Using CPU-compatible mode instead of mapping an unusable /dev/dri device."
      fi
    else
      echo "Krunkit VM is running, but /dev/dri/renderD128 is absent; using CPU-compatible mode."
      echo "Run 'make gpu-diagnose' for the VM/kernel-level GPU probe."
    fi
  else
    echo "Colima is running without Krunkit; using CPU-compatible mode."
  fi
fi

# Hardware-aware text tiering. A 16 GB Mac should not be forced to reserve nearly
# all host RAM for a 14B model. The standard tier is the newer Qwen3.5 9B Q4_K_M
# (~6.6 GB); Qwen3 14B is selected only when both host and Colima guest memory
# meet the configured high-memory thresholds.
RUNTIME_CHAT_MODEL="$STANDARD_CHAT_MODEL"
RUNTIME_KNOWLEDGE_CHAT_MODEL="$STANDARD_KNOWLEDGE_CHAT_MODEL"
RUNTIME_VISION_CHAT_MODEL="$VISION_CHAT_MODEL"
RUNTIME_MODEL_TIER="standard"
if (( USE_GPU == 1 )); then
  RUNTIME_CONTEXT_LENGTH="$(env_get OLLAMA_CONTEXT_LENGTH 16384)"
else
  RUNTIME_CONTEXT_LENGTH="$CPU_CONTEXT_LENGTH"
fi

HOST_MEMORY_GIB="${HOST_MEMORY_GIB_OVERRIDE:-}"
if [[ -z "$HOST_MEMORY_GIB" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]] && command -v sysctl >/dev/null 2>&1; then
    host_mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
    if [[ "$host_mem_bytes" =~ ^[0-9]+$ ]]; then
      HOST_MEMORY_GIB="$((host_mem_bytes / 1024 / 1024 / 1024))"
    fi
  elif [[ -r /proc/meminfo ]]; then
    host_mem_kib="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    if [[ "$host_mem_kib" =~ ^[0-9]+$ ]]; then
      HOST_MEMORY_GIB="$((host_mem_kib / 1024 / 1024))"
    fi
  fi
fi

VM_MEMORY_GIB="${VM_MEMORY_GIB_OVERRIDE:-}"
if [[ -z "$VM_MEMORY_GIB" ]] && command -v colima >/dev/null 2>&1; then
  vm_mem_kib="$(colima ssh -- awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
  if [[ "$vm_mem_kib" =~ ^[0-9]+$ ]]; then
    # Linux MemTotal is slightly below the memory requested from Colima because
    # the guest/kernel/hypervisor reserve some RAM. Truncating 9.7 GiB to 9
    # incorrectly rejects a VM started with `colima start --memory 10`.
    # Round to the nearest GiB so tier checks track the configured VM class
    # while still rejecting a genuinely 9 GiB guest.
    VM_MEMORY_GIB="$(((vm_mem_kib + 512 * 1024) / 1024 / 1024))"
  fi
fi

if [[ "$VM_MEMORY_GIB" =~ ^[0-9]+$ ]] && (( VM_MEMORY_GIB < STANDARD_VM_THRESHOLD_GIB )); then
  rm -f "$RUNTIME_ENV_FILE"
  printf 'Colima VM RAM is about %d GiB, below the %d GiB minimum for the standard %s tier.\n' \
    "$VM_MEMORY_GIB" "$STANDARD_VM_THRESHOLD_GIB" "$STANDARD_CHAT_MODEL" >&2
  printf 'Increase Colima modestly (for a 16 GB Mac, 10 GiB is a practical target), then rerun make up:\n' >&2
  printf '  colima stop && colima start --vm-type krunkit --memory 10\n' >&2
  exit 1
fi

if [[ "$HOST_MEMORY_GIB" =~ ^[0-9]+$ && "$VM_MEMORY_GIB" =~ ^[0-9]+$ ]] \
   && (( HOST_MEMORY_GIB >= HIGH_MEMORY_HOST_THRESHOLD_GIB && VM_MEMORY_GIB >= HIGH_MEMORY_VM_THRESHOLD_GIB )); then
  RUNTIME_CHAT_MODEL="$HIGH_MEMORY_CHAT_MODEL"
  RUNTIME_KNOWLEDGE_CHAT_MODEL="$HIGH_MEMORY_KNOWLEDGE_CHAT_MODEL"
  RUNTIME_MODEL_TIER="high-memory"
  printf 'High-memory host detected (%d GiB host / %d GiB Colima); selecting %s.\n' \
    "$HOST_MEMORY_GIB" "$VM_MEMORY_GIB" "$RUNTIME_CHAT_MODEL"
else
  if [[ "$HOST_MEMORY_GIB" =~ ^[0-9]+$ ]]; then
    printf 'Host RAM: about %d GiB; using standard 16 GB-class text tier.\n' "$HOST_MEMORY_GIB"
  fi
  if [[ "$VM_MEMORY_GIB" =~ ^[0-9]+$ ]]; then
    printf 'Colima VM RAM: about %d GiB.\n' "$VM_MEMORY_GIB"
  fi
fi

# Persist only capability-selected values, separate from the user's .env
# preferences. Subsequent make check/smoke-test/benchmark invocations use the
# same effective model that model-init used during this make up.
cat >"$RUNTIME_ENV_FILE" <<EOF
CHAT_MODEL=${RUNTIME_CHAT_MODEL}
KNOWLEDGE_CHAT_MODEL=${RUNTIME_KNOWLEDGE_CHAT_MODEL}
VISION_CHAT_MODEL=${RUNTIME_VISION_CHAT_MODEL}
KNOWLEDGE_AGENT_MODEL=${KNOWLEDGE_AGENT_MODEL}
VISION_AGENT_MODEL=${VISION_AGENT_MODEL}
TEXT_THINKING_DEFAULT=false
ROUTER_PROFILE=sticky-conversation
OLLAMA_CONTEXT_LENGTH=${RUNTIME_CONTEXT_LENGTH}
OLLAMA_RUNTIME_GPU=${USE_GPU}
RUNTIME_MODEL_TIER=${RUNTIME_MODEL_TIER}
EOF
chmod 600 "$RUNTIME_ENV_FILE"

COMPOSE=(docker compose --env-file .env --env-file "$RUNTIME_ENV_FILE" --env-file "$VERSION_LOCK_FILE" -f compose.yaml)
echo "Standard multilingual conversation / translation tool model: ${STANDARD_CHAT_MODEL} (CHAT_MODEL)."
echo "Standard Chinese conversation anchor: ${STANDARD_KNOWLEDGE_CHAT_MODEL} (KNOWLEDGE_CHAT_MODEL)."
if [[ "$RUNTIME_MODEL_TIER" == "high-memory" ]]; then
  echo "Runtime multilingual conversation anchor: ${RUNTIME_CHAT_MODEL} (high-memory tier)."
  echo "Runtime Chinese conversation anchor: ${RUNTIME_KNOWLEDGE_CHAT_MODEL} (high-memory tier)."
else
  echo "Runtime multilingual conversation anchor: ${RUNTIME_CHAT_MODEL} (standard tier)."
  echo "Runtime Chinese conversation anchor: ${RUNTIME_KNOWLEDGE_CHAT_MODEL} (standard tier)."
fi
echo "Vision model: ${RUNTIME_VISION_CHAT_MODEL} (VISION_CHAT_MODEL)."
echo "Text routing: sticky conversation mode (Chinese-first conversation -> ${RUNTIME_KNOWLEDGE_CHAT_MODEL}; other text conversation -> ${RUNTIME_CHAT_MODEL}; contextual translation resolves on the anchor, prefers the local exact-text corpus for missing whole works, then hands off to ${RUNTIME_CHAT_MODEL})."
echo "Text thinking default: disabled; full chat history is preserved on conversation routes."
echo "Open WebUI agentic tools: disabled for the curated assistant; File Context/RAG remains available."

# Contextual whole-work translation must not race the first corpus build. Run the
# one-shot provisioner synchronously before (re)loading the Python router. On
# ordinary later starts the revision marker makes this effectively instant and
# network-free. Keeping the named service container also lets wait-ready inspect
# its exit status alongside model-init/docling-model-init.
echo "Ensuring local exact-text literature corpus is ready ..."
"${COMPOSE[@]}" up --no-deps --force-recreate literature-corpus-init

if (( USE_GPU == 1 )); then
  echo "Runtime context: ${RUNTIME_CONTEXT_LENGTH} tokens (accelerated preference)."
  # model-router.py is bind-mounted into a long-running Python process. Docker
  # Compose does not recreate a container merely because the contents of a bind
  # mount changed, so without this explicit recreate `make up` can leave an old
  # router implementation resident in memory after a project upgrade. Recreate
  # only the lightweight router; do not churn Ollama, Docling, or Open WebUI.
  "${COMPOSE[@]}" -f compose.macos-gpu.yaml up -d --no-deps --force-recreate model-router
  "${COMPOSE[@]}" -f compose.macos-gpu.yaml up -d
else
  echo "CPU fallback context: ${RUNTIME_CONTEXT_LENGTH} tokens (OLLAMA_CPU_CONTEXT_LENGTH)."
  # See the GPU branch above: force-reload the bind-mounted Python router so a
  # code upgrade is guaranteed to take effect even when Compose sees no config
  # change for the already-running service.
  "${COMPOSE[@]}" up -d --no-deps --force-recreate model-router
  "${COMPOSE[@]}" up -d
fi

echo
printf 'Open WebUI: http://localhost:%s\n' "$WEBUI_PORT"
printf 'Admin email: %s\n' "$WEBUI_ADMIN_EMAIL"
echo "Admin password is stored only in the local .env file (WEBUI_ADMIN_PASSWORD)."
echo "Ollama and Docling are not published to the macOS host in the default profile."
echo "Use 'make debug-up' only when you intentionally need their localhost APIs/UI."
echo "Model, literature corpus, and Docling artifact provisioning run as one-shot services."
echo "Follow with: docker compose --env-file .env --env-file ${VERSION_LOCK_FILE} -f compose.yaml logs -f model-init literature-corpus-init docling-model-init"
echo "When provisioning finishes, run 'make smoke-test'."
