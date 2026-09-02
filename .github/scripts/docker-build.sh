#!/usr/bin/env bash
# docker-build.sh — host side (GitHub Actions runner).
# Runs the build inside a real Termux aarch64 rootfs under QEMU and copies
# artifacts out of the container home.
set -uo pipefail
PKG="$1"; VER="$2"; PYV="${3:-}"

mkdir -p dist
CID="twb-$(date +%s)"

docker run --platform linux/arm64 --name "$CID" \
  -v "$PWD:/work:ro" \
  termux/termux-docker:latest \
  bash /work/scripts/build-in-termux.sh "$PKG" "$VER" "$PYV" || BUILD_RC=$?

docker cp "$CID:/data/data/com.termux/files/home/dist/." dist/ 2>/dev/null \
  || echo "NOTE: no dist output copied from container"
docker rm -f "$CID" >/dev/null 2>&1 || true

echo "== artifacts:"
ls -la dist/ || true
exit "${BUILD_RC:-0}"
