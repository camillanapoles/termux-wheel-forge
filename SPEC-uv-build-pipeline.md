# Module Spec: uv-build-pipeline

Status: approved 2026-09-18 · shipped & verified (2026-09-20) · Depends on: —

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
- **Registry writes are main-only** (added 2026-09-20): the "Register wheel in
  registry.json" step no-ops with an explicit NOTE when `GITHUB_REF` is not
  `refs/heads/main`. Rationale: from a branch tip, its `rebase origin/main` +
  `push HEAD:main` would replay the branch's unreviewed commits straight into
  main (a PR-loop bypass), and actions/checkout's depth-1 cut cannot prove
  fast-forward for a branch tip anyway (the old code died there as a confusing
  non-FF "could not push registry.json" failure). Branch dispatches still
  publish the wheel to the Release; main dispatches run the exact original
  code path (byte-for-byte unchanged behavior).

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
  falls back to the full bootstrap (correctness over speed) and is classified into
  `state.txt` (three-state model under Self-heal below). Log lines:
  `== prefix cache: MISS/<reason> (bootstrapping + saving)` / `== prefix cache: HIT
  (restored in Xs)`.
- **Save**: after a bootstrap, tar to `.tmp` then `mv` (no half-written tarball);
  the marker is written LAST — marker+tarball present ⇔ complete save.
  `state.txt` (`hit`|`miss-cold`|`miss-other-minor`|`miss-corrupt`) is dropped in the
  same dir for the workflow.
- **Workflow**: second `actions/cache` on `.prefix-cache`, key
  `prefix-termux-v2-<ISO week>` (same rolling weekly cadence as the uv cache).
  Saved only on primary-key miss + job success (actions/cache default): a HIT run
  never re-tars.
- **Self-heal, three-state model** ("Drop stale prefix cache entry" step, needs
  `actions: write`; updated 2026-09-20): the container classifies every restore
  refusal, and `gh cache delete <key>` fires ONLY on:
  - `miss-corrupt` — marker/tarball present but extraction or verification failed
    (empty/poisoned entry: garbage). Deleting lets the post-job save the fresh
    tarball; entries are immutable per key, so without this a poisoned week stays
    cold until rollover. Non-fatal on failure. An unset classification also
    defaults here (delete): a needless delete of a cold key is a no-op, but a
    surviving garbage entry costs every remaining run of the week.
  - `miss-cold` (never deletes) — nothing was cached at all; there is no entry to
    drop.
  - `miss-other-minor` (never deletes) — entry healthy, but the cached python minor
    ≠ requested (e.g. dispatch asks 3.13 while the week's entry holds 3.14). It is
    still the week's good entry for its own minor and MUST survive: deleting it
    would force every remaining run this week to boot cold (~390s vs ~150s). The
    mismatching run logs the refusal clearly and accepts that its fresh tarball
    cannot re-save under the same key this week.

**Python-minor honesty gate (added 2026-09-20).** Termux's root repo ships ONE
system python per prefix (no side-by-side minors). When a dispatch sets
`python_version=X.Y` that the prefix cannot satisfy (`pkg install python-X.Y`
unavailable; actual interpreter ≠ requested), the build FAILS FAST (exit 9) with an
actionable message instead of building with whatever python is present: the wheel
would carry the actual interpreter's tag while the release path and registry id say
`pyX.Y` — a mislabeled registry entry is worse than a clear error. No fallback
exists; if one is ever added, its registry id MUST be derived from the ACTUAL
interpreter. A cache-HIT run cannot reach the gate (restore already refuses a
minor mismatch with `miss-other-minor`).

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
6. A dispatch with an unsatisfiable `python_version` (e.g. 3.13 while the prefix
   holds 3.14) fails fast with the honesty-gate message, writes
   `state.txt=miss-other-minor`, and the weekly cache entry survives.

## Files

`.github/workflows/build-wheel.yml`, `.github/scripts/docker-build.sh`,
`scripts/build-in-termux.sh`
