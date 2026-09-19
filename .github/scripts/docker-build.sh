#!/usr/bin/env bash
# docker-build.sh — host side (GitHub Actions runner).
# Runs the build inside a real Termux aarch64 rootfs under QEMU and copies
# artifacts out of the container home.
set -uo pipefail
PKG="$1"; VER="$2"; PYV="${3:-}"

mkdir -p dist .uv-cache
CID="twb-$(date +%s)"

# .uv-cache is the host-side uv cache, mounted at Termux's default cache dir.
# Container (root) writes stay readable for the runner-owned cache save.
docker run --platform linux/arm64 --name "$CID" \
  -v "$PWD:/work:ro" \
  -v "$PWD/.uv-cache:/data/data/com.termux/files/home/.cache/uv" \
  -e UV_CACHE_DIR=/data/data/com.termux/files/home/.cache/uv \
  termux/termux-docker:latest \
  bash /work/scripts/build-in-termux.sh "$PKG" "$VER" "$PYV" || BUILD_RC=$?

docker cp "$CID:/data/data/com.termux/files/home/dist/." dist/ 2>/dev/null \
  || echo "NOTE: no dist output copied from container"
docker rm -f "$CID" >/dev/null 2>&1 || true

echo "== artifacts:"
ls -la dist/ || true
exit "${BUILD_RC:-0}"
