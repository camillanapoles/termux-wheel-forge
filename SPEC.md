# Spec: termux-wheel-forge — uv-accelerated builds, artifact store & wheel registry

Status: **awaiting approval** · Map approved: 2026-09-18
Decisions locked: storage=**Releases + registry.json in git** · format=**.whl as-is** ·
CLI=**extend `termux-wheel`** · uv=**inside Termux container only**

## Objective

Make it one command to get a Python wheel that Termux cannot build natively — faster, and
with a queryable catalog:

1. A GitHub Action takes 3 args (from CLI on-device or workflow inputs): **python minor,
   package, version**. Python minor is captured from the calling environment by the CLI.
2. The build runs inside real Termux aarch64 (docker + QEMU) with **uv as the cached
   package layer** — the "warm machine checkpoint" that makes repeat builds fast.
3. On success the **.whl is attached to a GitHub Release** whose tag mirrors the directory
   pattern `wheel/py<minor>/<pkg>/<ver>`.
4. Every build is **upserted into `registry.json`** (committed to the repo) with a **unique
   id**, download URL, and metadata. The registry is the control plane: list all, list by
   module, search, and resolve id → download URL.
5. Final user-facing output is always a **download URL of a wheel installable on Termux**.

Users: (a) Termux/Android user on-device installing wheels; (b) repo maintainer driving
builds from CI.

## Why build inside a Termux container (and not a normal runner)

The container reproduces the device environment **on purpose** — same bionic libc, same
`$PREFIX`, same Termux python — so anything that builds there installs on-device. The
packages Termux "cannot build" become buildable because the forge ships the patch layer
that runs inside the container: `scripts/sdist_fixer.py` (missing headers/scanners),
`patches/known.sh` (bionic advisories), `ANDROID_API_LEVEL=24` (maturin). The runner adds
resources the phone lacks (RAM/disk/network, no battery/thermal limits). A glibc runner
would build easily and produce wheels that do not install on Termux — forbidden.

## Tech Stack

| Layer | Choice | Why / constraint |
|---|---|---|
| CI runner | GitHub Actions `ubuntu-latest` + `docker/setup-qemu-action@v3` | existing pattern |
| Build container | `termux/termux-docker:latest` (aarch64, QEMU) | wheels must target Android bionic |
| Accelerator | **uv**, static **musl** aarch64 build, in-container; cache persisted via `actions/cache` | gnu build won't run on bionic; cache = warm machine |
| Python for builds | Termux's own python (`--python` passed to uv pip; **no `uv python` management**) | uv-managed pythons are glibc/musl, not bionic |
| Build frontend | `python -m build` (unchanged) + `pip download` for sdist fetch | boring; uv wins at install/cache layer |
| Binary store | GitHub Releases, tag `wheel/py<minor>/<pkg>/<ver>`, asset = canonical `.whl` | no git-tree binaries |
| Control plane | `registry.json` in repo root, `schema_version: 1`, mutated by `scripts/registry.py` (stdlib-only) | list/get/search by id and by module |
| CLI | `bin/termux-wheel` (bash) gains subcommands `list/url/get/search` | single binary on-device |
| Tests | `pytest` (registry logic + offline CLI smoke via fixture registry) | CI-runnable, no network |
| Lint | `shellcheck -x`, `actionlint` (pinned 1.7.12), `py_compile` | existing ci.yml, extended |

**Hard constraints**
- Wheels MUST be built inside `termux/termux-docker` aarch64. Runner-native uv produces
  glibc wheels that do not install on Termux — forbidden.
- uv is the installer/cache layer only. Never `uv python install` in this pipeline.
- No binary artifacts (.whl/.zip) committed to the git tree, ever.

## Commands

```bash
# on-device: build end-to-end (captures local python minor automatically)
termux-wheel tree-sitter-json 0.24.8 3.14

# on-device: registry control plane (no build)
termux-wheel list                                   # all entries
termux-wheel list --pkg tree-sitter-json            # by module
termux-wheel search json                            # substring over pkg/id
termux-wheel url py3.14-tree-sitter-json-0.24.8     # id → download URL
termux-wheel get py3.14-tree-sitter-json-0.24.8 --install  # download (+install)

# registry script (CI + local; --registry overrides path, default ./registry.json)
python3 scripts/registry.py add --pkg P --ver V --py 3.14 --py-actual 3.14.0 \
        --wheel NAME.whl --url https://... [--layout py3.14/P/V/]
python3 scripts/registry.py list [--pkg P] | get <id> | url <id> | search TERM

# CI trigger (manual)
gh workflow run build-wheel.yml -f package=tree-sitter-json -f version=0.24.8 \
   -f python_version=3.14

# tests & lint (local == ci.yml)
python3 -m pytest tests/ -q
shellcheck -x bin/termux-wheel scripts/*.sh patches/known.sh
actionlint
```

## Project Structure

```
bin/termux-wheel                  → CLI: legacy build flow + list/url/get/search subcommands
scripts/build-in-termux.sh        → in-container build (uv toolchain, ANDROID_API_LEVEL)
scripts/registry.py               → registry CRUD/queries; stdlib only; pure functions + thin CLI
scripts/sdist_fixer.py            → existing auto-patcher (unchanged)
patches/known.sh                  → existing advisories (unchanged)
registry.json                     → versioned index (control plane); schema_version 1
tests/test_registry.py            → pytest for registry.py
tests/fixtures/registry.json      → fixture for offline CLI smoke
.github/workflows/build-wheel.yml → rewritten: 3-arg dispatch, uv+cache, store, registry commit
.github/workflows/ci.yml          → lint gates (extended with pytest)
```

## Code Style

Bash (as established in `bin/termux-wheel`): `set -euo pipefail`, `die()` helper,
shellcheck-clean, keyword subcommand dispatch:

```bash
case "${1:-}" in
  list|url|get|search) REGISTRY_MODE=1; shift ;;   # reserved keywords; legacy positional path untouched
esac
```

Python (`scripts/registry.py`): stdlib only, pure functions separated from I/O, argparse,
snake_case, upsert is a pure transform:

```python
def upsert(entries: list[dict], entry: dict) -> list[dict]:
    """Replace by id or append. Pure; caller owns file I/O."""
    others = [e for e in entries if e["id"] != entry["id"]]
    return sorted(others + [entry], key=lambda e: e["built_at"])
```

Registry entry shape (canonical example):

```json
{
  "id": "py3.14-tree-sitter-json-0.24.8",
  "pkg": "tree-sitter-json",
  "ver": "0.24.8",
  "py_requested": "3.14",
  "py_actual": "3.14.0",
  "wheel": "tree_sitter_json-0.24.8-cp314-cp314-android_arm64_v8a.whl",
  "layout_path": "py3.14/tree-sitter-json/0.24.8/",
  "download_url": "https://github.com/OWNER/REPO/releases/download/wheel/py3.14/tree-sitter-json/0.24.8/tree_sitter_json-0.24.8-cp314-cp314-android_arm64_v8a.whl",
  "built_at": "2026-09-18T12:00:00Z",
  "created_at": "2026-09-18T12:00:00Z",
  "run_id": 1234567890
}
```

Id rule: `py{py_requested}-{pkg}-{ver}`. Rebuild of the same id → upsert (one entry;
`created_at` preserved, `built_at`/`run_id` refreshed). Rebuild with a *different* python
minor is a **different id** — never overwrite across pythons.

## Testing Strategy

- `tests/test_registry.py` (pytest): add-new-id appends; rebuild same id upserts (1 entry,
  created_at preserved, built_at updated); `list --pkg` filters; `search` matches pkg and
  id substring; `url <id>` prints `download_url`; missing id exits non-zero; malformed
  entry rejected with clear error. No network, temp-dir fixtures.
- CLI smoke (in `ci.yml`, offline): `termux-wheel list|url|get` against
  `tests/fixtures/registry.json` via `--registry`; keyword dispatch; legacy positional
  path still exits correctly without gh/auth.
- `actionlint` on both workflows; `shellcheck -x` on all shell; `py_compile` both scripts.
- E2E (manual, after implementation): dispatch build of `tree-sitter-json 0.24.8`; assert
  Release tag exists, .whl asset downloads, `registry.json` gains the entry, second run
  shows uv cache hit and shorter wall time, `termux-wheel url <id>` yields a URL that
  `pip install --no-deps <url>` accepts on-device.

## Boundaries

- **Always:** register every successful build in `registry.json`; keep tag/asset/layout
  pattern in sync; run `pytest` + `shellcheck` + `actionlint` before commits; pass
  `--python` (Termux interpreter) to every uv invocation.
- **Ask first:** registry schema change (`schema_version` bump); storage backend change;
  deleting/retiring registry entries; backfilling pre-existing `wheels/<pkg>/<ver>`
  releases into the registry; changing the build container image.
- **Never:** commit .whl/.zip binaries to the git tree; register a runner-native (glibc)
  wheel; build with `uv python`-managed interpreters; overwrite a registry entry across
  different python minors.

## Success Criteria

1. `gh workflow run build-wheel.yml -f package=P -f version=V -f python_version=3.14` ends
   with Release `wheel/py3.14/P/V` holding the .whl, and `registry.json` committed with
   the new id.
2. `termux-wheel url py3.14-P-V` prints the asset URL; downloading it and running
   `pip install --no-deps <file>` succeeds on Termux.
3. `termux-wheel list`, `list --pkg`, `search` work from-device with no auth (public raw
   fetch of `registry.json`).
4. Second build of the same package/version logs a uv cache hit and completes faster than
   the first.
5. Rebuilding the same (pkg, ver, py) never duplicates registry entries.
6. `ci.yml` green: shellcheck, actionlint, py_compile, pytest, offline CLI smoke.
7. Legacy flow unchanged: `termux-wheel P V` without subcommand still triggers, waits,
   downloads (now additionally registered).

## Open Questions

- Registry write race (two different packages finishing concurrently): plan is
  `git pull --rebase` + re-add + push with bounded retries inside the workflow. Acceptable?
- Auto-commit straight to `main` with `GITHUB_TOKEN` (current `contents: write`) vs
  registry PRs. Default: direct commit. Flag if you want PRs.
- Backfill of legacy `wheels/<pkg>/<ver>` releases into `registry.json`: deferred,
  ask-first.

## Module Specs

- [`SPEC-uv-build-pipeline.md`](SPEC-uv-build-pipeline.md)
- [`SPEC-artifact-store.md`](SPEC-artifact-store.md)
- [`SPEC-wheel-registry.md`](SPEC-wheel-registry.md)
- [`SPEC-registry-cli.md`](SPEC-registry-cli.md)
