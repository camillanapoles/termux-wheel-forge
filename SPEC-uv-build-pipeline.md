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

## Prefix cache (toolchain bootstrap checkpoint) — added 2026-09-19

The dpkg bootstrap (`pkg update` + `pkg install python python-pip clang`) under QEMU
dominated the "Build wheel inside real Termux" step (302s baseline). The prefix cache
replaces it on warm runs with a gzip tarball of the toolchain state.
- **What is cached**: `$PREFIX` (`/data/data/com.termux/files/usr`, minus
  `var/cache/apt` and `tmp`) + `$HOME/.local/bin/uv` + `$HOME/.cache/pip`, tarred
  gzip (busybox-safe; no zstd) into host-mounted `.prefix-cache/` (222 MB measured).
- **Restore**: if `marker.txt` + `termux-prefix.tar.gz` both exist (`format=v1` in the
  marker), untar over `/` INSTEAD of the pkg bootstrap, then verify: `python -V`
  (matching the requested minor when given), `clang` present, `uv` executable iff the
  marker recorded `uv=yes`, and `import build, setuptools, wheel`. **Any** failure
  falls back to the full bootstrap (correctness over speed). Log lines:
  `== prefix cache: MISS (bootstrapping + saving)` / `== prefix cache: HIT (restored
  in Xs)`.
- **Save**: after a bootstrap, tar to `.tmp` then `mv` (no half-written tarball);
  the marker is written LAST — marker+tarball present ⇔ complete save.
  `state.txt` (`hit`|`miss`) is dropped in the same dir for the workflow.
- **Workflow**: second `actions/cache` on `.prefix-cache`, key
  `prefix-termux-v2-<ISO week>` (same rolling weekly cadence as the uv cache).
  Saved only on primary-key miss + job success (actions/cache default): a HIT run
  never re-tars.
- **Self-heal** ("Drop stale prefix cache entry" step, needs `actions: write`): if
  the container bootstrapped (`state.txt=miss`) despite a restore — an empty or
  poisoned entry — `gh cache delete <key>` so the post-job can save the fresh
  tarball. Entries are immutable per key; without this, a poisoned week stays cold
  until rollover. Non-fatal on failure.
- **Invalidation**: weekly key rollover (first run of an ISO week re-bootstraps) or
  manual key-version bump (`-v2-` → `-v3-`); bump the marker `format=` only when the
  tarball layout changes.
- **Staleness tradeoff**: toolchain ≤ 7 days old; a stale cache cannot produce wrong
  wheels — verification + fallback cover python-minor mismatch, corruption, and a
  missing toolchain.
- **Container permission model (hard-won)**: the container runs as a non-root user
  whose uid ≠ the runner's. Only `$HOME` is writable in-container — not `/tmp`, not
  plain 755 bind mounts, and not runner-owned 644 files restored by actions/cache
  even inside a 777 dir. Therefore `docker-build.sh` does `chmod -R a+rwX` on
  `.uv-cache` and `.prefix-cache` before `docker run`, and the uv musl tarball is
  downloaded into `$HOME/uv-download` (never `/tmp`), with `pkg install uv` as a
  middle fallback before the pip-toolchain fallback.

Measured (2026-09-19, tree-sitter-json 0.24.8 py3.14): MISS run build step 393s
(bootstrap + tar + upload), HIT run **148s** vs 302s baseline (**-51%**), restore
itself 25s.

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
