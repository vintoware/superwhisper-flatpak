#!/usr/bin/env bash
#
# build.sh — build the Superwhisper Flatpak bundle for this machine's architecture,
# inside a container (docker, or podman), so the host needs neither flatpak-builder nor
# minisign.
#
# Usage:
#   ./build.sh                                   # latest stable Superwhisper, host arch
#   SW_CHANNEL_FILE=stable.json ./build.sh       # pin to a saved stable.json (CI does this)
#   CONTAINER_ENGINE=podman ./build.sh
#
# Outputs (dist/):
#   com.superwhisper.Superwhisper.<arch>.flatpak   bundle; Superwhisper itself is extra-data
#   build-inputs.<arch>.json                       versions, upstream URL/hashes, bundle sha256
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${FLATPAK_ARCH:=$(uname -m)}"
case "$FLATPAK_ARCH" in
  x86_64|aarch64) ;;
  arm64) FLATPAK_ARCH=aarch64 ;;
  *) echo "unsupported architecture: $FLATPAK_ARCH" >&2; exit 1 ;;
esac
if [ "$FLATPAK_ARCH" != "$(uname -m | sed s/arm64/aarch64/)" ]; then
  echo "build $FLATPAK_ARCH on an $FLATPAK_ARCH machine: flatpak-builder's bubblewrap" >&2
  echo "can't run under QEMU emulation (CI uses a native runner per architecture)" >&2
  exit 1
fi
: "${PROJECT_URL:=https://github.com/vintoware/superwhisper-flatpak}"
: "${BASE_IMAGE:=debian:13.7}"
# bubblewrap inside the container needs user namespaces.
: "${CONTAINER_FLAGS:=--security-opt seccomp=unconfined --privileged --cap-add SYS_ADMIN}"

if [ -z "${CONTAINER_ENGINE:-}" ]; then
  if command -v docker >/dev/null 2>&1; then CONTAINER_ENGINE=docker
  elif command -v podman >/dev/null 2>&1; then CONTAINER_ENGINE=podman
  else echo "docker or podman is required" >&2; exit 1; fi
fi
RUN_ARGS=()
# Rootless podman: no SELinux relabelling of the bind mounts.
[ "$(basename "$CONTAINER_ENGINE")" = podman ] && RUN_ARGS+=(--security-opt label=disable)

CHANNEL_MOUNT=()
if [ -n "${SW_CHANNEL_FILE:-}" ]; then
  CHANNEL_MOUNT=(-v "$(realpath "$SW_CHANNEL_FILE"):/channel.json:ro" -e SW_CHANNEL_FILE=/channel.json)
fi

# .work: build tree + flatpak-builder state; .cache: upstream archives; .flatpak-user:
# runtime + SDK. All git-ignored and reused between builds.
mkdir -p "$HERE/.work" "$HERE/.cache" "$HERE/.flatpak-user" "$HERE/dist"

IMAGE=superwhisper-flatpak-builder:latest
"$CONTAINER_ENGINE" build --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$IMAGE" -f "$HERE/Containerfile" "$HERE"

# shellcheck disable=SC2086
"$CONTAINER_ENGINE" run --rm "${RUN_ARGS[@]}" $CONTAINER_FLAGS \
  -e FLATPAK_ARCH="$FLATPAK_ARCH" \
  -e PROJECT_URL="$PROJECT_URL" \
  "${CHANNEL_MOUNT[@]}" \
  -v "$HERE:/src:ro" \
  -v "$HERE/.work:/work" \
  -v "$HERE/.cache:/cache" \
  -v "$HERE/.flatpak-user:/root/.local/share/flatpak" \
  "$IMAGE" \
  bash /src/scripts/build-flatpak.sh

. "$HERE/build.env"
cp -f "$HERE/.work/dist/$APP_ID.$FLATPAK_ARCH.flatpak" "$HERE/.work/dist/build-inputs.$FLATPAK_ARCH.json" "$HERE/dist/"
echo
echo "Bundle: $HERE/dist/$APP_ID.$FLATPAK_ARCH.flatpak"
echo "An extra-data app can't be installed from the bundle file; install from the build repo:"
echo "  flatpak build-update-repo .work/repo"
echo "  flatpak remote-add --user --no-gpg-verify sw-local \"file://$HERE/.work/repo\""
echo "  flatpak install --user sw-local $APP_ID"
