#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/common.sh"

ollama='{"response":"ENGLISH_OK","thinking":"do not score this"}'
docling='{"document":{"text_content":"English OCR test\\nCode EN-482\\n奥斯陆 ZH-731"},"status":"success"}'

ofield="$(printf '%s\n' "$ollama" | ollama_generate_response_field)"
grep -Fq 'ENGLISH_OK' <<<"$ofield"
! grep -Fq 'do not score this' <<<"$ofield"

dfield="$(printf '%s\n' "$docling" | docling_text_content_field)"
grep -Fq 'EN-482' <<<"$dfield"
grep -Fq '奥斯陆' <<<"$dfield"

echo 'API response-channel extraction test passed'
