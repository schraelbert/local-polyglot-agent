#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

checksum_bundle() {
  local dir="$1"
  local files=(volumes.tar.gz env manifest.txt)
  [[ -f "$dir/versions.env" ]] && files+=(versions.env)
  [[ -f "$dir/versions.running.env" ]] && files+=(versions.running.env)
  if command -v shasum >/dev/null 2>&1; then
    (cd "$dir" && shasum -a 256 "${files[@]}" > SHA256SUMS)
  else
    (cd "$dir" && sha256sum "${files[@]}" > SHA256SUMS)
  fi
}

make_v1_bundle() {
  local name="$1" top="$2"
  mkdir -p "$work/$name/src/$top" "$work/$name/bundle"
  printf 'fixture\n' > "$work/$name/src/$top/file.txt"
  tar -C "$work/$name/src" -czf "$work/$name/bundle/volumes.tar.gz" "$top"
  cat > "$work/$name/bundle/manifest.txt" <<MANIFEST
format=local-polyglot-agent-backup-v1
kind=user-data
archive=volumes.tar.gz
MANIFEST
  printf 'WEBUI_SECRET_KEY=test-only\n' > "$work/$name/bundle/env"
  checksum_bundle "$work/$name/bundle"
}

make_v1_bundle unexpected evil
set +e
BACKUP="$work/unexpected/bundle" RESTORE_CONFIRM=RESTORE RESTORE_ALLOW_VERSION_MISMATCH=1 ./scripts/restore.sh >"$work/unexpected.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -q 'Unexpected path in backup archive' "$work/unexpected.out"

make_v1_bundle corrupt open-webui
printf 'corruption' >> "$work/corrupt/bundle/volumes.tar.gz"
set +e
BACKUP="$work/corrupt/bundle" RESTORE_CONFIRM=RESTORE ./scripts/restore.sh >"$work/corrupt.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -q 'Backup checksum verification failed' "$work/corrupt.out"

# SHA256SUMS may not name arbitrary host paths.
make_v1_bundle badsum open-webui
printf '%064d  /etc/passwd\n' 0 > "$work/badsum/bundle/SHA256SUMS"
set +e
BACKUP="$work/badsum/bundle" RESTORE_CONFIRM=RESTORE RESTORE_ALLOW_VERSION_MISMATCH=1 ./scripts/restore.sh >"$work/badsum.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -q 'Unexpected path in SHA256SUMS' "$work/badsum.out"

# Links are not needed in legitimate backups and can redirect extraction.
mkdir -p "$work/symlink/src/open-webui" "$work/symlink/bundle"
printf 'fixture\n' > "$work/symlink/src/open-webui/file.txt"
ln -s /tmp "$work/symlink/src/open-webui/escape-link"
tar -C "$work/symlink/src" -czf "$work/symlink/bundle/volumes.tar.gz" open-webui
cat > "$work/symlink/bundle/manifest.txt" <<MANIFEST
format=local-polyglot-agent-backup-v1
kind=user-data
archive=volumes.tar.gz
MANIFEST
printf 'WEBUI_SECRET_KEY=test-only\n' > "$work/symlink/bundle/env"
checksum_bundle "$work/symlink/bundle"
set +e
BACKUP="$work/symlink/bundle" RESTORE_CONFIRM=RESTORE RESTORE_ALLOW_VERSION_MISMATCH=1 ./scripts/restore.sh >"$work/symlink.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -q 'Unsafe non-file/non-directory member' "$work/symlink.out"

# A v2 backup from a different Open WebUI runtime must not silently migrate.
mkdir -p "$work/version/src/open-webui" "$work/version/bundle"
printf 'fixture\n' > "$work/version/src/open-webui/file.txt"
tar -C "$work/version/src" -czf "$work/version/bundle/volumes.tar.gz" open-webui
cat > "$work/version/bundle/manifest.txt" <<MANIFEST
format=local-polyglot-agent-backup-v2
kind=user-data
running_open_webui_image=ghcr.io/open-webui/open-webui:v0.0.0-test
running_ollama_image=ollama/ollama:0.0.0-test
running_docling_image=ghcr.io/docling-project/docling-serve:v0.0.0-test
archive=volumes.tar.gz
MANIFEST
printf 'WEBUI_SECRET_KEY=test-only\n' > "$work/version/bundle/env"
cp versions.env "$work/version/bundle/versions.env"
cat > "$work/version/bundle/versions.running.env" <<VERSIONS
STACK_RELEASE=test
OLLAMA_IMAGE=ollama/ollama:0.0.0-test
OPEN_WEBUI_IMAGE=ghcr.io/open-webui/open-webui:v0.0.0-test
DOCLING_IMAGE=ghcr.io/docling-project/docling-serve:v0.0.0-test
MAINTENANCE_IMAGE=alpine:3.22.1
SMOKE_IMAGE=curlimages/curl:8.16.0
VERSIONS
checksum_bundle "$work/version/bundle"
set +e
BACKUP="$work/version/bundle" RESTORE_CONFIRM=RESTORE ./scripts/restore.sh >"$work/version.out" 2>&1
rc=$?
set -e
[[ $rc -eq 3 ]]
grep -q 'runtime versions differ' "$work/version.out"

echo 'restore preflight validation tests passed'
