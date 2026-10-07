#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source scripts/common.sh

require_docker_daemon || exit 1

POLL_SECONDS="${PROVISION_POLL_SECONDS:-3}"
TIMEOUT_SECONDS="${PROVISION_TIMEOUT_SECONDS:-7200}"
STATUS_EVERY_SECONDS="${PROVISION_STATUS_EVERY_SECONDS:-30}"
WEBUI_READY_TIMEOUT_SECONDS="${WEBUI_READY_TIMEOUT_SECONDS:-300}"
start_epoch="$(date +%s)"
last_status_epoch=0
services=(model-init literature-corpus-init docling-model-init)

declare -a cids=()
for service in "${services[@]}"; do
  cid="$(dc -f compose.yaml ps -a -q "$service" 2>/dev/null | head -n 1 || true)"
  if [[ -z "$cid" ]]; then
    echo "Provisioning service '$service' does not exist. Run 'make up' first." >&2
    exit 1
  fi
  cids+=("$cid")
done

echo "Waiting for provisioning jobs: ${services[*]}"

while :; do
  completed=0
  now="$(date +%s)"

  for i in "${!services[@]}"; do
    service="${services[$i]}"
    cid="${cids[$i]}"
    status="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo missing)"

    case "$status" in
      exited)
        code="$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo 1)"
        if [[ "$code" == "0" ]]; then
          ((completed+=1))
        else
          printf '[fail] %s exited with code %s\n' "$service" "$code" >&2
          dc -f compose.yaml logs --no-color --tail=160 "$service" >&2 || true
          exit 1
        fi
        ;;
      running|created|restarting)
        ;;
      missing|dead|removing|paused)
        printf '[fail] %s entered unexpected state: %s\n' "$service" "$status" >&2
        dc -f compose.yaml logs --no-color --tail=160 "$service" >&2 || true
        exit 1
        ;;
      *)
        printf '[warn] %s state: %s\n' "$service" "$status" >&2
        ;;
    esac
  done

  if (( completed == ${#services[@]} )); then
    for service in "${services[@]}"; do
      printf '[ok] %s completed\n' "$service"
    done
    echo "Provisioning completed successfully."
    break
  fi

  if (( now - last_status_epoch >= STATUS_EVERY_SECONDS )); then
    printf 'Still provisioning:'
    for i in "${!services[@]}"; do
      service="${services[$i]}"
      cid="${cids[$i]}"
      status="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo missing)"
      if [[ "$status" == "exited" ]]; then
        code="$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo 1)"
        if [[ "$code" == "0" ]]; then status="done"; else status="failed($code)"; fi
      fi
      printf ' %s=%s' "$service" "$status"
    done
    printf '\n'
    last_status_epoch="$now"
  fi

  if (( now - start_epoch >= TIMEOUT_SECONDS )); then
    printf '[fail] provisioning timed out after %ss\n' "$TIMEOUT_SECONDS" >&2
    for service in "${services[@]}"; do
      echo "--- $service logs ---" >&2
      dc -f compose.yaml logs --no-color --tail=120 "$service" >&2 || true
    done
    exit 1
  fi

  sleep "$POLL_SECONDS"
done

# Open WebUI can still be running database migrations or application startup
# after the one-shot provisioning jobs are done. `docker compose up -d` only
# means the container was started, not that its HTTP server is ready.
webui_cid="$(dc -f compose.yaml ps -q open-webui 2>/dev/null | head -n 1 || true)"
if [[ -z "$webui_cid" ]]; then
  echo "[fail] Open WebUI container does not exist. Run 'make up' first." >&2
  exit 1
fi

echo "Waiting for Open WebUI health ..."
webui_start_epoch="$(date +%s)"
while :; do
  state="$(docker inspect -f '{{.State.Status}}' "$webui_cid" 2>/dev/null || echo missing)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$webui_cid" 2>/dev/null || echo missing)"

  case "$state" in
    running)
      if [[ "$health" == "healthy" ]]; then
        echo "[ok] Open WebUI is healthy"
        exit 0
      fi
      if [[ "$health" == "unhealthy" ]]; then
        echo "[fail] Open WebUI became unhealthy" >&2
        dc -f compose.yaml logs --no-color --tail=200 open-webui >&2 || true
        exit 1
      fi
      ;;
    restarting|created)
      ;;
    exited|dead|missing|removing|paused)
      echo "[fail] Open WebUI entered unexpected state: $state (health=$health)" >&2
      dc -f compose.yaml logs --no-color --tail=200 open-webui >&2 || true
      exit 1
      ;;
  esac

  now="$(date +%s)"
  if (( now - webui_start_epoch >= WEBUI_READY_TIMEOUT_SECONDS )); then
    echo "[fail] Open WebUI did not become healthy within ${WEBUI_READY_TIMEOUT_SECONDS}s (state=$state health=$health)" >&2
    dc -f compose.yaml logs --no-color --tail=200 open-webui >&2 || true
    exit 1
  fi
  sleep 3
done
