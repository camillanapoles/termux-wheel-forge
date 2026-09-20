# Module Spec: artifact-store

Status: approved 2026-09-18 · shipped & verified (2026-09-20) · Depends on: uv-build-pipeline

## Objective

Persist the built .whl behind a stable public download URL that mirrors the directory
pattern — GitHub Releases as the binary store. No binaries in the git tree.

## Interface (contract with pipeline and registry)

- After a successful build, the workflow attaches `dist/*.whl` to the Release with tag
  `wheel/py<py_requested>/<pkg>/<ver>` (create the Release if absent; upload with
  `--clobber` so rebuilds replace the asset).
- Release title/notes: `<pkg> <ver> — Termux (Android) wheels`, python requested + actual,
  "built in real Termux aarch64 (QEMU)".
- `layout_path` recorded by the registry = `py<minor>/<pkg>/<ver>/` (tag minus the
  `wheel/` prefix) — the directory pattern lives here and in the tag, not as git folders.
- `download_url` (what wheel-registry stores) =
  `https://github.com/<repo>/releases/download/wheel/py<minor>/<pkg>/<ver>/<wheel filename>`
- Build log goes to actions artifacts only, never to the Release.

**Contract with wheel-registry:** on success the workflow calls
`scripts/registry.py add` with the exact asset URL and `layout_path` above.

## Acceptance

1. Fresh build → Release `wheel/py<minor>/<pkg>/<ver>` exists holding exactly the .whl
   asset(s) produced by the build.
2. Rebuild of the same coordinates → assets replaced (`--clobber`), no duplicate Release,
   no duplicate tag.
3. Asset URL downloads anonymously (public repo, no token) and the file is a valid wheel
   (`unzip -t` passes; wheel filename matches canonical
   `<name>-<ver>-<py>-<abi>-<platform>.whl`).
4. `dist/` empty (build produced nothing) → publish step is a no-op, workflow still fails
   visibly per pipeline contract (exit 0 ⇔ wheel exists).

## Files

`.github/workflows/build-wheel.yml` (publish step)
