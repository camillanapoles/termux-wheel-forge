#!/usr/bin/env bash
# docker-build.sh — host side (GitHub Actions runner).
# Runs the build inside a real Termux aarch64 rootfs under QEMU and copies
# artifacts out of the container home.
set -uo pipefail
PKG="$1"; VER="$2"; PYV="${3:-}"

# The container runs as a non-root user whose uid differs from the runner's,
# so runner-owned bind-mount content is unwritable from inside (verified:
# /tmp unwritable; plain 755 dirs unwritable; and — run 35462492046 — files
# RESTORED by actions/cache land runner-owned 644, so even in a 777 dir the
# container could not overwrite state.txt: the stale 'miss' from the saved
# snapshot then made the workflow delete a perfectly good cache entry).
# chmod -R a+rwX (dir + every restored file) keeps both mounts writable;
# container-created files stay world-readable for the runner-owned save.
mkdir -p dist
mkdir -p .uv-cache .prefix-cache
chmod -R a+rwX .uv-cache .prefix-cache

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
