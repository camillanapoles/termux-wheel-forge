# Implementation Plan: uv-accelerated builds, artifact store & wheel registry

Implements [`SPEC.md`](../SPEC.md) (+ 4 module specs), approved 2026-09-18.
Tasks recorded in [`tasks/todo.md`](todo.md).

## Overview

Rewrite the build workflow around uv (musl, in-container, cached), publish wheels to
Releases under the `wheel/py<minor>/<pkg>/<ver>` tag pattern, register every build in
`registry.json` via `scripts/registry.py`, and expose `list/url/get/search` in
`bin/termux-wheel`. Four modules in dependency order: `uv-build-pipeline` →
`artifact-store` → `wheel-registry` → `registry-cli`.

## Architecture Decisions

- **Registry in git, binaries in Releases** (approved): `registry.json` is small,
  diffable, offline-queryable; zips/wheels never touch the git tree.
- **uv = installer/cache layer only**, musl static build inside `termux-docker`;
  `--python <Termux interpreter>` always; pip fallback if uv fetch fails.
- **`python -m build --no-isolation`** (deviation from initial spec text, applied
  2026-09-18): build isolation creates a fresh venv and re-downloads setuptools/wheel
  every run under QEMU, bypassing the uv cache entirely; with the toolchain already
  installed via uv, no-isolation is what makes the cache pay off.
- **Idempotent upsert by id** `py{minor}-{pkg}-{ver}`; cross-python overwrite impossible.
- **Registry commit**: direct to `main` with `GITHUB_TOKEN`, `git pull --rebase` →
  re-add → push, 3 attempts (approved 2026-09-18; absorbs concurrent build races).
- **Offline-first testing**: registry logic in pytest; CLI smoke via `--registry`
  fixture; no network in CI lint job.

## Dependency Graph

```
uv-build-pipeline (workflow + docker-build + build-in-termux)
    │
    ├── artifact-store (publish step, same workflow)
    │       │
    │       └── wheel-registry (registry.py + registry.json + commit step)
    │               │
    │               └── registry-cli (termux-wheel subcommands + fixtures + ci smoke)
    │
    └── (ci.yml pytest/smoke steps cut across; added with the tasks that need them)
```

Tasks 1–2 (registry core + CLI) and Task 3 (pipeline) are independent → safe to
parallelize. Task 4 merges them (publish + registry commit in the workflow).

## Task List

### Phase 1: Registry core (offline, TDD) — module `wheel-registry`
- [ ] **Task 1: registry.py + tests + initial registry.json** (S, TDD)
  Acceptance: spec'd commands/add-upsert/exit-codes; pytest green offline.
  Verify: `python3 -m pytest tests/ -q`; hand-run `list/url` on fixture.
  Files: `scripts/registry.py`, `registry.json`, `tests/test_registry.py`.

### Phase 2: CLI control plane — module `registry-cli`
- [ ] **Task 2: termux-wheel subcommands + fixture + ci smoke** (M)
  Acceptance: list/url/get/search with `--registry`/`TWB_REGISTRY`; reserved keywords;
  legacy flow untouched; --help updated.
  Verify: shellcheck; offline smoke vs `tests/fixtures/registry.json` locally and in ci.yml.
  Files: `bin/termux-wheel`, `tests/fixtures/registry.json`, `.github/workflows/ci.yml`.

### **Checkpoint A (offline stack):** pytest + shellcheck + actionlint + offline CLI smoke
green locally; no workflow changes required to pass.

### Phase 3: Pipeline — module `uv-build-pipeline`
- [ ] **Task 3: uv musl + cache + --python inside termux-docker** (M)
  Acceptance: weekly-key `actions/cache` on `.uv-cache/` mounted at Termux cache dir;
  `UV_CACHE_DIR` set; musl uv fetch with pip fallback; every uv call uses `--python`;
  no `uv python`.
  Verify: `actionlint`; `shellcheck`; `bash -n`; grep-guard: no `uv python`, every
  `uv` line has `--python`.
  Files: `.github/workflows/build-wheel.yml`, `.github/scripts/docker-build.sh`,
  `scripts/build-in-termux.sh`.

### Phase 4: Store + registration — module `artifact-store` (+ registry commit)
- [ ] **Task 4: publish to `wheel/py<minor>/<pkg>/<ver>` + registry commit loop** (M)
  Acceptance: Release create-or-reuse + `--clobber` upload; then rebase→add→push ×3
  committing `registry.json`; artifact name unchanged; empty-dist still fails visibly.
  Verify: `actionlint`; shellcheck on embedded run-steps (extracted or inline review);
  dry-run logic of the commit loop locally against a scratch repo.
  Files: `.github/workflows/build-wheel.yml`.

### **Checkpoint B (pipeline complete):** full lint suite green; E2E deferred to a real
dispatch (requires push — user-gated).

### Phase 5: E2E validation (manual, on-device + CI)
- [ ] **Task 5: live dispatch + on-device consume** (S, manual)
  Dispatch `tree-sitter-json 0.24.8` ×2; assert Release, registry commit, uv cache hit,
  `termux-wheel url <id>` → `pip install --no-deps` on device.

### Checkpoint: Complete
- [ ] SPEC.md success criteria 1–7 all verified
- [ ] ci.yml green on GitHub after push

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| uv musl won't run on bionic | Med | static musl build chosen; pip fallback keeps build alive |
| QEMU + uv slow on first (cold cache) run | Low | weekly rolling cache key; expected win from run 2 |
| registry.json push race | Med | rebase→add→push ×3; concurrency group still serializes same-pkg builds |
| actions/cache path ≠ container mount | Med | single source: both derived from Termux home cache path constant |
| Legacy `wheels/<pkg>/<ver>` tags | None | untouched; backfill is ask-first per spec |

## Open Questions

- None blocking. Backfill of legacy releases remains ask-first (SPEC.md).
