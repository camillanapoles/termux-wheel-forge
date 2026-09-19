# Module Spec: uv-build-pipeline

Status: awaiting approval · Depends on: —

## Objective

Rewrite `.github/workflows/build-wheel.yml` so a 3-arg dispatch (**python_version,
package, version**) produces a Termux-installable .whl inside the real Termux aarch64
container, with uv (static musl) as the cached installer layer.

## Why the container (decided 2026-09-18)

The container reproduces the device environment on purpose (same bionic libc, same
`$PREFIX`, same Termux python), so anything built there installs on-device. Packages that
"cannot build on Termux" become buildable because the forge's patch layer runs inside the
container: `scripts/sdist_fixer.py` + `patches/known.sh` + `ANDROID_API_LEVEL=24`. The
runner contributes resources (RAM/disk/network, no thermal/battery limits) under QEMU.
Runner-native builds are forbidden: they emit glibc wheels that do not install on Termux.

## Interface (workflow contract)

- Inputs (`workflow_dispatch`, type string): `package` (required), `version` (required),
  `python_version` (optional, empty = container default python).
- Steps:
  1. `actions/checkout@v4`
  2. `docker/setup-qemu-action@v3` (platforms: arm64)
  3. `actions/cache` — path `.uv-cache/`, key `uv-termux-v1-<ISO week>` (rolling weekly
     key keeps the cache warm without unbounded growth)
  4. `bash .github/scripts/docker-build.sh "$PKG" "$VER" "$PYV"` — the container adds:
     `-v "$PWD/.uv-cache:/data/data/com.termux/files/home/.cache/uv"` and env
     `UV_CACHE_DIR=/data/data/com.termux/files/home/.cache/uv`
  5. In-container (`scripts/build-in-termux.sh`): fetch uv **musl static aarch64** tarball
     from uv GitHub releases (gnu build will not run on bionic); then
     `uv pip install -p "$PY" --upgrade pip setuptools wheel build`. Fallback to plain
     `pip install` if the uv fetch fails (build must not die on uv unavailability).
     sdist fetch (`pip download --no-deps --no-binary :all:`) and the fixer layer
     unchanged; build runs `python -m build --wheel --no-isolation` — the toolchain
     (setuptools/wheel/build) was installed via the cached uv layer above, and build
     isolation would create a fresh venv that re-downloads deps every run, bypassing
     the cache.
  6. `ANDROID_API_LEVEL=24` exported before build (already implemented 2026-09-18).
- Concurrency group: `build-${{ inputs.package }}-${{ inputs.version }}` (unchanged).
- Build log uploaded as actions artifact (`if: always()`).

**Contract with artifact-store:** workflow step exit 0 ⇔ `dist/` contains ≥ 1 `*.whl`.

## Acceptance

1. `actionlint` clean on the rewritten workflow.
2. First dispatch builds `tree-sitter-json 0.24.8`; the second dispatch logs a uv cache
   hit and finishes measurably faster.
3. Every uv invocation passes `--python <Termux interpreter>`; no `uv python` anywhere.
4. uv fetch failure degrades to pip without failing the build.
5. Wheels produced carry the Termux/Android tags (e.g.
   `cp314-cp314-android_arm64_v8a`), never glibc (`manylinux`).

## Files

`.github/workflows/build-wheel.yml`, `.github/scripts/docker-build.sh`,
`scripts/build-in-termux.sh`
