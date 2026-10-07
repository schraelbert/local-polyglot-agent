#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source scripts/common.sh

public='polyglot-agent:latest'
text='qwen3.5:9b-q4_K_M'
knowledge='qwen2.5:7b'
knowledge_agent='polyglot-agent-knowledge:latest'
vision_base='qwen3-vl:4b-instruct'
vision_agent='polyglot-agent-vision:latest'
embedding='bge-m3'

# This is the exact shape that triggered the release-gate false positive: the
# public model legitimately reports its base parent in metadata. That metadata is
# not a leaked selectable model.
valid='{"models":[{"name":"polyglot-agent:latest","model":"polyglot-agent:latest","size":6600000000,"details":{"parent_model":"qwen3.5:9b-q4_K_M","parameter_size":"9B"}}]}'
curated_tags_expose_only_public_model \
  "$valid" "$public" "$knowledge_agent" "$vision_agent" "$text" "$knowledge" "$vision_base" "$embedding"

# Actual model entries for any internal model must still fail.
leaked='{"models":[{"name":"polyglot-agent:latest","model":"polyglot-agent:latest"},{"name":"qwen3.5:9b-q4_K_M","model":"qwen3.5:9b-q4_K_M"}]}'
if curated_tags_expose_only_public_model \
  "$leaked" "$public" "$knowledge_agent" "$vision_agent" "$text" "$knowledge" "$vision_base" "$embedding"; then
  echo "expected internal model leak to fail" >&2
  exit 1
fi

# A wrong or empty public list must fail as well.
wrong='{"models":[{"name":"other:latest","model":"other:latest"}]}'
if curated_tags_expose_only_public_model \
  "$wrong" "$public" "$knowledge_agent" "$vision_agent" "$text" "$knowledge" "$vision_base" "$embedding"; then
  echo "expected wrong public model to fail" >&2
  exit 1
fi

empty='{"models":[]}'
if curated_tags_expose_only_public_model \
  "$empty" "$public" "$knowledge_agent" "$vision_agent" "$text" "$knowledge" "$vision_base" "$embedding"; then
  echo "expected empty model list to fail" >&2
  exit 1
fi

echo "curated model list test passed"
