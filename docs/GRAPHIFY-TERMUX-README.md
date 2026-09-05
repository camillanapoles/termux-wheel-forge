# 📖 Guia do usuário: graphify no Termux (Android)

Como **instalar** e **usar** o [graphify](https://github.com/safishamsi/graphify)
num celular/tablet com Termux — do zero até o grafo de conhecimento do seu
projeto. Este guia é o caminho curto do case técnico completo em
[`GRAPHIFYY_CASE.md`](GRAPHIFYY_CASE.md).

> **Estado deste device (2026-09-05):** já instalado e validado —
> `graphifyy[gemini]` 0.9.54, 25/25 gramáticas OK, skill `pi` atualizada.
> Se é o seu caso, pule direto para [Uso diário](#3-uso-diário).

---

## 1. Instalação (uma vez por device)

### 1.1 Pré-requisitos

```bash
pkg update && pkg upgrade
pkg install uv gh rust binutils git
gh auth login        # GitHub (conta gratuita) — usado só p/ baixar as Releases
```

| Pacote | Por quê |
|---|---|
| `uv` | gerenciador Python (tool env isolada) |
| `gh` | baixar os wheels das Releases desta forja |
| `rust` + `binutils` | compilar `jiter`/`tiktoken` do extra `[gemini]` (maturin) |
| `git` | clonar a forja (headers + CLI) |

### 1.2 Forja local (CLI + headers)

```bash
git clone git@github.com:camillanapoles/termux-wheel-forge.git ~/termux-wheel-forge
mkdir -p ~/.local/bin
cp ~/termux-wheel-forge/bin/termux-wheel ~/.local/bin/
```

### 1.3 Headers ABI-14 globais (one-time)

Cobre as gramáticas tree-sitter que vêm sem header no sdist:

```bash
mkdir -p "$PREFIX/include/python3.14/tree_sitter"   # ajuste o minor p/ seu python
cp ~/termux-wheel-forge/patches/headers/abi14/*.h "$PREFIX/include/python3.14/tree_sitter/"
```

### 1.4 Baixar os wheels forjados

As 9 gramáticas problemáticas já têm wheels `android_24_arm64_v8a`
publicados nas Releases:

```bash
mkdir -p ~/termux-wheel-out/_flat && cd ~/termux-wheel-out/_flat
for tag in $(gh release list -R camillanapoles/termux-wheel-forge \
             --limit 60 --json tagName -q '.[].tagName'); do
  gh release download "$tag" -R camillanapoles/termux-wheel-forge \
    -p '*.whl' -D . --clobber
done
```

### 1.5 Variável de ambiente (maturin)

Pacotes Rust via maturin (`jiter`, dep do extra `[gemini]`) exigem o API
level do Android no build:

```bash
echo 'export ANDROID_API_LEVEL=24' >> ~/.bashrc && source ~/.bashrc
```

### 1.6 Instalar

```bash
echo 'numpy==2.4.4' > ~/graphify-constraints.txt   # bionic não tem cpow
uv tool install "graphifyy[gemini]" \
  --find-links ~/termux-wheel-out/_flat \
  --constraints ~/graphify-constraints.txt
```

### 1.7 Skill no agente (pi)

```bash
graphify install --platform pi    # outros: claude, codex, cursor, opencode…
```

### 1.8 Validar (não pule)

```bash
~/.local/share/uv/tools/graphifyy/bin/python - <<'EOF'
import importlib
from tree_sitter import Language, Parser
gs = "bash c cpp c_sharp elixir fortran go groovy java javascript json julia kotlin lua objc php powershell python ruby rust scala swift typescript verilog zig".split()
mods = {g: importlib.import_module(f"tree_sitter_{g}") for g in gs}
print(f"import: {len(mods)}/25 OK")
for g, src, fn in [("rust", b"fn main() { let x = 1; }", "language"),
                   ("python", b"def f():\n    return 42\n", "language"),
                   ("typescript", b"const x: number = 1;", "language_typescript")]:
    t = Parser(Language(getattr(mods[g], fn)())).parse(src)
    assert not t.root_node.has_error, f"parse {g} corrompido!"
    print(f"parse {g}: OK")
import numpy, openai, tiktoken, graphify
print(f"numpy {numpy.__version__} · extra [gemini] OK · TUDO OK")
EOF
```

---

## 2. O que o graphify faz

Transforma qualquer pasta (código, docs, PDFs, imagens, vídeo) num **grafo de
conhecimento persistente** com detecção de comunidades, nós-deuses
(hubs) e trilha de auditoria honesta (arestas EXTRACTED/INFERRED/AMBIGUOUS).
Saídas em `graphify-out/`:

| Arquivo | O que é |
|---|---|
| `graph.html` | grafo interativo (abra no navegador) |
| `GRAPH_REPORT.md` | relatório: comunidades, god nodes, conexões surpreendentes |
| `graph.json` | dados crus (GraphRAG, query/path/explain) |
| `obsidian/` | vault Obsidian (só com `--obsidian`) |

## 3. Uso diário

### No agente (pi) — jeito recomendado

| Comando | Faz o quê |
|---|---|
| `/graphify` | pipeline completo no diretório atual |
| `/graphify <path>` ou `<url-github>` | grafo de um caminho/repo |
| `/graphify query "pergunta"` | busca no grafo existente (BFS/DFS) |
| `/graphify path "A" "B"` | caminho mais curto entre conceitos |
| `/graphify explain "Nó"` | explicação em linguagem natural |
| `/graphify add <url>` | engorda o corpus com uma página |
| flags úteis | `--update` (incremental) · `--mode deep` · `--obsidian` · `--svg` · `--no-viz` |

Se `graphify-out/graph.json` já existe, perguntas sobre o código respondem
**do grafo** (sem reconstruir).

### CLI direto (sem agente)

```bash
graphify update .            # re-extrai código e atualiza o grafo (sem LLM)
graphify watch <dir>         # re-build automático ao salvar arquivos
graphify clone <url-github>  # clona repo p/ ~/.graphify/repos e imprime o path
graphify merge-graphs g1.json g2.json   # grafo cross-repo
graphify diagnose multigraph # auditoria de integridade do grafo
graphify export html|obsidian|svg|graphml|neo4j
```

### Extração semântica (Gemini) — opcional

Sem API key, código é extraído por AST (grátis, sem LLM) e a parte semântica
cai no próprio agente hospedeiro. Para usar Gemini na extração semântica:

```bash
export GEMINI_API_KEY=suakey   # em ~/.bashrc
# modelo: export GRAPHIFY_GEMINI_MODEL=gemini-3-flash-preview
```

## 4. Atualizar / manter

```bash
# nova versão do graphifyy (mantém wheels e constraints):
uv tool install "graphifyy[gemini]" \
  --find-links ~/termux-wheel-out/_flat \
  --constraints ~/graphify-constraints.txt   # uv reusa e atualiza

# pacote novo que quebra na compilação? forje um wheel:
termux-wheel <pacote> <versão> 3.14   # CI constrói e publica na Release
# depois reinstale com --find-links (o wheel novo já entra no _flat via Release)

# atualizar a skill depois de upgrade:
graphify install --platform pi
```

## 5. Troubleshooting

| Sintoma | Causa | Fix |
|---|---|---|
| `fatal error: 'tree_sitter/parser.h' file not found` | headers ABI-14 globais ausentes | passo [1.3](#13-headers-abi-14-globais-one-time) |
| `unknown type name 'TSLexerMode'` | gramática ABI-15 (rust/scala) contra header ABI-14 | wheel forjado no `--find-links` (passo 1.4) |
| `dlopen failed: cannot locate symbol …_external_scanner_create` | sdist sem `scanner.c` | `termux-wheel <pkg> <ver> 3.14` (fixer busca o scanner) |
| `Failed to determine Android API level` | maturin sem env | passo [1.5](#15-variável-de-ambiente-maturin) |
| `error: call to undeclared library function 'cpow'` | numpy ≥ 2.5 no bionic | constraint `numpy==2.4.4` (passo 1.6) |
| gramática importa mas parse dá erro | ABI corrompida (header errado no build) | refaça o wheel do pacote com a forja |

---

*Dúvidas técnicas e diagnóstico completo: [`GRAPHIFYY_CASE.md`](GRAPHIFYY_CASE.md) ·
metodologia geral da forja: [`../README.md`](../README.md).*
