---
name: termux-wheel-forge
description: Build and install Python packages/wheels on Termux (Android) when pip/uv fail with C build errors. Use when installing any Python package on an Android/Termux device fails with missing headers (e.g. 'tree_sitter/parser.h' not found), missing external scanners (dlopen 'cannot locate symbol ..._external_scanner_create'), missing includes (common/scanner.h), undeclared libc functions (cpow/cexpl — bionic gaps), or when prebuilt manylinux wheels don't apply. Covers diagnosis, the sdist auto-fixer, the termux-wheel CLI (remote GitHub Actions build in real Termux aarch64), and on-device manual fixes.
---

# Termux Wheel Forge — installing Python packages on Android/Termux

## When to use

Any of these on Termux (`aarch64-linux-android`, bionic libc, no PyPI binary wheels):

- `fatal error: 'X.h' file not found` during sdist build (headers not vendored in the sdist)
- wheel builds fine but `ImportError: dlopen failed: cannot locate symbol "…_external_scanner_create"`
- `error: call to undeclared library function 'cpow'/'cexpl'/…` (function never existed in bionic)
- `uv tool install` / `pip install` fails compiling a dependency from source

Root cause in one line: **PyPI has no Android wheels, so everything builds from
source, and many sdists are quietly incomplete/broken — invisible on
Linux/macOS where prebuilt wheels are used.**

## Step 1 — try the forge first (fast path)

```bash
termux-wheel <package> <version> [python-minor]        # python defaults to machine's
termux-wheel <package> <version> --install             # also installs (--no-deps)
termux-wheel <package> <version> --install --python ~/.local/share/uv/tools/<tool>/bin/python
```

- Repo: `camillanapoles/termux-wheel-forge` (override with `TWB_REPO`/`--repo`)
- Triggers `build-wheel` (workflow_dispatch) → QEMU arm64 + `termux/termux-docker`
  → `scripts/sdist_fixer.py` → wheel artifact + Release `wheels/<pkg>/<ver>`
- If a Release wheel already exists it is downloaded instantly (`--force` to rebuild)
- Wheels land in `./termux-wheel-out/…` tagged e.g. `cp39-abi3-android_24_arm64_v8a`
- Install manually: `uv pip install --no-deps <wheel>` or `python -m pip install --no-deps <wheel>`

## Step 2 — if you must fix on-device (manual)

```bash
pip download --no-deps --no-binary :all: -d . <pkg>==<ver>
tar xf <sdist>.tar.gz && cd <pkg>-<ver>
python3 /path/to/termux-wheel-forge/scripts/sdist_fixer.py --headers /path/to/termux-wheel-forge/patches/headers .
python3 -m build --wheel
```

One-time global fix for the entire tree-sitter header class (ABI 14 generation):

```bash
mkdir -p "$PREFIX/include/python3.14/tree_sitter"      # your python minor
cp .../patches/headers/abi14/{parser,alloc,array}.h "$PREFIX/include/python3.14/tree_sitter/"
```

`$PREFIX/include/python<X.Y>` is on every setuptools extension build line on
Termux, so `#include "tree_sitter/parser.h"` resolves globally afterwards.

## The fixer's decision tree (what it knows)

1. **tree-sitter grammar headers.** If `*/src/parser.c` exists and includes
   `tree_sitter/parser.h` but `src/tree_sitter/` lacks the trio
   (`parser.h, alloc.h, array.h`) → install the **ABI-matched** trio:
   - ABI **14** (parser.c uses `TSLexMode`, `TSFieldMapSlice`, TSLanguage
     field `.version`, no supertype fields)
   - ABI **15** (parser.c uses `TSLexerMode`, `TSMapSlice`, `.abi_version`,
     WITH `supertype_*` fields)
   Never mix generations: the `TSLanguage` struct layouts differ → silent
   memory corruption at runtime. Detect generation by grepping parser.c for
   `TSLexerMode` (15) vs `TSLexMode` (14).
2. **External scanners.** parser.c references `…_external_scanner_create` but
   `src/scanner.{c,cc}` missing → fetch from the grammar's GitHub repo
   (Homepage in `PKG-INFO`), trying tags `v<version>` then `<version>`.
   Without it the wheel builds but fails at import (dlopen).
3. **Scanner includes.** Any unresolvable quoted `#include` inside a scanner
   (classic: `../../common/scanner.h` in tree-sitter-php/typescript) → fetch
   the file at the same repo-relative path.
4. **Bionic libc gaps (NOT fixable by headers).** Android's bionic never
   shipped most `_Complex` functions (`cpow`, `cexpl`, `ccosl`, …). E.g.
   numpy ≥ 2.5 fails in `npy_math_complex.c.src` — pin `numpy<=2.4.4`
   (builds cleanly). See `patches/known.sh` advisories.

## Validation checklist (apply after any grammar fix)

```python
from tree_sitter import Language, Parser
import <grammar>          # must not raise dlopen errors
t = Parser(Language(<grammar>.language())).parse(b'<snippet>')
assert not t.root_node.has_error
```

Multi-grammar tool example (graphifyy): after `uv tool install`, re-install
forged wheels into the tool env with
`uv pip install --python ~/.local/share/uv/tools/<tool>/bin/python --reinstall <wheels>`.

## Known-broken families (as of 2025-09)

- tree-sitter sdists missing header trio: json 0.24.8, cpp 0.23.4, elixir,
  java, julia, kotlin, php, ruby, typescript, verilog, zig (ABI 14);
  rust 0.24.2, scala 0.26.2 (ABI 15)
- missing `src/scanner.c`: tree-sitter-python 0.25.0 (tree-sitter/tree-sitter-python),
  c-sharp 0.23.5 (tree-sitter/tree-sitter-c-sharp), lua 0.5.0
  (tree-sitter-grammars/tree-sitter-lua — NOT org tree-sitter!), powershell
  0.26.4 (airbus-cert/tree-sitter-powershell)
- missing `common/scanner.h`: php 0.23.11, typescript 0.23.2
- numpy: use 2.4.4 (≥2.5 needs cpow — absent in bionic)

Repo URL for repo discovery: parse `Project-URL: Homepage` from the sdist's
`PKG-INFO` (maintainer orgs vary — see lua/powershell above).
