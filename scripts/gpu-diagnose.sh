#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source scripts/common.sh

printf 'Local Polyglot Agent GPU diagnostics\n'
printf 'UTC: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REQUIRE_ACCEL="${GPU_DIAG_REQUIRE_ACCEL:-0}"

if ! command -v colima >/dev/null 2>&1; then
  echo '[fail] colima is not installed' >&2
  exit 1
fi

printf '== Host / Colima ==\n'
uname -a || true
sw_vers 2>/dev/null || true
colima version 2>/dev/null || true
colima status 2>&1 || true
printf '\n'

if ! colima status >/dev/null 2>&1; then
  echo '[fail] Colima is not running' >&2
  exit 1
fi

if ! colima_uses_krunkit; then
  echo '[fail] Colima is not using the Krunkit VM type' >&2
  exit 1
fi

printf '== Guest before module probe ==\n'
colima ssh -- sh -lc '
  set +e
  printf "kernel: "; uname -r
  printf "arch: "; uname -m
  printf "vendor: "; cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true
  printf "page-size: "; getconf PAGESIZE 2>/dev/null || true
  echo "-- /dev/dri --"
  ls -la /dev/dri 2>&1 || true
  echo "-- virtio_gpu module --"
  grep -E "^virtio_gpu " /proc/modules 2>/dev/null || true
  modinfo virtio_gpu 2>/dev/null | sed -n "1,20p" || true
  echo "-- DRM sysfs --"
  find /sys/class/drm -maxdepth 2 -type l -o -type d 2>/dev/null | head -80 || true
' || true

printf '\n== Attempting safe virtio_gpu module load ==\n'
if colima ssh -- sudo modprobe virtio_gpu >/dev/null 2>&1; then
  echo '[ok] modprobe virtio_gpu succeeded'
  colima ssh -- sudo udevadm settle >/dev/null 2>&1 || true
else
  echo '[warn] modprobe virtio_gpu failed or module is unavailable'
fi

printf '\n== Guest after module probe ==\n'
colima ssh -- sh -lc '
  set +e
  ls -la /dev/dri 2>&1 || true
  grep -E "^virtio_gpu " /proc/modules 2>/dev/null || true
  echo "-- recent GPU/DRM kernel messages --"
  sudo dmesg 2>/dev/null | grep -Ei "virtio.?gpu|drm|venus|virgl" | tail -80 || true
' || true

printf '\n== Ollama container Vulkan payload ==\n'
vulkan_payload=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && [[ -f .env && -f "$VERSION_LOCK_FILE" ]]; then
  ollama_cid="$(dc -f compose.yaml ps -q ollama 2>/dev/null | head -n 1 || true)"
  if [[ -n "$ollama_cid" ]]; then
    if ollama_container_has_vulkan_runner; then
      vulkan_payload=1
      echo '[ok] Ollama container includes a Vulkan runner payload.'
    else
      echo '[warn] Ollama container has no Vulkan runner payload under /usr/lib/ollama.'
      echo '       Device passthrough alone is insufficient; this ARM64 image cannot execute the Vulkan runner.'
    fi
  else
    echo '[warn] Ollama container is not running; Vulkan payload check skipped.'
  fi
else
  echo '[warn] Docker/Ollama stack is unavailable; Vulkan payload check skipped.'
fi

printf '\n== Result ==\n'
if colima ssh -- sh -lc 'test -c /dev/dri/renderD128 || test -e /dev/dri/renderD128' >/dev/null 2>&1; then
  echo '[ok] /dev/dri/renderD128 is present in the Colima VM.'
  if (( vulkan_payload == 1 )); then
    echo '[ok] VM device and Ollama Vulkan payload prerequisites are both present.'
    echo '     Re-run make up so the GPU compose override can map /dev/dri into Ollama.'
    exit 0
  fi
  echo '[warn] The VM device exists, but the current Ollama ARM64 container lacks a Vulkan runner payload.'
  echo '       CPU fallback is expected for this image; make up will select the smaller CPU chat model and cap its context for memory safety.'
  if [[ "$REQUIRE_ACCEL" == "1" ]]; then
    exit 3
  fi
  echo '[ok] GPU diagnostic completed; acceleration is unavailable but CPU fallback is supported.'
  exit 0
fi

echo '[warn] /dev/dri/renderD128 is still absent in the Colima VM.'
echo '       Docker Compose cannot pass a GPU device that the VM itself does not expose.'
echo '       This points first to the Colima/Lima/Krunkit guest path, before Ollama or Compose.'
echo '       Keep CPU mode for now; this diagnostic output is suitable for comparing with upstream Krunkit/Colima behavior.'
if [[ "$REQUIRE_ACCEL" == "1" ]]; then
  exit 2
fi
echo '[ok] GPU diagnostic completed; acceleration is unavailable but CPU fallback is supported.'
exit 0
