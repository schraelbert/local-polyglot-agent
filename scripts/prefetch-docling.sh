#!/bin/sh
set -eu

ARTIFACTS_DIR="/artifacts"
BAKED_ARTIFACTS_DIR="${DOCLING_BAKED_ARTIFACTS_DIR:-/opt/app-root/src/.cache/docling/models}"
REV="${DOCLING_PREFETCH_REV:-3}"
MARKER="${ARTIFACTS_DIR}/.local-polyglot-prefetch-${REV}"

mkdir -p "$ARTIFACTS_DIR"

if [ "${FORCE_DOCLING_MODEL_UPDATE:-0}" != "1" ] && [ -f "$MARKER" ]; then
  echo "Docling artifacts already prefetched for revision ${REV}."
  exit 0
fi

command -v docling-tools >/dev/null 2>&1 || {
  echo "docling-tools is not available in the configured Docling image." >&2
  exit 1
}

# docling-serve's published image already contains its standard layout/table/
# OCR model set. Seed our persistent volume from those baked artifacts instead
# of downloading the same multi-GB assets again. This also makes first boot
# less dependent on external model registries.
if [ -d "$BAKED_ARTIFACTS_DIR" ]; then
  echo "Seeding persistent Docling artifacts from the upstream image..."
  # Copy contents, including dotfiles, without deleting any existing artifacts.
  cp -a "$BAKED_ARTIFACTS_DIR"/. "$ARTIFACTS_DIR"/
else
  echo "Upstream baked artifact directory not found; downloading Docling defaults..."
  docling-tools models download --output-dir "$ARTIFACTS_DIR"
fi

# RapidOCR runs one recognition language/model per conversion. Explicitly cache
# the three model sets used by this project's scanned-document benchmark so
# Chinese, English and Norwegian can work offline. The official Docling CLI
# accepts repeated backend:language pairs here.
echo "Prefetching RapidOCR Chinese, English, and Norwegian recognition artifacts..."
docling-tools models download rapidocr \
  --rapidocr-backend-lang onnxruntime:ch \
  --rapidocr-backend-lang onnxruntime:en \
  --rapidocr-backend-lang onnxruntime:no \
  --output-dir "$ARTIFACTS_DIR"

# Make the persistent cache readable/traversable by the non-root Docling runtime
# user while keeping write access restricted to the owner/group where possible.
chmod -R a+rX "$ARTIFACTS_DIR"

# Replace older project markers only after seeding/downloads complete.
rm -f "${ARTIFACTS_DIR}"/.local-polyglot-prefetch-* 2>/dev/null || true
printf '%s\n' "prefetch_rev=${REV}" > "$MARKER"
printf '%s\n' "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$MARKER"
chmod a+r "$MARKER"

echo "Docling artifacts are ready for offline processing."
