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

# --- Prefix cache (toolchain bootstrap checkpoint) --------------------------
# pkg update+install under QEMU dominates the build (~300s). A gzip tarball of
# the toolchain lives on the host-mounted .prefix-cache dir; on HIT we restore
# it instead of bootstrapping. Correctness over speed: every restore is
# verified, and any failure falls back to the full bootstrap below.
CACHE_DIR="/data/data/com.termux/files/prefix-cache"
CACHE_TARBALL="$CACHE_DIR/termux-prefix.tar.gz"
CACHE_MARKER="$CACHE_DIR/marker.txt"
CACHE_FORMAT="v1"
UV_BIN="$HOME/.local/bin/uv"

prefix_cache_restore() {
  # marker + tarball must both exist; the saver writes the marker last.
  [ -s "$CACHE_MARKER" ] && [ -s "$CACHE_TARBALL" ] || return 1
  grep -q "^format=$CACHE_FORMAT$" "$CACHE_MARKER" 2>/dev/null || return 1
  tar -xzf "$CACHE_TARBALL" -C / || return 1
  local py pyver
  py="$(command -v python || command -v python3)" || return 1
  pyver="$("$py" -V 2>&1)" || return 1
  if [ -n "$PYV" ] && [ "$PYV" != "default" ]; then
    case "$pyver" in
      *" $PYV"*) ;;
      *) echo "  prefix cache holds '$pyver', requested $PYV"; return 1 ;;
    esac
  fi
  command -v clang >/dev/null 2>&1 || return 1
  if grep -q '^uv=yes$' "$CACHE_MARKER" 2>/dev/null; then
    [ -x "$UV_BIN" ] || return 1
  fi
  # the cached toolchain must be importable, not just present on disk
  "$py" -c 'import build, setuptools, wheel' >/dev/null 2>&1 || return 1
}

prefix_cache_save() {
  mkdir -p "$CACHE_DIR"
  local paths=(data/data/com.termux/files/usr)
  [ -x "$UV_BIN" ] && paths+=(data/data/com.termux/files/home/.local/bin/uv)
  [ -d "$HOME/.cache/pip" ] && paths+=(data/data/com.termux/files/home/.cache/pip)
  # gzip only (busybox-safe; no zstd). tmp+mv so a half-written tarball never
  # gets a marker: marker+tarball present ⇔ complete save.
  if tar -czf "$CACHE_TARBALL.tmp" \
       --exclude='data/data/com.termux/files/usr/var/cache/apt' \
       --exclude='data/data/com.termux/files/usr/tmp' \
       -C / "${paths[@]}" \
     && mv "$CACHE_TARBALL.tmp" "$CACHE_TARBALL"; then
    printf 'format=%s\ncreated=%s\nuv=%s\n' "$CACHE_FORMAT" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$([ -x "$UV_BIN" ] && echo yes || echo no)" > "$CACHE_MARKER.tmp"
    mv "$CACHE_MARKER.tmp" "$CACHE_MARKER"
    echo "== prefix cache: saved ($(du -h "$CACHE_TARBALL" 2>/dev/null | cut -f1)) to host .prefix-cache/"
  else
    rm -f "$CACHE_TARBALL.tmp" "$CACHE_MARKER.tmp"
    echo "WARN: prefix cache save failed — next run bootstraps from scratch"
  fi
}

echo "== [1/5] toolchain (prefix cache, else pkg bootstrap)"
CACHE_T0="$(date +%s)"
if prefix_cache_restore; then
  echo "== prefix cache: HIT (restored in $(( $(date +%s) - CACHE_T0 ))s)"
else
  if [ -e "$CACHE_TARBALL" ] || [ -e "$CACHE_MARKER" ]; then
    echo "== prefix cache: restore failed — full bootstrap (correctness over speed)"
  fi
  echo "== prefix cache: MISS (bootstrapping + saving)"
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

  command -v curl >/dev/null 2>&1 || pkg install -y curl >/dev/null 2>&1 || true
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
  PY_BOOT="$(command -v python || command -v python3)"
  if [ -x "$UV_BIN" ]; then
    echo "== uv pip toolchain (cache: ${UV_CACHE_DIR:-unset})"
    # --python pins Termux's own bionic interpreter; never `uv python`
    # (uv-managed glibc/musl pythons do not run on Android).
    "$UV_BIN" pip install -p "$PY_BOOT" --upgrade pip setuptools wheel build \
      || { echo "WARN: uv toolchain install failed — falling back to pip"; \
           "$PY_BOOT" -m pip install -q --upgrade pip setuptools wheel build 2>&1 | tail -1 || true; }
  else
    "$PY_BOOT" -m pip install -q --upgrade pip setuptools wheel build 2>&1 | tail -1 || true
  fi
  prefix_cache_save
fi

PY="$(command -v python || command -v python3)"
PYVER_ACTUAL="$("$PY" -V 2>&1)"
echo "== python: $PYVER_ACTUAL"
printf '%s\n' "${PYVER_ACTUAL#Python }" > "$DIST/py-actual.txt"
[ -n "$PYV" ] && [ "$PYV" != "default" ] && \
  [[ "$PYVER_ACTUAL" != *" $PYV"* ]] && \
  echo "WARN: requested python $PYV but got $PYVER_ACTUAL (wheel tag follows the actual one)"

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
