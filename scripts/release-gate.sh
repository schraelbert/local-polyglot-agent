#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source scripts/common.sh

require_docker_daemon || exit 1

# Release policy: CPU fallback is a supported Apple Silicon runtime when the
# pinned Linux/ARM64 Ollama image lacks a Vulkan runner.  Do not let a stale
# SMOKE_REQUIRE_GPU value in .env accidentally turn the normal release gate
# into an impossible GPU gate.  GPU strictness is opt-in from the invoking
# process, e.g. `SMOKE_REQUIRE_GPU=1 make release-gate`.
if [[ "${SMOKE_REQUIRE_GPU+x}" != x ]]; then
  export SMOKE_REQUIRE_GPU=0
fi
case "$SMOKE_REQUIRE_GPU" in
  0)
    printf 'Release GPU policy: supported CPU fallback is allowed.\n'
    printf 'Use SMOKE_REQUIRE_GPU=1 make release-gate for strict GPU validation.\n'
    ;;
  1)
    printf 'Release GPU policy: strict GPU validation is required.\n'
    ;;
  *)
    printf 'SMOKE_REQUIRE_GPU must be 0 or 1 for the release gate (got: %s).\n' "$SMOKE_REQUIRE_GPU" >&2
    exit 2
    ;;
esac

# Production release policy: the aggregate benchmark must be at least 95%, and
# benchmark.sh separately requires 100% of all critical translation,
# component-knowledge, end-to-end dialogue, OCR, and vision cases.  Callers may raise the aggregate bar, but may not lower it.
if [[ "${BENCH_MIN_SCORE+x}" != x ]]; then
  export BENCH_MIN_SCORE=95
fi
if [[ ! "$BENCH_MIN_SCORE" =~ ^[0-9]+$ ]] || (( BENCH_MIN_SCORE < 95 || BENCH_MIN_SCORE > 100 )); then
  printf 'BENCH_MIN_SCORE must be an integer from 95 to 100 for the release gate (got: %s).\n' "$BENCH_MIN_SCORE" >&2
  exit 2
fi
printf 'Release quality policy: translation + component knowledge + E2E dialogue + OCR + vision critical cases must all pass; overall benchmark >= %s%%.\n' "$BENCH_MIN_SCORE"

# Production conversation policy: natural text turns use a sticky anchor selected
# from the first substantive user turn. The router must not reclassify each
# follow-up into a different conversational model. Translation is a controlled
# tool exception: self-contained requests bypass directly, while contextual
# translation first resolves its source through the sticky anchor and then hands
# the resolved source to the multilingual translator. Images may also bypass.
# Deep thinking remains opt-in.
if [[ ! -f "$RUNTIME_ENV_FILE" ]]; then
  printf 'Release gate requires runtime routing metadata; rerun make up.\n' >&2
  exit 2
fi
router_profile="$(awk -F= '$1 == "ROUTER_PROFILE" {print substr($0, index($0, "=") + 1)}' "$RUNTIME_ENV_FILE" | tail -n 1)"
runtime_chinese_anchor="$(awk -F= '$1 == "KNOWLEDGE_CHAT_MODEL" {print substr($0, index($0, "=") + 1)}' "$RUNTIME_ENV_FILE" | tail -n 1)"
runtime_thinking_default="$(awk -F= '$1 == "TEXT_THINKING_DEFAULT" {print substr($0, index($0, "=") + 1)}' "$RUNTIME_ENV_FILE" | tail -n 1)"
if [[ "$router_profile" != "sticky-conversation" || -z "$runtime_chinese_anchor" ]]; then
  printf 'Release gate requires sticky conversation routing with a Chinese conversation anchor; rerun make up with the current profile.\n' >&2
  exit 2
fi
case "$(printf '%s' "$runtime_thinking_default" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) ;;
  *)
    printf 'Release gate requires direct-by-default sticky conversation routing (TEXT_THINKING_DEFAULT=false); rerun make up.\n' >&2
    exit 2
    ;;
esac
printf 'Release text routing policy: sticky conversation anchors enabled; Chinese-first anchor %s; contextual translation uses resolve-then-translate handoff; default hidden thinking disabled.\n' "$runtime_chinese_anchor"
printf 'Release exact-source policy: local literature corpus must be provisioned and healthy for contextual whole-work translation.\n'

# Production text tiers are hardware-aware. The standard 16 GB-class tier and
# the high-memory 14B tier are both release-eligible, but stale/development
# runtime tiers from earlier RCs are not.
if [[ -f "$RUNTIME_ENV_FILE" ]]; then
  runtime_tier="$(awk -F= '$1 == "RUNTIME_MODEL_TIER" {print substr($0, index($0, "=") + 1)}' "$RUNTIME_ENV_FILE" | tail -n 1)"
  runtime_model="$(awk -F= '$1 == "CHAT_MODEL" {print substr($0, index($0, "=") + 1)}' "$RUNTIME_ENV_FILE" | tail -n 1)"
  case "$runtime_tier" in
    standard|high-memory)
      printf 'Release text tier: %s (%s).\n' "$runtime_tier" "${runtime_model:-unknown}"
      ;;
    "")
      printf 'Release gate could not determine RUNTIME_MODEL_TIER; rerun make up.\n' >&2
      exit 2
      ;;
    *)
      printf 'Release gate refuses non-production text tier %s (%s).\n' "$runtime_tier" "${runtime_model:-unknown}" >&2
      printf 'Rerun make up with the current hardware-aware model policy.\n' >&2
      exit 2
      ;;
  esac
fi

steps=(wait-ready check smoke-test benchmark backup)
for step in "${steps[@]}"; do
  printf '\n===== make %s =====\n' "$step"
  make "$step"
done

printf '\nRelease gate completed successfully.\n'
