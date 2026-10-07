#!/usr/bin/env bash
# Shared helpers. User .env is intentionally parsed as data instead of
# `source`-ing it, because Docker Compose .env syntax permits values with
# spaces that are not valid shell assignments.

VERSION_LOCK_FILE="${VERSION_LOCK_FILE:-versions.env}"
RUNTIME_ENV_FILE="${RUNTIME_ENV_FILE:-.runtime.env}"

# Compose interpolation loads user configuration first and the tracked version
# lock second. This deliberately makes image versions authoritative even when
# an old .env still contains legacy *_IMAGE keys from legacy builds.
dc() {
  if [[ ! -f .env ]]; then
    echo ".env not found; run 'make up' first." >&2
    return 2
  fi
  if [[ ! -f "$VERSION_LOCK_FILE" ]]; then
    echo "Version lock not found: $VERSION_LOCK_FILE" >&2
    return 2
  fi
  local env_args=(--env-file .env)
  # make up writes capability-selected runtime overrides here (for example,
  # the routed text/vision models and the CPU-safe context length).
  if [[ -f "$RUNTIME_ENV_FILE" ]]; then
    env_args+=(--env-file "$RUNTIME_ENV_FILE")
  fi
  env_args+=(--env-file "$VERSION_LOCK_FILE")
  docker compose "${env_args[@]}" "$@"
}

env_get() {
  local key="$1" default_value="${2:-}" env_file="${3:-.env}" line value
  if [[ -f "$env_file" ]]; then
    line="$(grep -E "^${key}=" "$env_file" | tail -n 1 || true)"
    if [[ -n "$line" ]]; then
      value="${line#*=}"
      # Handle simple matching single/double quotes without evaluating content.
      if [[ ${#value} -ge 2 ]]; then
        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
          value="${value:1:${#value}-2}"
        elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
          value="${value:1:${#value}-2}"
        fi
      fi
      printf '%s' "$value"
      return 0
    fi
  fi
  printf '%s' "$default_value"
}

version_get() {
  env_get "$1" "${2:-}" "$VERSION_LOCK_FILE"
}

effective_env_get() {
  local key="$1" default_value="${2:-}" value
  if [[ -f "$RUNTIME_ENV_FILE" ]] && grep -Eq "^${key}=" "$RUNTIME_ENV_FILE"; then
    value="$(env_get "$key" "$default_value" "$RUNTIME_ENV_FILE")"
    printf '%s' "$value"
    return 0
  fi
  env_get "$key" "$default_value"
}

sha256_file() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    return 1
  fi
}

require_docker_daemon() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker CLI is not installed. Run 'make bootstrap' first." >&2
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    cat >&2 <<'MSG'
Docker CLI is installed, but no Docker daemon is reachable.
For this project on Apple Silicon, run:
  make bootstrap
Then verify:
  colima status
  docker info
Do not continue with make up/check/smoke-test/benchmark/backup until Docker is reachable.
MSG
    return 1
  fi
}

# Colima 0.10.x writes its human-readable status lines (including the VM type)
# to stderr. Capture both streams so callers do not accidentally conclude that
# a running Krunkit VM is using the default VM type.
colima_status_text() {
  command -v colima >/dev/null 2>&1 || return 127
  colima status 2>&1
}

colima_uses_krunkit() {
  local status
  status="$(colima_status_text)" || return 1
  grep -qi 'krunkit' <<<"$status"
}



# Report the Colima filesystem that backs Docker/containerd storage as:
#   <total_kib> <free_kib>
# Test overrides keep the preflight deterministic without requiring a real VM.
colima_container_disk_stats_kib() {
  if [[ -n "${COLIMA_DISK_TOTAL_KIB_OVERRIDE:-}" && -n "${COLIMA_DISK_FREE_KIB_OVERRIDE:-}" ]]; then
    printf '%s %s\n' "$COLIMA_DISK_TOTAL_KIB_OVERRIDE" "$COLIMA_DISK_FREE_KIB_OVERRIDE"
    return 0
  fi

  command -v colima >/dev/null 2>&1 || return 1
  local stats
  stats="$(colima ssh -- df -Pk /var/lib/containerd 2>/dev/null | awk 'NR==2 {print $2, $4; exit}' || true)"
  if [[ ! "$stats" =~ ^[0-9]+[[:space:]][0-9]+$ ]]; then
    stats="$(colima ssh -- df -Pk / 2>/dev/null | awk 'NR==2 {print $2, $4; exit}' || true)"
  fi
  [[ "$stats" =~ ^[0-9]+[[:space:]][0-9]+$ ]] || return 1
  printf '%s\n' "$stats"
}

# Pick a conservative free-space floor. Fresh/partial provisioning needs room
# for the large Open WebUI + Docling images plus local model blobs. Once all
# core runtime images exist, a smaller reserve is sufficient for model updates,
# temporary extraction, logs, and copy-on-write overhead.
project_required_free_disk_gib() {
  local explicit="${COLIMA_MIN_FREE_DISK_GIB:-}"
  if [[ -n "$explicit" ]]; then
    [[ "$explicit" =~ ^[0-9]+$ ]] && (( explicit >= 4 )) || {
      echo "COLIMA_MIN_FREE_DISK_GIB must be an integer >= 4 (got: $explicit)." >&2
      return 2
    }
    printf '%s\n' "$explicit"
    return 0
  fi

  local image missing=0
  for image in "$@"; do
    [[ -n "$image" ]] || continue
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      missing=1
      break
    fi
  done

  if (( missing == 1 )); then
    printf '30\n'
  else
    printf '16\n'
  fi
}

# Fail early with actionable guidance instead of allowing a multi-gigabyte pull
# to die halfway through layer extraction with ENOSPC. This never prunes data
# automatically because a Colima VM may contain unrelated user workloads.
colima_disk_preflight() {
  local minimum_gib="$1"
  [[ "$minimum_gib" =~ ^[0-9]+$ ]] || return 2

  local stats total_kib free_kib total_gib free_gib min_kib deficit_gib target_gib
  stats="$(colima_container_disk_stats_kib)" || {
    echo "Warning: unable to read Colima container-disk free space; continuing without disk preflight." >&2
    return 0
  }
  read -r total_kib free_kib <<<"$stats"
  [[ "$total_kib" =~ ^[0-9]+$ && "$free_kib" =~ ^[0-9]+$ ]] || return 2

  total_gib=$(( total_kib / 1024 / 1024 ))
  free_gib=$(( free_kib / 1024 / 1024 ))
  min_kib=$(( minimum_gib * 1024 * 1024 ))
  printf 'Colima container disk: about %d GiB total / %d GiB free.\n' "$total_gib" "$free_gib"

  if (( free_kib >= min_kib )); then
    return 0
  fi

  deficit_gib=$(( minimum_gib - free_gib ))
  (( deficit_gib < 1 )) && deficit_gib=1
  # Add the missing reserve plus 10 GiB working headroom, rounded to 10 GiB.
  target_gib=$(( total_gib + deficit_gib + 10 ))
  target_gib=$(( ((target_gib + 9) / 10) * 10 ))
  (( target_gib < 120 )) && target_gib=120

  local grow_flag="--disk"
  local storage_note="Colima's container data disk"
  if colima_uses_krunkit; then
    # Current Krunkit releases can fail to remount Colima's secondary data disk
    # after restart, which silently leaves /var/lib/containerd on the default
    # ~20 GiB root filesystem. Growing rootDisk avoids that failure mode.
    grow_flag="--root-disk"
    storage_note="the Krunkit root filesystem that currently backs /var/lib/containerd"
  fi

  cat >&2 <<MSG
Colima container storage has only about ${free_gib} GiB free; this startup needs at least ${minimum_gib} GiB of working space.
The previous Docker pull would otherwise fail partway through layer extraction with "no space left on device".

Inspect usage first:
  docker system df
  colima ssh -- df -h /var/lib/containerd

If this Colima VM is dedicated to this project, reclaim unused image/build cache without deleting named volumes:
  docker image prune -af
  docker builder prune -af
  colima ssh -- sudo fstrim -a

If free space is still below ${minimum_gib} GiB and macOS has enough host disk, grow ${storage_note}:
  colima stop
  colima start --memory 10 ${grow_flag} ${target_gib}

Then rerun:
  make disk-check
  make up
MSG
  return 1
}

# Return success when an Ollama image for the current Docker platform contains
# a Vulkan llama-server payload. The official Linux ARM64 image currently omits
# this payload even when the Krunkit guest exposes /dev/dri, so checking the
# image is required before enabling the GPU Compose override.
ollama_image_has_vulkan_runner() {
  local image="${1:-}"
  [[ -n "$image" ]] || return 2

  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Pulling pinned Ollama image for runtime capability probe: $image" >&2
    docker pull "$image" >&2 || return 2
  fi

  docker run --rm --network none --entrypoint /bin/sh "$image" -lc '
    find /usr/lib/ollama -type f \
      \( -path "*/vulkan/*" -o -name "*vulkan*.so" -o -name "*vulkan*.so.*" \) \
      -print -quit 2>/dev/null | grep -q .
  ' >/dev/null 2>&1
}

ollama_container_has_vulkan_runner() {
  dc -f compose.yaml exec -T ollama sh -lc '
    find /usr/lib/ollama -type f \
      \( -path "*/vulkan/*" -o -name "*vulkan*.so" -o -name "*vulkan*.so.*" \) \
      -print -quit 2>/dev/null | grep -q .
  ' >/dev/null 2>&1
}

# Validate the curated Ollama /api/tags payload structurally enough to avoid
# false positives from metadata such as details.parent_model. The router emits
# compact JSON; we require exactly one top-level-style name field, and both the
# public name/model fields must match. Internal models are considered leaked
# only when they appear as actual name/model field values, not as metadata.
curated_tags_expose_only_public_model() {
  local payload="$1" public_model="$2"
  shift 2

  [[ "$payload" == *"\"name\":\"${public_model}\""* ]] || return 1
  [[ "$payload" == *"\"model\":\"${public_model}\""* ]] || return 1

  local name_count
  name_count="$(printf '%s' "$payload" | grep -o '"name":"' | wc -l | tr -d '[:space:]')"
  [[ "$name_count" == "1" ]] || return 1

  local internal_model
  for internal_model in "$@"; do
    [[ -n "$internal_model" && "$internal_model" != "$public_model" ]] || continue
    if [[ "$payload" == *"\"name\":\"${internal_model}\""* \
      || "$payload" == *"\"model\":\"${internal_model}\""* ]]; then
      return 1
    fi
  done

  return 0
}

# Extract the JSON string token belonging to /api/generate's response field.
# Keeping the field wrapper is intentional: callers can regex-match the answer
# without accidentally matching the separate thinking channel. This handles
# normal JSON backslash escapes while remaining dependency-free on jq/python.
ollama_generate_response_field() {
  grep -oE '"response"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n 1
}

# Extract /api/chat assistant message content without matching a separate
# thinking field. The response does not echo input messages, so the first
# message.content token is the assistant answer.
ollama_chat_content_field() {
  grep -oE '"content"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n 1
}

# Smoke markers are protocol sentinels, not translation-quality assertions.
# Accept ASCII case variation plus harmless leading/trailing whitespace emitted
# by some chat templates (including JSON-escaped \n/\r/\t) while still
# requiring the trimmed response value to contain only the requested marker.
ollama_response_is_exact_marker_ci() {
  local response_field="$1" expected="$2" observed expected_norm
  [[ "$expected" =~ ^[A-Za-z0-9_]+$ ]] || return 2

  # ollama_generate_response_field returns a single JSON token such as
  #   "response":"\nCHINESE_OK"
  # Capture only the JSON string payload, then trim whitespace at the two ends.
  # Do not remove whitespace in the middle: "CHINESE_\nOK" must still fail.
  observed="$(printf '%s\n' "$response_field" | sed -nE 's/^"response"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"$/\1/p')"

  # Trim only harmless edge whitespace. Do this in Bash rather than with sed
  # labels: macOS ships BSD sed, whose label parsing differs from GNU sed.
  # JSON-escaped \n/\r/\t stay literal after token extraction, so strip both
  # those escape sequences and real shell whitespace at the two edges.
  while :; do
    case "$observed" in
      ' '*) observed="${observed# }" ;;
      $'\t'*) observed="${observed#$'\t'}" ;;
      $'\n'*) observed="${observed#$'\n'}" ;;
      $'\r'*) observed="${observed#$'\r'}" ;;
      \\n*) observed="${observed#\\n}" ;;
      \\r*) observed="${observed#\\r}" ;;
      \\t*) observed="${observed#\\t}" ;;
      *) break ;;
    esac
  done
  while :; do
    case "$observed" in
      *' ') observed="${observed% }" ;;
      *$'\t') observed="${observed%$'\t'}" ;;
      *$'\n') observed="${observed%$'\n'}" ;;
      *$'\r') observed="${observed%$'\r'}" ;;
      *\\n) observed="${observed%\\n}" ;;
      *\\r) observed="${observed%\\r}" ;;
      *\\t) observed="${observed%\\t}" ;;
      *) break ;;
    esac
  done

  [[ "$observed" =~ ^[A-Za-z0-9_]+$ ]] || return 1

  observed="$(printf '%s' "$observed" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  expected_norm="$(printf '%s' "$expected" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$observed" == "$expected_norm" ]]
}

# Extract Docling's actual OCR/document text channel. This intentionally does
# not reuse the Ollama response-field extractor: Docling returns converted text
# under document.text_content.
docling_text_content_field() {
  grep -oE '"text_content"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n 1
}

ollama_cpu_context_length() {
  local value
  value="$(env_get OLLAMA_CPU_CONTEXT_LENGTH 4096)"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 512 )); then
    echo "OLLAMA_CPU_CONTEXT_LENGTH must be an integer >= 512 (got: $value)." >&2
    return 2
  fi
  printf '%s' "$value"
}
