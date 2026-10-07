#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bench="$ROOT_DIR/scripts/benchmark.sh"

# The production gate cannot be weakened below 95%.
grep -Fq 'MIN_SCORE="${BENCH_MIN_SCORE:-95}"' "$bench"
grep -Fq 'MIN_SCORE < 95' "$bench"

# Six language directions x four critical semantic cases = 24.
critical_translation_count="$(grep -c '^translation_case 1 ' "$bench")"
[[ "$critical_translation_count" -eq 24 ]]

# Six language directions x two extended cases = 12.
extended_translation_count="$(grep -c '^translation_case 0 ' "$bench")"
[[ "$extended_translation_count" -eq 12 ]]

# The old Nynorsk regression must require residence semantics, not merely Norway + negation.
grep -Fq 'Nynorsk -> English / residence semantics' "$bench"
grep -Fq "'liv(e|ing)|resid(e|ing)' 'Norway' 'not|don.t|do not|rather than|instead of'" "$bench"
bad='"response":"I am not in Norway."'
! grep -Eiq 'liv(e|ing)|resid(e|ing)' <<<"$bad"

# Seven single-turn/component knowledge regressions remain release-blocking, but
# natural chat quality is no longer inferred from those isolated prompts.
critical_knowledge_count="$(grep -c '^knowledge_case 1 ' "$bench")"
[[ "$critical_knowledge_count" -eq 7 ]]
grep -Fq 'Chinese literature / Wang Wei attribution' "$bench"
grep -Fq 'Unknown fictional manufacturer' "$bench"
grep -Fq 'component knowledge critical:' "$bench"
grep -Fq 'critical component-knowledge failure' "$bench"

# Three sequential E2E dialogue scenarios are separate release blockers. They
# exercise actual assistant outputs across turns, including the real poem
# referent regression that motivated the conversation-architecture reset.
grep -Fq '== Critical E2E multi-turn conversation ==' "$bench"
grep -Fq 'e2e-dialogue-benchmark.py' "$bench"
grep -Fq './scripts/e2e-dialogue-benchmark.py:/app/e2e-dialogue-benchmark.py:ro' "$ROOT_DIR/compose.yaml"
grep -Fq 'E2E dialogue critical:' "$bench"
grep -Fq 'critical E2E dialogue failure' "$bench"
grep -Fq 'poem referent + contextual full-poem translation' "$ROOT_DIR/scripts/e2e-dialogue-benchmark.py"
grep -Fq 'contextual ‘second sentence’ translation' "$ROOT_DIR/scripts/e2e-dialogue-benchmark.py"
grep -Fq 'English sticky cross-turn memory' "$ROOT_DIR/scripts/e2e-dialogue-benchmark.py"

# Whole-work literary translation is a single grounded tool call over the exact
# local corpus source. The E2E gate accepts documented classical textual variants
# instead of adding hidden rewrite loops that overfit one edition.
grep -Fq 'LOCAL_POLYGLOT_LITERARY_DRAFT' "$ROOT_DIR/scripts/model-router.py"
! grep -Fq 'LOCAL_POLYGLOT_LITERARY_REVISION' "$ROOT_DIR/scripts/model-router.py"
! grep -Fq 'literary_draft_issues' "$ROOT_DIR/scripts/model-router.py"
grep -Fq 'long-attested textual variant' "$ROOT_DIR/scripts/e2e-dialogue-benchmark.py"

# Component knowledge still uses a bounded direct answer budget.
grep -Fq 'KNOWLEDGE_CHAT_MODEL="$(effective_env_get KNOWLEDGE_CHAT_MODEL qwen2.5:7b)"' "$bench"
grep -Fq 'KNOWLEDGE_NUM_PREDICT="${BENCH_KNOWLEDGE_NUM_PREDICT:-512}"' "$bench"
grep -Fq 'KNOWLEDGE_NUM_PREDICT < 64' "$bench"
grep -Fq 'KNOWLEDGE_NUM_PREDICT > 1024' "$bench"
grep -Fq 'num_predict\":${KNOWLEDGE_NUM_PREDICT}' "$bench"
grep -Fq 'Conversation routing: sticky first-user-language anchor' "$bench"
grep -Fq 'Component knowledge answer budget: ${KNOWLEDGE_NUM_PREDICT} generated tokens' "$bench"

# Translation stays deterministic and explicitly non-thinking.
grep -Fq '\"think\":false' < <(sed -n '/translation_case()/,/knowledge_case()/p' "$bench")

# Anti-hallucination scoring accepts semantically correct statements that a
# user-invented manufacturer does not exist, without requiring one stock phrase.
grep -Fq '没有现实世界' "$bench"
grep -Fq '不存在' "$bench"

# OCR and vision are release-blocking critical categories.
grep -Fq 'OCR critical:' "$bench"
grep -Fq 'vision critical:' "$bench"
grep -Fq 'critical translation semantic failure' "$bench"
grep -Fq 'critical OCR failure' "$bench"
grep -Fq 'critical vision failure' "$bench"

# The agent prompt itself prioritizes fidelity over fluent semantic weakening.
grep -Fq 'semantic fidelity is a hard constraint' "$ROOT_DIR/config/agent/system-prompt.md"
grep -Fq 'Norwegian `bor` / Nynorsk `bur` means **live/reside**' "$ROOT_DIR/config/agent/system-prompt.md"
grep -Fq 'Proper nouns and named entities are fidelity-critical' "$ROOT_DIR/config/agent/system-prompt.md"
grep -Fq 'Bergen` may be rendered as `Bergen` or the established Simplified Chinese `卑尔根`' "$ROOT_DIR/config/agent/system-prompt.md"
grep -Fq 'Do not invent quotations, poem lines, titles, authors' "$ROOT_DIR/config/agent/system-prompt.md"
grep -Fq 're-evaluate the claim itself' "$ROOT_DIR/config/agent/system-prompt.md"
grep -Fq "separately verify author and work title" "$ROOT_DIR/config/agent/system-prompt.md"

grep -Fq 'resolve anaphora and references such as' "$ROOT_DIR/config/agent/system-prompt.md"
grep -Fq 'Do not ask the user to repeat content that is already recoverable from the current conversation' "$ROOT_DIR/config/agent/system-prompt.md"
echo 'production benchmark policy regression test passed'
