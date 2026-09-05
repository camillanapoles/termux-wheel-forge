# Case study: installing `graphifyy` 0.9.53 on Termux (Android, aarch64)

Real session (Termux, Python 3.14, uv 0.12). `uv tool install graphifyy`
pulls ~30 packages including **25 tree-sitter grammars** and numpy. On
Android none of them have wheels, and the install failed four different ways.
This document is the complete diagnosis→fix record; the repo automates all of
it (`termux-wheel <pkg> <ver>`).

## Failure 1 — sdists missing vendored tree-sitter headers

```
src/parser.c:1:10: fatal error: 'tree_sitter/parser.h' file not found
```

`tree_sitter_json-0.24.8.tar.gz` ships only `src/parser.c` — the
`src/tree_sitter/` header submodule is skipped when the sdist is packed.
The same defect affects cpp/elixir/java/julia/kotlin/php/ruby/typescript/
verilog/zig (ABI 14) and rust/scala (ABI 15).

**Fix:** vendor `parser.h + alloc.h + array.h` into `src/tree_sitter/` of the
extracted sdist.

### The ABI-generation trap

Giving every grammar the same header is **wrong**. The `TSLanguage` struct
differs across grammar generations and the wrong one compiles fine but
corrupts memory at runtime:

| parser.c uses | generation | TSLanguage | header set |
|---|---|---|---|
| `TSLexMode`, `TSFieldMapSlice`, `.version`, no supertypes | ABI 14 | old layout | `patches/headers/abi14/` |
| `TSLexerMode`, `TSMapSlice`, `.abi_version`, `supertype_*` | ABI 15 | extended layout | `patches/headers/abi15/` |

Version check: `grep LANGUAGE_VERSION src/parser.c` (14 or 15).
py-tree-sitter 0.25.x supports both; the *build header* must match the grammar.

**Global shortcut (ABI 14 only):** copy the abi14 trio to
`$PREFIX/include/python3.14/tree_sitter/` — that path is on every extension
build line on Termux (`-I$PREFIX/include/python3.14`), fixing every
header-less ABI-14 grammar at once. ABI-15 grammars (rust 0.24.2, scala
0.26.2) still need their own vendored trio (build local wheels for them).

## Failure 2 — sdists missing the external scanner

Wheel builds, then:

```
ImportError: dlopen failed: cannot locate symbol
"tree_sitter_python_external_scanner_create" referenced by ".../_binding.abi3.so"
```

The sdist lacks `src/scanner.c` (python 0.25.0, c-sharp 0.23.5, lua 0.5.0,
powershell 0.26.4). **Always test imports of built grammars, not just builds.**

**Fix:** fetch `src/scanner.c` from the grammar's GitHub at tag `v<version>`.
Mind the maintainer orgs — lua is `tree-sitter-grammars/tree-sitter-lua`,
powershell is `airbus-cert/tree-sitter-powershell`. Discover from
`Project-URL: Homepage` in `PKG-INFO`.

## Failure 3 — missing `common/scanner.h` (php, typescript)

```
fatal error: '../../common/scanner.h' file not found
```

Multi-language grammars keep shared scanners in a top-level `common/` dir that
is not packed. **Fix:** fetch `common/scanner.h` from the repo into the sdist
root (the relative include then resolves).

## Failure 4 — numpy 2.5.x vs bionic libc

```
npy_math_complex.c.src: error: call to undeclared library function 'cpow'
```

Android's bionic never implemented most `_Complex` math (`cpow`, `cexpl`,
`ccosl`, …). numpy ≥ 2.5 calls them; 2.4.4 does not.

**Fix:** pin `numpy==2.4.4` via constraints:

```bash
echo 'numpy==2.4.4' > constraints.txt
uv tool install graphifyy --find-links <forged-wheels-dir> --constraints constraints.txt
```

## Failure 5 — maturin can't determine Android API level ([gemini] extra)

Installing the extras (`uv tool install graphifyy[gemini]`) pulls `openai` →
`jiter` + `tiktoken` (Rust, maturin backend). On-device builds die with:

```
💥 maturin failed
  Caused by: Failed to determine Android API level. Please set the
ANDROID_API_LEVEL environment variable.
```

**Fix:** `export ANDROID_API_LEVEL=24` (matches the `android_24_arm64_v8a`
wheel tag) before `uv tool install`. The same env var is needed for any
maturin-backed sdist (pydantic-core tolerates its absence; jiter does not).

## Final working recipe (all fixes combined)

```bash
# forged wheels for the 8 broken grammars
for spec in \
  "tree-sitter-rust 0.24.2"       "tree-sitter-scala 0.26.2" \
  "tree-sitter-php 0.23.11"       "tree-sitter-typescript 0.23.2" \
  "tree-sitter-python 0.25.0"     "tree-sitter-c-sharp 0.23.5" \
  "tree-sitter-lua 0.5.0"         "tree-sitter-powershell 0.26.4"; do
  set -- $spec
  termux-wheel "$1" "$2" 3.14     # wheels → ./termux-wheel-out/
done

# global ABI-14 headers (one-time; fixes the other 11 header-less grammars)
mkdir -p "$PREFIX/include/python3.14/tree_sitter"
cp patches/headers/abi14/*.h "$PREFIX/include/python3.14/tree_sitter/"

uv tool install graphifyy \
  --find-links ./termux-wheel-out \
  --constraints <(echo 'numpy==2.4.4')

# with the [gemini] extra (adds openai/tiktoken/jiter): same recipe plus
export ANDROID_API_LEVEL=24   # maturin (jiter) requirement on Termux
uv tool install graphifyy[gemini] \
  --find-links ./termux-wheel-out/_flat \
  --constraints <(echo 'numpy==2.4.4')

# if the tool was already installed, re-inject the scanner-fixed wheels:
uv pip install --python ~/.local/share/uv/tools/graphifyy/bin/python --reinstall \
  ./termux-wheel-out/*/*.whl
```

## Validation (non-negotiable)

```python
# 1. every grammar imports (catches dlopen/scanner breakage)
import tree_sitter_bash, ..., tree_sitter_zig
# 2. real parsing (catches ABI/struct-layout corruption)
from tree_sitter import Language, Parser
t = Parser(Language(tree_sitter_rust.language())).parse(b'fn main() {}')
assert not t.root_node.has_error
# 3. end-to-end
graphify update .
```

Result: 25/25 grammars OK, graph built (14 nodes / 10 edges on the smoke repo),
`graphify` + `graphify-mcp` working on-device.
