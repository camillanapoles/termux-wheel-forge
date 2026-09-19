#!/usr/bin/env bash
# docker-build.sh — host side (GitHub Actions runner).
# Runs the build inside a real Termux aarch64 rootfs under QEMU and copies
# artifacts out of the container home.
set -uo pipefail
PKG="$1"; VER="$2"; PYV="${3:-}"

# The container runs as a non-root user whose uid differs from the runner's,
# so it cannot write into runner-owned bind-mount dirs (verified empirically:
# /tmp and plain 755 mounts are unwritable from inside; only $HOME is).
# World-writable so the container can write the toolchain tarball and the uv
# cache; files land 644 and stay readable for the runner-owned cache save.
mkdir -p dist
mkdir -p .uv-cache .prefix-cache && chmod 0777 .uv-cache .prefix-cache

CID="twb-$(date +%s)"

# .uv-cache is the host-side uv cache, mounted at Termux's default cache dir.
# .prefix-cache carries the gzip'd toolchain tarball written by
# scripts/build-in-termux.sh (pkg-bootstrap checkpoint; runner saves it via
# actions/cache). Container (root) writes stay readable for the runner-owned
# cache save on both mounts.
docker run --platform linux/arm64 --name "$CID" \
  -v "$PWD:/work:ro" \
  -v "$PWD/.uv-cache:/data/data/com.termux/files/home/.cache/uv" \
  -v "$PWD/.prefix-cache:/data/data/com.termux/files/prefix-cache" \
  -e UV_CACHE_DIR=/data/data/com.termux/files/home/.cache/uv \
  termux/termux-docker:latest \
  bash /work/scripts/build-in-termux.sh "$PKG" "$VER" "$PYV" || BUILD_RC=$?

docker cp "$CID:/data/data/com.termux/files/home/dist/." dist/ 2>/dev/null \
  || echo "NOTE: no dist output copied from container"
docker rm -f "$CID" >/dev/null 2>&1 || true

echo "== artifacts:"
ls -la dist/ || true
exit "${BUILD_RC:-0}"
