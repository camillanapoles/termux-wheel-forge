# 🔨 termux-wheel-forge

**One command → a Python wheel that actually installs on Termux (Android).**

```bash
termux-wheel <package> <version> [python-minor]
```

PyPI has no `android_arm64` wheels, so on Termux every C extension must build
from source — and many popular sdists are quietly **broken** on Android
(missing headers, missing scanners, libc functions that bionic never shipped).
This repo fixes that:

1. you run `termux-wheel tree-sitter-rust 0.24.2 3.14` on your phone,
2. it triggers a GitHub Actions workflow that builds inside a **real Termux
   aarch64 rootfs** (QEMU-emulated on the runner),
3. an **auto-fixer** patches the known sdist breakage (tree-sitter headers,
   missing scanners, missing includes…),
4. you get back a tagged wheel (`…-android_24_arm64_v8a.whl`) — as a workflow
   artifact **and** a permanent GitHub Release asset (so the second install of
   the same package is instant, no rebuild).

```text
 your phone                GitHub Actions                      your phone
┌────────────┐   trigger  ┌──────────────────────────┐  wheel  ┌──────────────┐
│ termux-wheel├───────────►│ QEMU arm64 + termux-docker├─────────► uv pip install│
└────────────┘  workflow  │ sdist → autofix → build  │ release └──────────────┘
                          └──────────────────────────┘
```

---

## Install the CLI (Termux)

```bash
pkg install gh          # once, and: gh auth login
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/camillanapoles/termux-wheel-forge/main/bin/termux-wheel \
  -o ~/.local/bin/termux-wheel
chmod +x ~/.local/bin/termux-wheel
```

## Usage

```bash
# 2 mandatory args: package + version (python defaults to this machine's)
termux-wheel tree-sitter-json 0.24.8

# explicit python minor (wheel tag follows it; abi3 wheels work across 3.x)
termux-wheel tree-sitter-rust 0.24.2 3.14

# also install it afterwards (uses --no-deps)
termux-wheel numpy 2.4.4 --install

# install straight into a uv tool env (e.g. the graphifyy case study):
termux-wheel tree-sitter-lua 0.5.0 --install \
  --python ~/.local/share/uv/tools/graphifyy/bin/python
```

Options: `--install` · `--python PATH` (target env for `--install`) ·
`--force` (rebuild even if a Release wheel exists) · `--repo OWNER/NAME`
(default `camillanapoles/termux-wheel-forge`, or `$TWB_REPO`).

Wheels land in `./termux-wheel-out/<pkg>-<ver>-py<minor>/` and are published
to Releases under the tag `wheels/<pkg>/<ver>`.

## What the auto-fixer handles

| Problem (symptom) | Packages seen | Fix |
|---|---|---|
| sdist missing `src/tree_sitter/parser.h` (`fatal error: 'tree_sitter/parser.h' file not found`) | tree-sitter-json/cpp/java/ruby/julia/kotlin/… | vendor the header trio (`parser.h, alloc.h, array.h`), **ABI-matched** to the grammar generation (ABI 14 vs 15 have different `TSLanguage` layouts — mixing them corrupts the struct) |
| sdist missing `src/scanner.c` (wheel builds, then `dlopen failed: cannot locate symbol …_external_scanner_create`) | tree-sitter-python / c-sharp / lua / powershell | fetch scanner from the grammar's GitHub repo (tag `v<version>`) |
| sdist missing `common/scanner.h` (`fatal error: '../../common/scanner.h' file not found`) | tree-sitter-php / typescript | fetch the missing include from the GitHub repo |
| bionic libc gaps (e.g. numpy ≥ 2.5 uses `cpow`, absent in Android) | numpy | advisories + known-good pins (`numpy<=2.4.4`) |

Advisories live in [`patches/known.sh`](patches/known.sh); add new cases there.
The full methodology is documented for humans in
[`docs/GRAPHIFYY_CASE.md`](docs/GRAPHIFYY_CASE.md) and for LLM agents in
[`SKILL.md`](SKILL.md).

## Building manually (no CI), on-device

Everything runs on-device too — this is exactly what CI automates:

```bash
git clone https://github.com/camillanapoles/termux-wheel-forge
cd termux-wheel-forge
mkdir -p work && cd work
pip download --no-deps --no-binary :all: -d . tree-sitter-rust==0.24.2
tar xf tree_sitter_rust-0.24.2.tar.gz && cd tree_sitter_rust-0.24.2
python3 ../scripts/sdist_fixer.py --headers ../patches/headers .
python3 -m build --wheel
```

Tip — a one-time global fix for the tree-sitter header class of errors
(makes every ABI-14 header-less grammar build without any patching):

```bash
mkdir -p "$PREFIX/include/python3.14/tree_sitter"   # match your python minor
cp patches/headers/abi14/*.h "$PREFIX/include/python3.14/tree_sitter/"
```

That directory is on every setuptools extension build line on Termux, so
`#include "tree_sitter/parser.h"` resolves for any grammar.

## Case study: installing `graphifyy` (25 tree-sitter grammars) on Termux

See [`docs/GRAPHIFYY_CASE.md`](docs/GRAPHIFYY_CASE.md). Short version:

```bash
uv tool install graphifyy \
  --find-links <dir-with-forged-wheels> \
  --constraints <(echo 'numpy==2.4.4')
```

With this repo, the eight broken grammars are simply:

```bash
for gv in "tree-sitter-rust 0.24.2" "tree-sitter-scala 0.26.2" \
          "tree-sitter-php 0.23.11" "tree-sitter-typescript 0.23.2" \
          "tree-sitter-python 0.25.0" "tree-sitter-c-sharp 0.23.5" \
          "tree-sitter-lua 0.5.0" "tree-sitter-powershell 0.26.4"; do
  termux-wheel $gv 3.14
done
```

## Limitations

- Android wheels built here target the **device-compatible** tag
  (`android_24_arm64_v8a` / `cp3XX`), not Google's abandoned `android` PyPI
  platform tags — install them by file path, not from PyPI.
- Packages needing external native libs (openblas, openssl…) need those libs
  present (`pkg install …`) — advisories remind you.
- Runtime-only breakage (like the missing-scanner dlopen case) is fixed
  because the fixer knows the pattern; truly package-specific bugs need a
  patch in this repo — PRs welcome.

## For AI agents

[`SKILL.md`](SKILL.md) is an installable agent skill with the complete
diagnosis→fix decision tree for Python packaging on Termux. Point your agent
at this repo, or copy `SKILL.md` into your skills directory.

## License

MIT © Camilla Napoles

---

### Nota (pt-BR)

Criado durante uma sessão real de debugging no Termux (instalação do
`graphifyy`, 25 grammars tree-sitter + numpy quebrados). Se um `pip install` /
`uv tool install` falhar no seu Android com erro de compilação C, rode
`termux-wheel <pacote> <versão>` — o CI reconstrói com os patches e devolve o
wheel compatível.
