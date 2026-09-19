# Task List: uv-accelerated builds, artifact store & wheel registry

Source: `tasks/plan.md` · Specs: `SPEC.md` + `SPEC-{uv-build-pipeline,artifact-store,wheel-registry,registry-cli}.md`

## Phase 1: Registry core
- [x] Task 1: registry.py + tests + initial registry.json
  - Acceptance: add/upsert/get/url/list/search per SPEC-wheel-registry; exit codes 0/1/2; pytest green offline
  - Verify: `python3 -m pytest tests/ -q` → 13 passed; hand-run `list`/`url` against fixture
  - Files: `scripts/registry.py`, `registry.json`, `tests/test_registry.py`

## Phase 2: CLI control plane
- [x] Task 2: termux-wheel list/url/get/search + fixture + ci smoke
  - Acceptance: subcommands work via `--registry`/`TWB_REGISTRY`; legacy flow untouched; --help updated
  - Verify: shellcheck clean; offline smoke vs fixture (list/--pkg/search/url/not-found/legacy exits)
  - Files: `bin/termux-wheel`, `tests/fixtures/registry.json`, `.github/workflows/ci.yml`

### Checkpoint A — DONE (local, 2026-09-18)
- [x] pytest 13/13 + shellcheck clean + YAML parse + offline CLI smoke green

## Phase 3: Pipeline
- [x] Task 3: uv musl + cache + --python inside termux-docker
  - Acceptance: cache mount/UV_CACHE_DIR aligned; musl uv w/ pip fallback; no `uv python`
  - Verify: shellcheck; bash -n; YAML parse; grep-guard (only a comment mentions `uv python`)
  - Files: `.github/workflows/build-wheel.yml`, `.github/scripts/docker-build.sh`, `scripts/build-in-termux.sh`

## Phase 4: Store + registration
- [x] Task 4: publish to wheel/py<minor>/<pkg>/<ver> + registry commit loop
  - Acceptance: create-or-reuse Release, --clobber; rebase→add→push ×3 with empty-commit-safe retry
  - Verify: YAML parse; shellcheck of touched scripts; loop logic reviewed for retry-with-no-diff case
  - Files: `.github/workflows/build-wheel.yml`, `scripts/build-in-termux.sh` (py-actual.txt)

### Checkpoint B — DONE (local, 2026-09-18)
- [x] Full lint suite green; E2E user-gated (needs push)

## Phase 5: E2E (manual, after push)
- [ ] Task 5: live dispatch tree-sitter-json 0.24.8 ×2 + on-device install via `termux-wheel url/get`
  - Depends: push to origin/main (CI runs actionlint + all gates), then `gh workflow run`
