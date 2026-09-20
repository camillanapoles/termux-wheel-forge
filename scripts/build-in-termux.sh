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
  # Every refusal sets CACHE_MISS_REASON so the caller can classify the miss
  # for the workflow's self-heal step:
  #   miss-cold        nothing cached at all — nothing to protect or delete
  #   miss-other-minor entry healthy, holds a different python minor — the
  #                    week's entry MUST survive (still valid for its minor)
  #   miss-corrupt     entry present but failed extraction/verification —
  #                    garbage; deleting it is correct
  if [ ! -e "$CACHE_MARKER" ] && [ ! -e "$CACHE_TARBALL" ]; then
    CACHE_MISS_REASON="miss-cold"; return 1
  fi
  # marker + tarball must both exist and be non-empty; the saver writes the
  # marker last. A half-present/zero-byte pair (e.g. a poisoned entry) is
  # corrupt, not cold: actions/cache restored *something* unusable.
  if [ ! -s "$CACHE_MARKER" ] || [ ! -s "$CACHE_TARBALL" ]; then
    CACHE_MISS_REASON="miss-corrupt"; return 1
  fi
  grep -q "^format=$CACHE_FORMAT$" "$CACHE_MARKER" 2>/dev/null || { CACHE_MISS_REASON="miss-corrupt"; return 1; }
  tar -xzf "$CACHE_TARBALL" -C / || { CACHE_MISS_REASON="miss-corrupt"; return 1; }
  local py pyver
  py="$(command -v python || command -v python3)" || { CACHE_MISS_REASON="miss-corrupt"; return 1; }
  pyver="$("$py" -V 2>&1)" || { CACHE_MISS_REASON="miss-corrupt"; return 1; }
  if [ -n "$PYV" ] && [ "$PYV" != "default" ]; then
    case "$pyver" in
      *" $PYV"*) ;;
      *) echo "  prefix cache holds '$pyver', requested $PYV — entry stays valid for its own minor"
         CACHE_MISS_REASON="miss-other-minor"; return 1 ;;
    esac
  fi
  command -v clang >/dev/null 2>&1 || { CACHE_MISS_REASON="miss-corrupt"; return 1; }
  if grep -q '^uv=yes$' "$CACHE_MARKER" 2>/dev/null; then
    [ -x "$UV_BIN" ] || { CACHE_MISS_REASON="miss-corrupt"; return 1; }
  fi
  # the cached toolchain must be importable, not just present on disk
  "$py" -c 'import build, setuptools, wheel' >/dev/null 2>&1 || { CACHE_MISS_REASON="miss-corrupt"; return 1; }
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
  mkdir -p "$CACHE_DIR"; printf 'hit\n' > "$CACHE_DIR/state.txt"
  echo "== prefix cache: HIT (restored in $(( $(date +%s) - CACHE_T0 ))s)"
else
  if [ -n "${CACHE_MISS_REASON:-}" ]; then
    echo "== prefix cache: restore refused ($CACHE_MISS_REASON) — full bootstrap (correctness over speed)"
    if [ "$CACHE_MISS_REASON" = "miss-other-minor" ]; then
      echo "  note: the weekly entry stays valid for its own minor and will NOT be deleted;"
      echo "        this run's fresh tarball cannot re-save under the same key this week (accepted)"
    fi
  fi
  # state.txt: host-visible classified state — the workflow deletes the weekly
  # entry ONLY on miss-corrupt (miss-cold has nothing to delete; a
  # miss-other-minor entry is the week's good entry for its own minor).
  # Unset reason defaults to miss-corrupt: a needless delete of a cold key is a
  # no-op, but a surviving garbage entry costs every remaining run this week.
  mkdir -p "$CACHE_DIR"; printf '%s\n' "${CACHE_MISS_REASON:-miss-corrupt}" > "$CACHE_DIR/state.txt"
  echo "== prefix cache: MISS/${CACHE_MISS_REASON:-miss-corrupt} (bootstrapping + saving)"
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
    # Download into $HOME: the container user cannot write /tmp (curl used
    # to die with error 23 "client returned ERROR on write" on /tmp/uv.tgz,
    # so uv never installed and the uv cache stayed empty).
    UVDL="$HOME/uv-download"; rm -rf "$UVDL"; mkdir -p "$UVDL"
    if curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-unknown-linux-musl.tar.gz" \
         -o "$UVDL/uv.tgz" \
       && tar -xzf "$UVDL/uv.tgz" -C "$UVDL" \
       && mkdir -p "$(dirname "$UV_BIN")" \
       && install -m 755 "$UVDL/uv-aarch64-unknown-linux-musl/uv" "$UV_BIN"; then
      rm -rf "$UVDL"
    elif pkg install -y uv >/dev/null 2>&1 && command -v uv >/dev/null 2>&1; then
      # Termux-native uv (bionic build). Unify on $UV_BIN for the callers.
      mkdir -p "$(dirname "$UV_BIN")"
      ln -sf "$(command -v uv)" "$UV_BIN" || true
      echo "== uv: installed from the Termux root repo"
    else
      rm -rf "$UVDL"
      echo "WARN: uv fetch failed — falling back to pip"
    fi
  fi
  PY_BOOT="$(command -v python || command -v python3)"
  if [ -x "$UV_BIN" ]; then
    echo "== uv pip toolchain (cache: ${UV_CACHE_DIR:-unset})"
    echo "== uv: $("$UV_BIN" --version 2>&1 | head -1)"
    # --python pins Termux's own bionic interpreter; never `uv python`
    # (uv-managed glibc/musl pythons do not run on Android).
    "$UV_BIN" pip install -p "$PY_BOOT" --upgrade pip setuptools wheel build \
      || { echo "WARN: uv toolchain install failed — falling back to pip"; \
           "$PY_BOOT" -m pip install -q --upgrade pip setuptools wheel build 2>&1 | tail -1 || true; }
    # post-install evidence: did the mounted uv cache actually populate?
    du -sh "${UV_CACHE_DIR:-$HOME/.cache/uv}" 2>/dev/null || true
  else
    "$PY_BOOT" -m pip install -q --upgrade pip setuptools wheel build 2>&1 | tail -1 || true
  fi
  # Python-minor honesty gate (fail fast): Termux ships ONE system python per
  # prefix — if the requested minor could not be satisfied, building anyway
  # would tag the wheel with the actual interpreter while the release/registry
  # label says py$PYV. A mislabeled registry entry is worse than a clear error.
  # (HIT runs can't reach this: restore already refuses a minor mismatch.)
  PY_BOOT_V="$("$PY_BOOT" -V 2>&1)"
  if [ -n "$PYV" ] && [ "$PYV" != "default" ] && [[ "$PY_BOOT_V" != *" $PYV"* ]]; then
    echo "FAIL: requested python $PYV, but this Termux provides '$PY_BOOT_V'."
    echo "      Termux ships a single system python (no side-by-side minors): the wheel"
    echo "      would carry the ${PY_BOOT_V#Python } tag while the registry id says py$PYV."
    echo "      Action: re-dispatch with python_version empty (distro default, currently"
    echo "      $(cut -d. -f1,2 <<<"${PY_BOOT_V#Python }")) — or from a prefix that actually has $PYV."
    cp "$LOG" "$DIST/" 2>/dev/null || true
    exit 9
  fi
  prefix_cache_save
fi

PY="$(command -v python || command -v python3)"
PYVER_ACTUAL="$("$PY" -V 2>&1)"
echo "== python: $PYVER_ACTUAL"
printf '%s\n' "${PYVER_ACTUAL#Python }" > "$DIST/py-actual.txt"

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
