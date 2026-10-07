#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/common.sh"

thinking_only='{"model":"polyglot-agent:latest","response":"","thinking":"ENGLISH_OK Oslo ikke 星期五 09:15"}'
answer='{"model":"polyglot-agent:latest","response":"ENGLISH_OK Oslo ikke 星期五 09:15","thinking":"irrelevant"}'
escaped='{"response":"He said \"Oslo\" at 09:15.","thinking":""}'

field="$(printf '%s\n' "$thinking_only" | ollama_generate_response_field)"
[[ "$field" == '"response":""' ]]
! grep -Fq 'ENGLISH_OK' <<<"$field"

field="$(printf '%s\n' "$answer" | ollama_generate_response_field)"
grep -Fq 'ENGLISH_OK' <<<"$field"
grep -Fq '星期五' <<<"$field"

field="$(printf '%s\n' "$escaped" | ollama_generate_response_field)"
grep -Fq '09:15' <<<"$field"


# Smoke protocol markers are case-insensitive but must occupy the entire
# response value. This prevents harmless casing drift from blocking a release
# without allowing extra prose to masquerade as a valid sentinel.
mixed_case='{"response":"Nynorsk_ok","thinking":""}'
field="$(printf '%s\n' "$mixed_case" | ollama_generate_response_field)"
ollama_response_is_exact_marker_ci "$field" "NYNORSK_OK"

# Some local models may prepend/append harmless whitespace around an otherwise exact smoke
# sentinel. JSON escapes remain literal in the extracted response token.
leading_newline='{"response":"\nCHINESE_OK","thinking":""}'
field="$(printf '%s\n' "$leading_newline" | ollama_generate_response_field)"
ollama_response_is_exact_marker_ci "$field" "CHINESE_OK"

wrapped_whitespace='{"response":" \tENGLISH_OK\r\n ","thinking":""}'
field="$(printf '%s\n' "$wrapped_whitespace" | ollama_generate_response_field)"
ollama_response_is_exact_marker_ci "$field" "ENGLISH_OK"

embedded_newline='{"response":"CHINESE_\nOK","thinking":""}'
field="$(printf '%s\n' "$embedded_newline" | ollama_generate_response_field)"
! ollama_response_is_exact_marker_ci "$field" "CHINESE_OK"

extra_text='{"response":"Nynorsk_ok maybe","thinking":""}'
field="$(printf '%s\n' "$extra_text" | ollama_generate_response_field)"
! ollama_response_is_exact_marker_ci "$field" "NYNORSK_OK"

prefixed='{"response":"prefix_NYNORSK_OK","thinking":""}'
field="$(printf '%s\n' "$prefixed" | ollama_generate_response_field)"
! ollama_response_is_exact_marker_ci "$field" "NYNORSK_OK"

echo 'Ollama response-channel extraction test passed'
