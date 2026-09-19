#!/usr/bin/env bash
# build-in-termux.sh — runs INSIDE a Termux (aarch64) environment.
# Image: termux/termux-docker (emulated arm64 on the CI runner via QEMU).
# Env: PKG, VER, PYV (optional python minor, e.g. 3.14). Repo mounted read-only at /work.
set -uo pipefail

PKG="${1:?usage: build-in-termux.sh <pkg> <ver> [pyv]}"
VER="${2:?usage: build-in-termux.sh <pkg> <ver> [pyv]}"
PYV="${3:-}"

DIST="$HOME/dist"
LOG="$HOME/build.log"
rm -rf "$DIST"; mkdir -p "$DIST"
exec > >(tee "$LOG") 2>&1

echo "== termux-wheel-forge: building $PKG==$VER (python=${PYV:-default})"
echo "== host: $(uname -m) — $(getprop ro.product.cpu.abi 2>/dev/null || echo docker)"

echo "== [1/5] pkg update + toolchain"
yes | pkg update -y >/dev/null 2>&1 || apt-get update -y || true
# Termux root repo ships one main `python`; versioned packages exist for some minors.
PKGNAME="python"
if [ -n "$PYV" ] && [ "$PYV" != "default" ]; then
  if pkg install -y "python-$PYV" >/dev/null 2>&1; then
    PKGNAME="python-$PYV"
  else
    echo "WARN: package python-$PYV not available; falling back to default python"
  fi
fi
pkg install -y "$PKGNAME" python-pip clang >/dev/null 2>&1 \
  || pkg install -y python python-pip clang

PY="$(command -v python || command -v python3)"
PYVER_ACTUAL="$("$PY" -V 2>&1)"
echo "== python: $PYVER_ACTUAL"
printf '%s\n' "${PYVER_ACTUAL#Python }" > "$DIST/py-actual.txt"
[ -n "$PYV" ] && [ "$PYV" != "default" ] && \
  [[ "$PYVER_ACTUAL" != *" $PYV"* ]] && \
  echo "WARN: requested python $PYV but got $PYVER_ACTUAL (wheel tag follows the actual one)"

command -v curl >/dev/null 2>&1 || pkg install -y curl >/dev/null 2>&1 || true
UV_BIN="$HOME/.local/bin/uv"
if [ ! -x "$UV_BIN" ]; then
  echo "== [1b/5] uv (musl static aarch64 — cached package layer)"
  # musl build is fully static: runs on bionic. The gnu build would not.
  if curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-unknown-linux-musl.tar.gz" \
       -o /tmp/uv.tgz \
     && tar -xzf /tmp/uv.tgz -C /tmp \
     && mkdir -p "$(dirname "$UV_BIN")" \
     && install -m 755 /tmp/uv-aarch64-unknown-linux-musl/uv "$UV_BIN"; then
    rm -rf /tmp/uv.tgz /tmp/uv-aarch64-unknown-linux-musl
  else
    echo "WARN: uv fetch failed — falling back to pip"
  fi
fi
if [ -x "$UV_BIN" ]; then
  echo "== uv pip toolchain (cache: ${UV_CACHE_DIR:-unset})"
  # --python pins Termux's own bionic interpreter; never `uv python`
  # (uv-managed glibc/musl pythons do not run on Android).
  "$UV_BIN" pip install -p "$PY" --upgrade pip setuptools wheel build \
    || { echo "WARN: uv toolchain install failed — falling back to pip"; \
         "$PY" -m pip install -q --upgrade pip setuptools wheel build 2>&1 | tail -1 || true; }
else
  "$PY" -m pip install -q --upgrade pip setuptools wheel build 2>&1 | tail -1 || true
fi

echo "== [2/5] download sdist"
WORK="$HOME/work"
rm -rf "$WORK"; mkdir -p "$WORK/sdists"
cd "$WORK" || exit 1
if ! "$PY" -m pip download --no-deps --no-binary :all: -d sdists "$PKG==$VER" >/dev/null 2>&1; then
  echo "ERROR: sdist download failed for $PKG==$VER"
  "$PY" -m pip download --no-deps -d sdists "$PKG==$VER" >/dev/null 2>&1 || true
  if ls sdists/*.whl >/dev/null 2>&1; then
    echo "NOTICE: PyPI only ships prebuilt (non-Android) wheels for this version; nothing to build."
  fi
  cp "$LOG" "$DIST/" 2>/dev/null || true
  exit 3
fi
SDIST="$(find sdists -maxdepth 1 -type f -name '*.tar.gz' | sort | head -n 1 || true)"
if [ -z "$SDIST" ]; then
  echo "ERROR: sdist is not a .tar.gz — unsupported packaging"
  cp "$LOG" "$DIST/" 2>/dev/null || true
  exit 3
fi
tar xf "$SDIST"
ROOTD="$(tar tzf "$SDIST" | head -1 | sed 's|/.*||')"
echo "== sdist root: $ROOTD"

echo "== [3/5] known-issues advisories"
( cd "$ROOTD" && PKG="$PKG" VER="$VER" bash /work/patches/known.sh ) 2>/dev/null || true

echo "== [4/5] sdist fixer (Termux/Android auto-patches)"
"$PY" /work/scripts/sdist_fixer.py --headers /work/patches/headers "$ROOTD" || true

echo "== [5/5] building wheel"
# maturin (jiter/tiktoken) refuses to build without this; 24 matches the
# android_24_arm64_v8a wheel tag Termux ships.
export ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-24}"
cd "$ROOTD" || exit 1
if "$PY" -m build --wheel --no-isolation --outdir "$DIST"; then
  RC=0
else
  RC=$?
  echo "ERROR: wheel build failed (rc=$RC) — see build.log artifact"
fi
ls -la "$DIST"
cp "$LOG" "$DIST/" 2>/dev/null || true
exit "$RC"
