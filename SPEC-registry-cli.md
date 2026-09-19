# Module Spec: registry-cli

Status: awaiting approval · Depends on: wheel-registry

## Objective

Extend `bin/termux-wheel` with the on-device registry control plane — `list`, `url`,
`get`, `search` — while keeping the existing build flow behaviorally unchanged (it now
additionally registers builds). Python-minor capture from the calling environment stays
as implemented.

## Interface

- Subcommand dispatch on the first positional argument when it is a reserved keyword:
  `list|url|get|search`. Any other first positional → legacy build flow
  (`termux-wheel <pkg> <ver> [py-minor] [options]`) untouched.
- Registry source: `https://raw.githubusercontent.com/<repo>/main/registry.json` via
  `curl -fsSL` (public, no auth). `--registry PATH` or env `TWB_REGISTRY` overrides
  (file path or URL) — this is what makes offline tests possible.
- Commands:
  - `list [--pkg P]` → aligned table: `id  py  pkg  ver  built_at`.
  - `search TERM` → same table, filtered by substring on pkg or id.
  - `url <id>` → prints the download URL, single line, nothing else (pipe-friendly).
  - `get <id> [--install] [--python PATH] [--force]` → downloads the .whl into
    `$TWB_OUTDIR/<id>/` (default `./termux-wheel-out/<id>/`) and, with `--install`,
    reuses the existing `do_install` machinery (uv or pip with `--python`, fixed
    2026-09-18).
- Errors: unknown id, unreachable registry, or non-200 fetch → clear `die()` message,
  non-zero exit, no partial output on stdout for `url`.
- No new dependencies: `curl` (or `gh`, already required) and `python3` only.

## Acceptance

1. Offline smoke in `ci.yml`: `list`, `list --pkg`, `search`, `url`, `get` against
   `tests/fixtures/registry.json` via `--registry` — correct stdout, correct exit codes
   (including not-found).
2. Legacy paths intact: `termux-wheel P V` still reaches the trigger step;
   `termux-wheel` (no args) and `termux-wheel P V --bogus` still exit non-zero;
   `--help` documents the new subcommands.
3. `shellcheck -x` clean; keyword dispatch cannot be shadowed by a package name (reserved
   keywords documented in help).

## Files

`bin/termux-wheel`, `tests/fixtures/registry.json`, `.github/workflows/ci.yml`
(smoke step)
