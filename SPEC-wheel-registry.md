# Module Spec: wheel-registry

Status: approved 2026-09-18 · shipped & verified (2026-09-20) · Depends on: artifact-store

## Objective

`registry.json` is the versioned control plane: one entry per built wheel with a unique
id, download URL, and metadata — queryable by the CLI and by humans. Mutations go through
`scripts/registry.py`: stdlib only, pure functions plus a thin argparse CLI.

## Interface

- Schema `schema_version: 1`; entry fields exactly as in `SPEC.md` (id, pkg, ver,
  py_requested, py_actual, wheel, layout_path, download_url, built_at, created_at,
  run_id).
- Id rule: `py{py_requested}-{pkg}-{ver}`.
- Commands (`--registry PATH` overrides file, default `./registry.json`):
  - `add --pkg P --ver V --py 3.14 --py-actual 3.14.0 --wheel NAME.whl --url URL
    [--layout py3.14/P/V/] [--run-id N]` → upsert.
  - `get <id>` → prints the JSON entry.
  - `url <id>` → prints `download_url` (single line, nothing else).
  - `list [--pkg P]` → all entries / filtered by module.
  - `search TERM` → entries where pkg or id contains TERM (case-insensitive).
- Upsert semantics: same id replaces in place (`created_at` preserved, `built_at` +
  `run_id` refreshed, file stays sorted by `built_at`); a different python minor yields a
  different id — cross-python overwrite is impossible by construction.
- CI write path: after the publish step, the workflow commits `registry.json` to `main`
  with `GITHUB_TOKEN` (`contents: write` already granted). Concurrent-build races are
  absorbed by a bounded loop: `git pull --rebase` → re-run `registry.py add` → push,
  up to 3 attempts.
- Exit codes: `0` ok · `1` usage error / id not found · `2` schema violation (missing
  field, bad JSON, wrong types).
- Validation: `add` refuses entries missing required fields or with a `download_url` not
  matching the Release-URL shape; refuses to mutate the file when `schema_version` is
  newer than supported.

## Acceptance

1. `tests/test_registry.py` covers: add-new appends; rebuild same id upserts to exactly
   one entry with `created_at` preserved; `list --pkg` filters; `search` matches pkg and
   id substrings; `url <id>` prints only the URL; unknown id exits 1; malformed entry
   exits 2; file remains valid JSON sorted by `built_at` after every operation. All
   offline (tmp_path fixtures).
2. `python3 -m pytest tests/ -q` green in `ci.yml` with no network.
3. Hand check: after one real build, `registry.json` diff shows exactly one added object
   and no reformatting of unrelated lines.

## Files

`scripts/registry.py`, `registry.json`, `tests/test_registry.py`,
`.github/workflows/ci.yml` (pytest step), `.github/workflows/build-wheel.yml`
(registry commit step)
