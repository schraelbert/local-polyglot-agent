#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
work="$tmp/work"
bin="$tmp/bin"
mkdir -p "$work/scripts" "$bin"
cp "$ROOT_DIR/scripts/up.sh" "$ROOT_DIR/scripts/common.sh" "$work/scripts/"
cp "$ROOT_DIR/.env.example" "$ROOT_DIR/versions.env" "$ROOT_DIR/compose.yaml" "$ROOT_DIR/compose.macos-gpu.yaml" "$work/"
cp "$work/.env.example" "$work/.env"
sed -i 's/^WEBUI_SECRET_KEY=.*/WEBUI_SECRET_KEY=0123456789abcdef0123456789abcdef/' "$work/.env"
sed -i 's/^DOCLING_API_KEY=.*/DOCLING_API_KEY=0123456789abcdef0123456789abcdef/' "$work/.env"
sed -i 's/^WEBUI_ADMIN_PASSWORD=.*/WEBUI_ADMIN_PASSWORD=0123456789abcdef0123456789abcdef/' "$work/.env"

cat > "$bin/colima" <<'SH2'
#!/bin/sh
if [ "${1:-}" = status ]; then
  echo 'INFO[0000] colima is running using Krunkit' >&2
  exit 0
fi
if [ "${1:-}" = ssh ]; then
  case "$*" in
    *MemTotal*)
      [ -n "${FAKE_VM_MEM_KIB:-}" ] && printf '%s\n' "$FAKE_VM_MEM_KIB"
      ;;
  esac
  exit 0
fi
exit 1
SH2

cat > "$bin/docker" <<'SH2'
#!/bin/sh
case "${1:-}" in
  info) exit 0 ;;
  image)
    [ "${2:-}" = inspect ] && exit 0
    ;;
  pull) exit 0 ;;
  run)
    [ "${FAKE_VULKAN_PRESENT:-0}" = 1 ] && exit 0
    exit 1
    ;;
  compose)
    printf 'args=' >> "$DOCKER_CAPTURE"
    printf '%s ' "$@" >> "$DOCKER_CAPTURE"
    printf '\n' >> "$DOCKER_CAPTURE"
    exit 0
    ;;
esac
exit 0
SH2
chmod +x "$bin/colima" "$bin/docker"

capture="$tmp/docker-capture"
: > "$capture"

# A 16 GB host with a 10 GiB Colima guest uses the standard Qwen3.5 9B tier.
(
  cd "$work"
  PATH="$bin:/usr/bin:/bin" DOCKER_CAPTURE="$capture" FAKE_VULKAN_PRESENT=0 \
    HOST_MEMORY_GIB_OVERRIDE=16 VM_MEMORY_GIB_OVERRIDE=10 ./scripts/up.sh > "$tmp/standard.out"
)
grep -Fq 'has no Vulkan runner' "$tmp/standard.out"
grep -Fq 'Host RAM: about 16 GiB; using standard 16 GB-class text tier.' "$tmp/standard.out"
grep -Fq 'Colima VM RAM: about 10 GiB.' "$tmp/standard.out"
grep -Fq 'Standard multilingual conversation / translation tool model: qwen3.5:9b-q4_K_M' "$tmp/standard.out"
grep -Fq 'Standard Chinese conversation anchor: qwen2.5:7b' "$tmp/standard.out"
grep -Fq 'Runtime multilingual conversation anchor: qwen3.5:9b-q4_K_M (standard tier).' "$tmp/standard.out"
grep -Fq 'Runtime Chinese conversation anchor: qwen2.5:7b (standard tier).' "$tmp/standard.out"
grep -Fq 'Text routing: sticky conversation mode' "$tmp/standard.out"
grep -Fq 'Vision model: qwen3-vl:4b-instruct' "$tmp/standard.out"
grep -Fq 'CPU fallback context: 4096 tokens' "$tmp/standard.out"
grep -Fxq 'CHAT_MODEL=qwen3.5:9b-q4_K_M' "$work/.runtime.env"
grep -Fxq 'KNOWLEDGE_CHAT_MODEL=qwen2.5:7b' "$work/.runtime.env"
grep -Fxq 'KNOWLEDGE_AGENT_MODEL=polyglot-agent-knowledge:latest' "$work/.runtime.env"
grep -Fxq 'TEXT_THINKING_DEFAULT=false' "$work/.runtime.env"
grep -Fxq 'ROUTER_PROFILE=sticky-conversation' "$work/.runtime.env"
grep -Fxq 'RUNTIME_MODEL_TIER=standard' "$work/.runtime.env"
grep -Fxq 'VISION_CHAT_MODEL=qwen3-vl:4b-instruct' "$work/.runtime.env"
grep -Fxq 'OLLAMA_CONTEXT_LENGTH=4096' "$work/.runtime.env"
grep -Fq -- '--env-file .runtime.env' "$capture"
! grep -Fq 'compose.macos-gpu.yaml' "$capture"
# A bind-mounted Python router must be recreated on every make up so upgraded
# routing code is actually imported by the long-running interpreter.
grep -Fq -- 'up -d --no-deps --force-recreate model-router' "$capture"

# A VM requested as 10 GiB commonly exposes slightly less than 10 GiB through
# Linux MemTotal. The real probe must round that value instead of truncating it
# to 9 and rejecting a correctly configured `colima start --memory 10` VM.
: > "$capture"
(
  cd "$work"
  PATH="$bin:/usr/bin:/bin" DOCKER_CAPTURE="$capture" FAKE_VULKAN_PRESENT=0 \
    HOST_MEMORY_GIB_OVERRIDE=16 FAKE_VM_MEM_KIB=10100000 ./scripts/up.sh > "$tmp/rounded-standard.out"
)
grep -Fq 'Colima VM RAM: about 10 GiB.' "$tmp/rounded-standard.out"
grep -Fq 'Runtime multilingual conversation anchor: qwen3.5:9b-q4_K_M (standard tier).' "$tmp/rounded-standard.out"
grep -Fq 'Runtime Chinese conversation anchor: qwen2.5:7b (standard tier).' "$tmp/rounded-standard.out"
grep -Fxq 'RUNTIME_MODEL_TIER=standard' "$work/.runtime.env"

# A 9 GiB guest is rejected rather than silently falling back to the old 8B tier.
: > "$capture"
if (
  cd "$work"
  PATH="$bin:/usr/bin:/bin" DOCKER_CAPTURE="$capture" FAKE_VULKAN_PRESENT=0 \
    HOST_MEMORY_GIB_OVERRIDE=16 VM_MEMORY_GIB_OVERRIDE=9 ./scripts/up.sh > "$tmp/undersized.out" 2>&1
); then
  echo 'production make up unexpectedly accepted a 9 GiB VM' >&2
  exit 1
fi
grep -Fq 'below the 10 GiB minimum for the standard qwen3.5:9b-q4_K_M tier' "$tmp/undersized.out"
grep -Fq 'colima stop && colima start --vm-type krunkit --memory 10' "$tmp/undersized.out"
[[ ! -f "$work/.runtime.env" ]]

# A 24 GB+ host with a sufficiently large VM automatically uses the 14B tier.
: > "$capture"
(
  cd "$work"
  PATH="$bin:/usr/bin:/bin" DOCKER_CAPTURE="$capture" FAKE_VULKAN_PRESENT=0 \
    HOST_MEMORY_GIB_OVERRIDE=32 VM_MEMORY_GIB_OVERRIDE=16 ./scripts/up.sh > "$tmp/high.out"
)
grep -Fq 'High-memory host detected (32 GiB host / 16 GiB Colima); selecting qwen3:14b.' "$tmp/high.out"
grep -Fq 'Runtime multilingual conversation anchor: qwen3:14b (high-memory tier).' "$tmp/high.out"
grep -Fq 'Runtime Chinese conversation anchor: qwen3:14b (high-memory tier).' "$tmp/high.out"
grep -Fxq 'CHAT_MODEL=qwen3:14b' "$work/.runtime.env"
grep -Fxq 'KNOWLEDGE_CHAT_MODEL=qwen3:14b' "$work/.runtime.env"
grep -Fxq 'RUNTIME_MODEL_TIER=high-memory' "$work/.runtime.env"

# The same rounding applies to the high-memory threshold: a VM requested as
# 14 GiB may expose roughly 13.6-13.9 GiB as MemTotal and should still qualify.
: > "$capture"
(
  cd "$work"
  PATH="$bin:/usr/bin:/bin" DOCKER_CAPTURE="$capture" FAKE_VULKAN_PRESENT=0 \
    HOST_MEMORY_GIB_OVERRIDE=32 FAKE_VM_MEM_KIB=14300000 ./scripts/up.sh > "$tmp/rounded-high.out"
)
grep -Fq 'High-memory host detected (32 GiB host / 14 GiB Colima); selecting qwen3:14b.' "$tmp/rounded-high.out"
grep -Fxq 'RUNTIME_MODEL_TIER=high-memory' "$work/.runtime.env"

# A 16 GB host stays on the standard tier even if the VM is unusually large.
: > "$capture"
(
  cd "$work"
  PATH="$bin:/usr/bin:/bin" DOCKER_CAPTURE="$capture" FAKE_VULKAN_PRESENT=0 \
    HOST_MEMORY_GIB_OVERRIDE=16 VM_MEMORY_GIB_OVERRIDE=14 ./scripts/up.sh > "$tmp/host16.out"
)
grep -Fq 'Runtime multilingual conversation anchor: qwen3.5:9b-q4_K_M (standard tier).' "$tmp/host16.out"
grep -Fq 'Runtime Chinese conversation anchor: qwen2.5:7b (standard tier).' "$tmp/host16.out"
grep -Fxq 'RUNTIME_MODEL_TIER=standard' "$work/.runtime.env"

# Legacy .env files used OLLAMA_CPU_CHAT_MODEL instead of VISION_CHAT_MODEL.
sed -i '/^VISION_CHAT_MODEL=/d' "$work/.env"
printf '\nOLLAMA_CPU_CHAT_MODEL=qwen3-vl:2b-instruct\n' >> "$work/.env"
: > "$capture"
(
  cd "$work"
  PATH="$bin:/usr/bin:/bin" DOCKER_CAPTURE="$capture" FAKE_VULKAN_PRESENT=0 \
    HOST_MEMORY_GIB_OVERRIDE=16 VM_MEMORY_GIB_OVERRIDE=10 ./scripts/up.sh > "$tmp/legacy-vision.out"
)
grep -Fq 'Vision model: qwen3-vl:2b-instruct' "$tmp/legacy-vision.out"
grep -Fxq 'VISION_CHAT_MODEL=qwen3-vl:2b-instruct' "$work/.runtime.env"
sed -i '/^OLLAMA_CPU_CHAT_MODEL=/d' "$work/.env"
printf '\nVISION_CHAT_MODEL=qwen3-vl:4b-instruct\n' >> "$work/.env"

# Known older project defaults migrate to the new standard tier.
for legacy in qwen3-vl:8b qwen3-vl:8b-instruct qwen3:14b; do
  sed -i "s|^CHAT_MODEL=.*$|CHAT_MODEL=${legacy}|" "$work/.env"
  : > "$capture"
  (
    cd "$work"
    PATH="$bin:/usr/bin:/bin" DOCKER_CAPTURE="$capture" FAKE_VULKAN_PRESENT=0 \
      HOST_MEMORY_GIB_OVERRIDE=16 VM_MEMORY_GIB_OVERRIDE=10 ./scripts/up.sh > "$tmp/migrate.out"
  )
  grep -Fq "Migrated legacy CHAT_MODEL=${legacy} to qwen3.5:9b-q4_K_M" "$tmp/migrate.out"
  grep -Fxq 'CHAT_MODEL=qwen3.5:9b-q4_K_M' "$work/.env"
done

# The previous expert-router default migrates from GLM-4 9B to Qwen2.5 7B.
sed -i 's/^KNOWLEDGE_CHAT_MODEL=.*/KNOWLEDGE_CHAT_MODEL=glm4:9b/' "$work/.env"
: > "$capture"
(
  cd "$work"
  PATH="$bin:/usr/bin:/bin" DOCKER_CAPTURE="$capture" FAKE_VULKAN_PRESENT=0 \
    HOST_MEMORY_GIB_OVERRIDE=16 VM_MEMORY_GIB_OVERRIDE=10 ./scripts/up.sh > "$tmp/migrate-knowledge.out"
)
grep -Fq 'Migrated legacy KNOWLEDGE_CHAT_MODEL=glm4:9b to qwen2.5:7b' "$tmp/migrate-knowledge.out"
grep -Fxq 'KNOWLEDGE_CHAT_MODEL=qwen2.5:7b' "$work/.env"

# Explicit thinking/custom selection remains untouched by migration.
sed -i 's/^CHAT_MODEL=.*/CHAT_MODEL=qwen3-vl:8b-thinking/' "$work/.env"
: > "$capture"
(
  cd "$work"
  PATH="$bin:/usr/bin:/bin" DOCKER_CAPTURE="$capture" FAKE_VULKAN_PRESENT=0 \
    HOST_MEMORY_GIB_OVERRIDE=16 VM_MEMORY_GIB_OVERRIDE=10 ./scripts/up.sh > "$tmp/explicit-thinking.out"
)
! grep -Fq 'Migrated legacy CHAT_MODEL' "$tmp/explicit-thinking.out"
grep -Fxq 'CHAT_MODEL=qwen3-vl:8b-thinking' "$work/.env"

# Restore project standard and verify a usable GPU still selects the standard
# tier on a 16 GB host while enabling the GPU Compose override.
sed -i 's/^CHAT_MODEL=.*/CHAT_MODEL=qwen3.5:9b-q4_K_M/' "$work/.env"
: > "$capture"
(
  cd "$work"
  PATH="$bin:/usr/bin:/bin" DOCKER_CAPTURE="$capture" FAKE_VULKAN_PRESENT=1 \
    HOST_MEMORY_GIB_OVERRIDE=16 VM_MEMORY_GIB_OVERRIDE=10 ./scripts/up.sh > "$tmp/gpu.out"
)
grep -Fq 'Ollama Vulkan runner detected' "$tmp/gpu.out"
grep -Fq 'compose.macos-gpu.yaml' "$capture"
grep -Fq -- 'up -d --no-deps --force-recreate model-router' "$capture"
grep -Fxq 'CHAT_MODEL=qwen3.5:9b-q4_K_M' "$work/.runtime.env"
grep -Fxq 'KNOWLEDGE_CHAT_MODEL=qwen2.5:7b' "$work/.runtime.env"
grep -Fxq 'KNOWLEDGE_AGENT_MODEL=polyglot-agent-knowledge:latest' "$work/.runtime.env"
grep -Fxq 'TEXT_THINKING_DEFAULT=false' "$work/.runtime.env"
grep -Fxq 'ROUTER_PROFILE=sticky-conversation' "$work/.runtime.env"
grep -Fxq 'RUNTIME_MODEL_TIER=standard' "$work/.runtime.env"
grep -Fxq 'OLLAMA_RUNTIME_GPU=1' "$work/.runtime.env"

echo 'up.sh hardware-tier routing test passed'
