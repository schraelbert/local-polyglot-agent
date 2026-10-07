#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
work="$tmp/work"
bin="$tmp/bin"
mkdir -p "$work/scripts" "$bin"
cp "$ROOT_DIR/scripts/release-gate.sh" "$ROOT_DIR/scripts/common.sh" "$work/scripts/"

# A stale project setting must not make the default release gate strict.
printf 'SMOKE_REQUIRE_GPU=1\n' > "$work/.env"
printf 'OLLAMA_IMAGE=ollama/ollama:test\n' > "$work/versions.env"
printf '%s\n' \
  'CHAT_MODEL=qwen3.5:9b-q4_K_M' \
  'KNOWLEDGE_CHAT_MODEL=qwen2.5:7b' \
  'TEXT_THINKING_DEFAULT=false' \
  'ROUTER_PROFILE=sticky-conversation' \
  'RUNTIME_MODEL_TIER=standard' > "$work/.runtime.env"

cat > "$bin/docker" <<'SH2'
#!/bin/sh
[ "${1:-}" = info ] && exit 0
exit 0
SH2

cat > "$bin/make" <<'SH2'
#!/bin/sh
printf '%s:%s:%s\n' "${1:-}" "${SMOKE_REQUIRE_GPU:-unset}" "${BENCH_MIN_SCORE:-unset}" >> "$MAKE_CAPTURE"
exit 0
SH2
chmod +x "$bin/docker" "$bin/make"

capture="$tmp/make-capture"
: > "$capture"
(
  cd "$work"
  PATH="$bin:/usr/bin:/bin" MAKE_CAPTURE="$capture" ./scripts/release-gate.sh > "$tmp/default.out"
)
grep -Fq 'supported CPU fallback is allowed' "$tmp/default.out"
grep -Fq 'sticky conversation anchors enabled; Chinese-first anchor qwen2.5:7b; contextual translation uses resolve-then-translate handoff; default hidden thinking disabled' "$tmp/default.out"
grep -Fxq 'smoke-test:0:95' "$capture"
grep -Fxq 'benchmark:0:95' "$capture"
! grep -Eq ':1:' "$capture"

# Both current production tiers are release-eligible.
for tier_model in 'standard|qwen3.5:9b-q4_K_M|qwen2.5:7b' 'high-memory|qwen3:14b|qwen3:14b'; do
  tier="${tier_model%%|*}"
  rest="${tier_model#*|}"
  model="${rest%%|*}"
  knowledge="${rest#*|}"
  printf 'CHAT_MODEL=%s\nKNOWLEDGE_CHAT_MODEL=%s\nTEXT_THINKING_DEFAULT=false\nROUTER_PROFILE=sticky-conversation\nRUNTIME_MODEL_TIER=%s\n' \
    "$model" "$knowledge" "$tier" > "$work/.runtime.env"
  : > "$capture"
  (
    cd "$work"
    PATH="$bin:/usr/bin:/bin" MAKE_CAPTURE="$capture" ./scripts/release-gate.sh > "$tmp/${tier}.out"
  )
  grep -Fq "Release text tier: ${tier} (${model})." "$tmp/${tier}.out"
  grep -Fq "Chinese-first anchor ${knowledge}" "$tmp/${tier}.out"
  grep -Fxq 'benchmark:0:95' "$capture"
done

# Stale/development tiers from earlier RCs must never be certified.
printf '%s\n' \
  'CHAT_MODEL=qwen3:8b' \
  'KNOWLEDGE_CHAT_MODEL=qwen2.5:7b' \
  'TEXT_THINKING_DEFAULT=false' \
  'ROUTER_PROFILE=sticky-conversation' \
  'RUNTIME_MODEL_TIER=low-memory' > "$work/.runtime.env"
: > "$capture"
if (
  cd "$work"
  PATH="$bin:/usr/bin:/bin" MAKE_CAPTURE="$capture" ./scripts/release-gate.sh > "$tmp/low-memory.out" 2>&1
); then
  echo 'release gate unexpectedly certified a stale low-memory runtime tier' >&2
  exit 1
fi
grep -Fq 'refuses non-production text tier low-memory (qwen3:8b)' "$tmp/low-memory.out"
[[ ! -s "$capture" ]]

# Missing/old smart-thinking router metadata is not release-eligible.
printf '%s\n' \
  'CHAT_MODEL=qwen3.5:9b-q4_K_M' \
  'KNOWLEDGE_CHAT_MODEL=qwen2.5:7b' \
  'TEXT_THINKING_DEFAULT=true' \
  'ROUTER_PROFILE=sticky-conversation' \
  'RUNTIME_MODEL_TIER=standard' > "$work/.runtime.env"
: > "$capture"
if (
  cd "$work"
  PATH="$bin:/usr/bin:/bin" MAKE_CAPTURE="$capture" ./scripts/release-gate.sh > "$tmp/think-on.out" 2>&1
); then
  echo 'release gate unexpectedly certified always-on thinking profile' >&2
  exit 1
fi
grep -Fq 'requires direct-by-default sticky conversation routing' "$tmp/think-on.out"
[[ ! -s "$capture" ]]

printf '%s\n' \
  'CHAT_MODEL=qwen3.5:9b-q4_K_M' \
  'KNOWLEDGE_CHAT_MODEL=qwen2.5:7b' \
  'TEXT_THINKING_DEFAULT=false' \
  'ROUTER_PROFILE=legacy' \
  'RUNTIME_MODEL_TIER=standard' > "$work/.runtime.env"
if (
  cd "$work"
  PATH="$bin:/usr/bin:/bin" MAKE_CAPTURE="$capture" ./scripts/release-gate.sh > "$tmp/wrong-profile.out" 2>&1
); then
  echo 'release gate unexpectedly certified legacy router profile' >&2
  exit 1
fi
grep -Fq 'requires sticky conversation routing with a Chinese conversation anchor' "$tmp/wrong-profile.out"

# Restore valid runtime profile for remaining policy tests.
printf '%s\n' \
  'CHAT_MODEL=qwen3.5:9b-q4_K_M' \
  'KNOWLEDGE_CHAT_MODEL=qwen2.5:7b' \
  'TEXT_THINKING_DEFAULT=false' \
  'ROUTER_PROFILE=sticky-conversation' \
  'RUNTIME_MODEL_TIER=standard' > "$work/.runtime.env"

: > "$capture"
(
  cd "$work"
  PATH="$bin:/usr/bin:/bin" MAKE_CAPTURE="$capture" SMOKE_REQUIRE_GPU=1 ./scripts/release-gate.sh > "$tmp/strict.out"
)
grep -Fq 'strict GPU validation is required' "$tmp/strict.out"
grep -Fxq 'smoke-test:1:95' "$capture"

: > "$capture"
(
  cd "$work"
  PATH="$bin:/usr/bin:/bin" MAKE_CAPTURE="$capture" BENCH_MIN_SCORE=98 ./scripts/release-gate.sh > "$tmp/quality98.out"
)
grep -Fq 'overall benchmark >= 98%' "$tmp/quality98.out"
grep -Fxq 'benchmark:0:98' "$capture"

if (
  cd "$work"
  PATH="$bin:/usr/bin:/bin" MAKE_CAPTURE="$capture" BENCH_MIN_SCORE=94 ./scripts/release-gate.sh > "$tmp/quality-low.out" 2>&1
); then
  echo 'release gate unexpectedly allowed BENCH_MIN_SCORE below 95' >&2
  exit 1
fi
grep -Fq 'BENCH_MIN_SCORE must be an integer from 95 to 100' "$tmp/quality-low.out"

if (
  cd "$work"
  PATH="$bin:/usr/bin:/bin" MAKE_CAPTURE="$capture" SMOKE_REQUIRE_GPU=2 ./scripts/release-gate.sh > "$tmp/invalid.out" 2>&1
); then
  echo 'invalid SMOKE_REQUIRE_GPU unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'SMOKE_REQUIRE_GPU must be 0 or 1' "$tmp/invalid.out"

echo 'release gate sticky-conversation/GPU policy regression test passed'
