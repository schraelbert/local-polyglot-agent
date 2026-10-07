#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source scripts/common.sh

require_docker_daemon || exit 1

kind="${1:-full}"
case "$kind" in
  full|user-data) ;;
  *) echo "Usage: $0 [full|user-data]" >&2; exit 2 ;;
esac

[[ -f .env ]] || { echo ".env not found; run 'make up' first." >&2; exit 1; }
[[ -f "$VERSION_LOCK_FILE" ]] || { echo "Version lock not found: $VERSION_LOCK_FILE" >&2; exit 1; }

running="$(dc -f compose.yaml ps --services --filter status=running 2>/dev/null || true)"
if grep -Eq '^(model-init|docling-model-init)$' <<<"$running"; then
  echo "A provisioning job is still running. Wait for model-init/docling-model-init to finish before backing up." >&2
  exit 1
fi

service_image() {
  local service="$1" fallback_key="$2" cid image
  cid="$(dc -f compose.yaml ps -q "$service" 2>/dev/null || true)"
  if [[ -n "$cid" ]]; then
    image="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
  fi
  if [[ -z "${image:-}" ]]; then image="$(version_get "$fallback_key")"; fi
  printf '%s' "$image"
}

running_ollama_image="$(service_image ollama OLLAMA_IMAGE)"
running_webui_image="$(service_image open-webui OPEN_WEBUI_IMAGE)"
running_docling_image="$(service_image docling DOCLING_IMAGE)"

if [[ "$kind" == "full" ]]; then
  volume_list="open-webui ollama docling-artifacts"
  volume_paths="/volumes/open-webui /volumes/ollama /volumes/docling-artifacts"
else
  volume_list="open-webui"
  volume_paths="/volumes/open-webui"
fi

mkdir -p backups

# Conservative preflight: require roughly the uncompressed source volume size
# plus 10% and 512 MiB on the host filesystem that will receive the archive.
# Compression usually needs less, but refusing early is safer than a partial
# backup that fills the disk. Override only deliberately.
if [[ "${BACKUP_SKIP_SPACE_CHECK:-0}" != "1" ]]; then
  estimate_kb="$(dc -f compose.yaml --profile maintenance run --rm --no-deps -T backup-helper \
    "du -sk ${volume_paths} 2>/dev/null | awk '{s+=\$1} END {print s+0}'" 2>/dev/null | tail -n 1 || true)"
  free_kb="$(df -Pk backups | awk 'NR==2 {print $4}' || true)"
  if [[ "$estimate_kb" =~ ^[0-9]+$ && "$free_kb" =~ ^[0-9]+$ ]]; then
    required_kb=$(( estimate_kb + estimate_kb / 10 + 524288 ))
    if (( free_kb < required_kb )); then
      printf 'Insufficient free disk for conservative backup preflight.\n' >&2
      printf 'Estimated source: %d MiB; free: %d MiB; required: %d MiB.\n' \
        "$((estimate_kb/1024))" "$((free_kb/1024))" "$((required_kb/1024))" >&2
      echo "Free space or set BACKUP_SKIP_SPACE_CHECK=1 if you knowingly accept the risk." >&2
      exit 1
    fi
  else
    echo "Unable to determine backup/free-space size; refusing without BACKUP_SKIP_SPACE_CHECK=1." >&2
    exit 1
  fi
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out_rel="backups/${stamp}-${kind}"
out_abs="${ROOT_DIR}/${out_rel}"
mkdir -p "$out_abs"
chmod 700 "$out_abs"
backup_complete=0

webui_cid="$(dc -f compose.yaml ps -q open-webui 2>/dev/null || true)"
docling_cid="$(dc -f compose.yaml ps -q docling 2>/dev/null || true)"
ollama_cid="$(dc -f compose.yaml ps -q ollama 2>/dev/null || true)"

if [[ "$kind" == "full" ]]; then
  dc -f compose.yaml stop open-webui docling ollama >/dev/null 2>&1 || true
else
  dc -f compose.yaml stop open-webui >/dev/null 2>&1 || true
fi

cleanup() {
  # Restart the exact containers that were running before the backup. Do not
  # run `compose up` here: after a git pull, the tracked version lock may point
  # at newer images and could otherwise trigger an application/DB upgrade just
  # by taking a backup.
  if grep -qx 'ollama' <<<"$running" && [[ -n "$ollama_cid" ]]; then docker start "$ollama_cid" >/dev/null 2>&1 || true; fi
  if grep -qx 'docling' <<<"$running" && [[ -n "$docling_cid" ]]; then docker start "$docling_cid" >/dev/null 2>&1 || true; fi
  if grep -qx 'open-webui' <<<"$running" && [[ -n "$webui_cid" ]]; then docker start "$webui_cid" >/dev/null 2>&1 || true; fi
  if [[ "$backup_complete" != "1" && -d "$out_abs" ]]; then rm -rf "$out_abs"; fi
}
trap cleanup EXIT INT TERM

# Use a Compose maintenance service so volume names stay project-scoped and no
# Docker volume naming convention is hard-coded.
dc -f compose.yaml --profile maintenance run --rm --no-deps -T backup-helper \
  "tar -C /volumes -czf /backups/${stamp}-${kind}/volumes.tar.gz ${volume_list}"

cp .env "${out_abs}/env"
cp "$VERSION_LOCK_FILE" "${out_abs}/versions.env"
chmod 600 "${out_abs}/env" "${out_abs}/versions.env"

cat > "${out_abs}/versions.running.env" <<RUNNING
STACK_RELEASE=backup-runtime-${stamp}
OLLAMA_IMAGE=${running_ollama_image}
OPEN_WEBUI_IMAGE=${running_webui_image}
DOCLING_IMAGE=${running_docling_image}
MAINTENANCE_IMAGE=$(version_get MAINTENANCE_IMAGE)
SMOKE_IMAGE=$(version_get SMOKE_IMAGE)
RUNNING
chmod 600 "${out_abs}/versions.running.env"

{
  echo "format=local-polyglot-agent-backup-v2"
  echo "kind=${kind}"
  echo "created_utc=${stamp}"
  echo "git_commit=$(git rev-parse --verify HEAD 2>/dev/null || echo unknown)"
  echo "stack_release=$(version_get STACK_RELEASE unknown)"
  echo "running_open_webui_image=${running_webui_image}"
  echo "running_ollama_image=${running_ollama_image}"
  echo "running_docling_image=${running_docling_image}"
  echo "target_open_webui_image=$(version_get OPEN_WEBUI_IMAGE)"
  echo "target_ollama_image=$(version_get OLLAMA_IMAGE)"
  echo "target_docling_image=$(version_get DOCLING_IMAGE)"
  echo "version_lock_sha256=$(sha256_file "$VERSION_LOCK_FILE" 2>/dev/null || echo unavailable)"
  echo "compose_project=$(dc -f compose.yaml config --format json 2>/dev/null | sed -n 's/.*\"name\":\"\([^\"]*\)\".*/\1/p' | head -1 || true)"
  echo "archive=volumes.tar.gz"
} > "${out_abs}/manifest.txt"
chmod 600 "${out_abs}/manifest.txt"

if command -v shasum >/dev/null 2>&1; then
  (cd "$out_abs" && shasum -a 256 volumes.tar.gz env versions.env versions.running.env manifest.txt > SHA256SUMS)
elif command -v sha256sum >/dev/null 2>&1; then
  (cd "$out_abs" && sha256sum volumes.tar.gz env versions.env versions.running.env manifest.txt > SHA256SUMS)
else
  echo "Neither shasum nor sha256sum is available; refusing to create an unverifiable backup." >&2
  exit 1
fi
chmod 600 "${out_abs}"/* 2>/dev/null || true
backup_complete=1

trap - EXIT INT TERM
cleanup

if [[ -n "${BACKUP_RESULT_FILE:-}" ]]; then
  printf '%s\n' "$out_rel" > "$BACKUP_RESULT_FILE"
fi

echo "Backup created: ${out_rel}"
echo "It contains local secrets in the env file. Store the directory securely."
