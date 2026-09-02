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
[ -n "$PYV" ] && [ "$PYV" != "default" ] && \
  [[ "$PYVER_ACTUAL" != *" $PYV"* ]] && \
  echo "WARN: requested python $PYV but got $PYVER_ACTUAL (wheel tag follows the actual one)"

"$PY" -m pip install -q --upgrade pip setuptools wheel build 2>&1 | tail -1 || true

echo "== [2/5] download sdist"
WORK="$HOME/work"
rm -rf "$WORK"; mkdir -p "$WORK/sdists"
cd "$WORK"
if ! "$PY" -m pip download --no-deps --no-binary :all: -d sdists "$PKG==$VER" >/dev/null 2>&1; then
  echo "ERROR: sdist download failed for $PKG==$VER"
  "$PY" -m pip download --no-deps -d sdists "$PKG==$VER" >/dev/null 2>&1 || true
  if ls sdists/*.whl >/dev/null 2>&1; then
    echo "NOTICE: PyPI only ships prebuilt (non-Android) wheels for this version; nothing to build."
  fi
  cp "$LOG" "$DIST/" 2>/dev/null || true
  exit 3
fi
SDIST="$(ls sdists/*.tar.gz 2>/dev/null | head -1 || true)"
if [ -z "$SDIST" ]; then
  echo "ERROR: sdist is not a .tar.gz — unsupported packaging"
  cp "$LOG" "$DIST/" 2>/dev/null || true
  exit 3
fi
tar xf "$SDIST"
ROOTD="$(tar tzf "$SDIST" | head -1 | sed 's|/.*||')"
echo "== sdist root: $ROOTD"

echo "== [3/5] known-issues advisories"
PKG="$PKG" VER="$VER" bash /work/patches/known.sh 2>/dev/null || true

echo "== [4/5] sdist fixer (Termux/Android auto-patches)"
"$PY" /work/scripts/sdist_fixer.py --headers /work/patches/headers "$ROOTD" || true

echo "== [5/5] building wheel"
cd "$ROOTD"
if "$PY" -m build --wheel --outdir "$DIST"; then
  RC=0
else
  RC=$?
  echo "ERROR: wheel build failed (rc=$RC) — see build.log artifact"
fi
ls -la "$DIST"
cp "$LOG" "$DIST/" 2>/dev/null || true
exit "$RC"
