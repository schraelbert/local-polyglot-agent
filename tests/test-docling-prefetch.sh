#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
grep -q 'user: "0"' compose.yaml
grep -q 'BAKED_ARTIFACTS_DIR=' scripts/prefetch-docling.sh
grep -q 'cp -a .*BAKED_ARTIFACTS_DIR' scripts/prefetch-docling.sh
grep -q -- '--rapidocr-backend-lang onnxruntime:ch' scripts/prefetch-docling.sh
grep -q -- '--rapidocr-backend-lang onnxruntime:en' scripts/prefetch-docling.sh
grep -q -- '--rapidocr-backend-lang onnxruntime:no' scripts/prefetch-docling.sh
grep -q 'services=(model-init literature-corpus-init docling-model-init)' scripts/wait-ready.sh
grep -q '^DOCLING_PREFETCH_REV=3$' .env.example
grep -q 'DOCLING_PREFETCH_REV: ${DOCLING_PREFETCH_REV:-3}' compose.yaml
grep -q 'REV="${DOCLING_PREFETCH_REV:-3}"' scripts/prefetch-docling.sh
echo 'Docling prefetch/wait-ready regression checks passed.'
