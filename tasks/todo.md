# Task List: uv-accelerated builds, artifact store & wheel registry

Source: `tasks/plan.md` · Specs: `SPEC.md` + 4 module specs · Loop: github-ops-cicd (PR #1 merged adfbe92)

## Status: TODAS AS TASKS EXECUTADAS — SC1–SC7 com evidência real

- [x] Task 1–4 (implementação + verificação local: pytest 13/13, shellcheck 0.11, YAML, smoke)
- [x] Task 5 E2E:
  - PR #1: 🔴 SC2015 → fix → 🟢 (lint ×2) → merged `adfbe92`
  - dispatch #1 (35450396630, 312s): Release `wheel/py3.14/tree-sitter-json/0.24.8` ✓ · registry commit `3166d53` ✓ · cache cold miss + saved
  - dispatch #2 (35450792009, 328s): `Cache hit for: uv-termux-v1-2026-W38` ✓ · build 302s vs 301s → **sem speedup material** (dominado por pkg bootstrap + compilação sob QEMU, fora do cache)
  - registry idempotente ao vivo: re-run → 1 entrada, diff 2 linhas (`f67fc8e`)
  - on-device (Termux real): `list` sem auth ✓ · `url` → URL canônica ✓ · `get` baixou ✓ · wheel zip válido ✓ · `pip install --no-deps --target` rc=0 ✓

## Incremento 2 (2026-09-19): prefix cache — EXECUTADO, SC-A..SC-D verdes

Design aprovado pelo main agent (design handed-down); spec: seção "Prefix cache" em
`SPEC-uv-build-pipeline.md`.

- PRs: **#4** `6320c0f` (feature) → **#5** `65c3e24` (mount 0777) → **#6** `6a6be3d`
  (self-heal + v2 keys + uv fix) → **#7** `b2f168b` (chmod -R a+rwX)
- Bugs reais encontrados e corrigidos pelo caminho (todos com evidência de log):
  1. container roda como não-root com uid ≠ runner → mounts 755 e `/tmp` graváveis
     só pelo runner (curl uv morria com erro 23 no `/tmp`; tar do cache: Permission
     denied) → chmod nos mounts + download do uv em `$HOME/uv-download`
  2. entrada de cache vazia (0 MB) salva antes do fix "envenena" a chave semanal
     (entradas são imutáveis por chave; post-job se recusa a re-salvar em hit) →
     bump v1→v2 + passo self-heal (`gh cache delete` quando state=miss)
  3. arquivos restaurados pelo actions/cache ficam 644 do runner → container não
     conseguia sobrescrever o `state.txt` → run B deletou a entrada BOA (35462492046)
     → `chmod -R a+rwX` (PR #7); B3 confirmou: entrada sobreviveu
  - uv nunca tinha rodado (cache uv 0 MB desde o dia 1) — mesma causa raiz de 1;
    agora roda (`uv 0.12.17 musl`), cache `uv-termux-v2-2026-W38` = 1.05 MB
- Medição final (tree-sitter-json 0.24.8, py3.14, após PR #7):
  - **#A 35462789961**: `Cache not found: prefix-termux-v2-2026-W38` →
    `== prefix cache: MISS (bootstrapping + saving)` → `saved (223M)` → entrada
    `prefix-termux-v2-2026-W38` = **221.89 MB** ✓ · build step 393s (bootstrap+tar+upload)
  - **#B 35463197195**: `Cache hit for: prefix-termux-v2-2026-W38` →
    `== prefix cache: HIT (restored in 25s)` · build step **148s vs baseline 302s
    (-51%)** ✓ · entrada sobreviveu ao run ✓
  - wheel `tree_sitter_json-0.24.8-cp39-abi3-android_24_arm64_v8a.whl` idêntico ✓ ·
    registry.json: 1 entrada (`created_at` preservado, `built_at`/`run_id` B3) ✓
- SC-A ✓ (CI verde nos 4 branches) · SC-B ✓ (MISS+save / HIT 148s ≤ 180s) ·
  SC-C ✓ · SC-D ✓ (spec + este WAL)

### Próximos follow-ups

- [ ] MISS runs ficaram mais lentos (393s vs 302s: tar+upload do 223M). Se doer:
      gzip -1, ou excluir mais payload do tarball.
- [ ] `WARN: package python-3.14 not available` apareceu no run A3 (default python
      é 3.14.6, tag igual) — investigar repos do Termux se voltar a importar.
