#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source scripts/common.sh

backup_input="${BACKUP:-${1:-}}"
if [[ -z "$backup_input" ]]; then
  echo "Set BACKUP to a backup directory, e.g. BACKUP=backups/20261002T120000Z-user-data make restore" >&2
  exit 2
fi

if [[ "$backup_input" = /* ]]; then backup_abs="$backup_input"; else backup_abs="${ROOT_DIR}/${backup_input}"; fi
[[ -d "$backup_abs" ]] || { echo "Backup directory not found: $backup_abs" >&2; exit 1; }
[[ -s "$backup_abs/manifest.txt" && -s "$backup_abs/volumes.tar.gz" ]] || { echo "Backup is incomplete: manifest.txt/volumes.tar.gz missing." >&2; exit 1; }
[[ -s "$backup_abs/SHA256SUMS" ]] || { echo "Backup is missing SHA256SUMS; refusing an unverifiable restore." >&2; exit 1; }

# Do not let a crafted checksum file make the verifier read arbitrary host paths.
sum_names="$(awk '{print $2}' "$backup_abs/SHA256SUMS")"
while IFS= read -r sumfile; do
  [[ -z "$sumfile" ]] && continue
  case "$sumfile" in
    volumes.tar.gz|env|versions.env|versions.running.env|manifest.txt) ;;
    *) echo "Unexpected path in SHA256SUMS: $sumfile" >&2; exit 1 ;;
  esac
done <<<"$sum_names"
for required in volumes.tar.gz env manifest.txt; do
  grep -Fqx "$required" <<<"$sum_names" || { echo "SHA256SUMS does not cover required file: $required" >&2; exit 1; }
done
pre_format="$(sed -n 's/^format=//p' "$backup_abs/manifest.txt" | head -1)"
if [[ "$pre_format" == "local-polyglot-agent-backup-v2" ]]; then
  for required in versions.env versions.running.env; do
    grep -Fqx "$required" <<<"$sum_names" || { echo "SHA256SUMS does not cover v2 file: $required" >&2; exit 1; }
  done
fi

# Verify the bundle before stopping or overwriting any running service.
if command -v shasum >/dev/null 2>&1; then
  (cd "$backup_abs" && shasum -a 256 -c SHA256SUMS >/dev/null) || { echo "Backup checksum verification failed." >&2; exit 1; }
elif command -v sha256sum >/dev/null 2>&1; then
  (cd "$backup_abs" && sha256sum -c SHA256SUMS >/dev/null) || { echo "Backup checksum verification failed." >&2; exit 1; }
else
  echo "Neither shasum nor sha256sum is available; cannot verify backup integrity." >&2
  exit 1
fi

manifest_get() { sed -n "s/^$1=//p" "$backup_abs/manifest.txt" | head -1; }
format="$(manifest_get format)"
case "$format" in
  local-polyglot-agent-backup-v2)
    [[ -s "$backup_abs/versions.env" && -s "$backup_abs/versions.running.env" ]] || { echo "Backup v2 is missing version metadata files." >&2; exit 1; }
    ;;
  local-polyglot-agent-backup-v1)
    if [[ "${RESTORE_ALLOW_VERSION_MISMATCH:-0}" != "1" ]]; then
      echo "This v1 backup predates runtime-version metadata. Re-run with RESTORE_ALLOW_VERSION_MISMATCH=1 only after checking compatibility." >&2
      exit 3
    fi
    ;;
  *) echo "Unsupported backup format: $format" >&2; exit 1 ;;
esac

kind="$(manifest_get kind)"
case "$kind" in full|user-data) ;; *) echo "Unknown backup kind: $kind" >&2; exit 1 ;; esac

# Reject absolute paths, parent traversal, links, device nodes, FIFOs and other
# special members before passing the archive to tar as root in the helper.
allowed_re='^open-webui(/|$)'
if [[ "$kind" == "full" ]]; then
  allowed_re='^(open-webui|ollama|docling-artifacts)(/|$)'
fi
archive_list="$(mktemp)"
archive_verbose="$(mktemp)"
trap 'rm -f "$archive_list" "$archive_verbose"' EXIT

tar -tzf "$backup_abs/volumes.tar.gz" > "$archive_list" || { echo "Backup volume archive is not a readable tar.gz file." >&2; exit 1; }
tar -tvzf "$backup_abs/volumes.tar.gz" > "$archive_verbose" || { echo "Backup volume archive metadata cannot be inspected." >&2; exit 1; }
while IFS= read -r line; do
  type="${line:0:1}"
  case "$type" in
    -|d) ;;
    *) echo "Unsafe non-file/non-directory member in backup archive (type '$type'). Links and special files are rejected." >&2; exit 1 ;;
  esac
done < "$archive_verbose"
while IFS= read -r entry; do
  clean="${entry#./}"
  [[ -z "$clean" ]] && continue
  if [[ "$clean" == /* || "$clean" == ".." || "$clean" == ../* || "$clean" == */../* || "$clean" == */.. ]]; then
    echo "Unsafe path in backup archive: $entry" >&2
    exit 1
  fi
  if ! [[ "$clean" =~ $allowed_re ]]; then
    echo "Unexpected path in backup archive: $entry" >&2
    exit 1
  fi
done < "$archive_list"
rm -f "$archive_list" "$archive_verbose"
trap - EXIT

# Database/artifact compatibility guard. Open WebUI migrations can be one-way;
# do not silently restore an older database into a different app image. A
# deliberate forward migration can be requested explicitly, or rollback.sh can
# use the exact runtime versions stored in a v2 backup.
if [[ "$format" == "local-polyglot-agent-backup-v2" ]]; then
  backup_webui="$(manifest_get running_open_webui_image)"
  backup_ollama="$(manifest_get running_ollama_image)"
  backup_docling="$(manifest_get running_docling_image)"
  current_webui="$(version_get OPEN_WEBUI_IMAGE)"
  current_ollama="$(version_get OLLAMA_IMAGE)"
  current_docling="$(version_get DOCLING_IMAGE)"

  mismatch=0
  [[ -n "$backup_webui" && "$backup_webui" != "$current_webui" ]] && mismatch=1
  if [[ "$kind" == "full" ]]; then
    [[ -n "$backup_ollama" && "$backup_ollama" != "$current_ollama" ]] && mismatch=1
    [[ -n "$backup_docling" && "$backup_docling" != "$current_docling" ]] && mismatch=1
  fi
  if (( mismatch == 1 )) && [[ "${RESTORE_ALLOW_VERSION_MISMATCH:-0}" != "1" ]]; then
    cat >&2 <<MSG
Backup runtime versions differ from the selected version lock (${VERSION_LOCK_FILE}).
Backup Open WebUI: ${backup_webui}
Current Open WebUI: ${current_webui}
A database migration may be one-way. For rollback, use 'BACKUP=${backup_input} make rollback'.
For an intentional forward migration, set RESTORE_ALLOW_VERSION_MISMATCH=1.
MSG
    exit 3
  fi
fi

if [[ "${RESTORE_CONFIRM:-}" != "RESTORE" ]]; then
  echo "Restore will overwrite current ${kind} Docker volume data."
  read -r -p "Type RESTORE to continue: " answer
  [[ "$answer" == "RESTORE" ]] || { echo "Restore cancelled."; exit 1; }
fi

running="$(dc -f compose.yaml ps --services --filter status=running 2>/dev/null || true)"
was_active=0
grep -Eq '^(open-webui|docling|ollama)$' <<<"$running" && was_active=1

dc -f compose.yaml stop open-webui docling model-init docling-model-init ollama >/dev/null 2>&1 || true

if [[ "$kind" == "full" ]]; then
  wipe_cmd='for d in open-webui ollama docling-artifacts; do find "/volumes/$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; done; tar -C /volumes -xzf /restore/volumes.tar.gz'
else
  wipe_cmd='find /volumes/open-webui -mindepth 1 -maxdepth 1 -exec rm -rf {} +; tar -C /volumes -xzf /restore/volumes.tar.gz'
fi

dc -f compose.yaml --profile maintenance run --rm --no-deps -T \
  -v "${backup_abs}:/restore:ro" backup-helper "$wipe_cmd"

if [[ "${RESTORE_ENV:-1}" == "1" && -s "$backup_abs/env" ]]; then
  if [[ -f .env ]]; then cp .env ".env.pre-restore.$(date -u +%Y%m%dT%H%M%SZ)"; fi
  cp "$backup_abs/env" .env
  chmod 600 .env
  echo "Restored .env; previous copy preserved as .env.pre-restore.* when applicable."
fi

echo "Tracked runtime versions were not restored; version selection remains controlled by ${VERSION_LOCK_FILE}."

if (( was_active == 1 )); then
  ./scripts/up.sh >/dev/null
fi

echo "Restore completed from: $backup_abs"
echo "Run 'make check' and 'make smoke-test' before relying on the restored instance."
