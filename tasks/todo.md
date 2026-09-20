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

## Incremento 3 (2026-09-20): breadth — segundo pacote via CLI + fix de clobber no download

Segundo pacote validado end-to-end pelo caminho do usuário (CLI
`bin/termux-wheel`): **tree-sitter-scala 0.26.2, py3.14** (escolhido de
`termux-wheel-out/`; release legada `wheels/tree-sitter-scala/0.26.2` existia,
então `--force` para forçar build QEMU real em vez do fast path).

- Bugs reais encontrados e corrigidos pelo caminho (com evidência de log):
  1. `gh run download` não tem clobber (ao contrário do fast path
     `gh release download --clobber`): run **35526622254** — build/publish/
     registry OK no server, mas o download local morreu com
     `error extracting zip archive: ... file exists` (wheel pré-existente do
     trabalho manual) → **PR #9** `de597f7` (parcial: limpava `*.whl`/`*.log`)
     → **PR #10** `0de45b6` (completo: `rm -rf "$DEST"`; o artefato `dist/*`
     também carrega `py-actual.txt`, que a extração parcial do run falho
     deixou para trás e o fix parcial não cobria)
  - CI: 35527066008 ✓ · 35527181122 ✓ · prova e2e = re-dispatch (run B)
- Medição (build step "Build wheel inside real Termux (aarch64)"):
  - **#A 35526622254**: `== prefix cache: HIT (restored in 25s)` · build **197s**
  - **#B 35527218210**: `== prefix cache: HIT (restored in 25s)` · build **198s**
  - 197/198s vs 148s ontem (mesmo HIT/25s) = **variância observada do runner
    sob QEMU (n=1 por lado), NÃO conclusão de regressão** — mesmo comportamento
    de cache nos dois dias
- Registry idempotente ao vivo: 2 entradas · json intocado (`created_at`
  `2026-09-19T15:04:46Z`) · scala `created_at` preservado (2026-09-20T17:44:05Z),
  `built_at`/`run_id` refreshed (17:55:28Z / 35527218210) ✓
- Release `wheel/py3.14/tree-sitter-scala/0.26.2` ✓ (asset 489.918 B, re-upload
  clobber no run B) · nota: `created_at` da release herda timestamp do tag
  (tag órfã da sessão de ontem; json mostra o mesmo padrão)
- on-device (Termux real): `list` 2 ids ✓ · `url` ✓ · wheel zip válido
  (10 entradas, CRC ok) ✓ · `pip install --no-deps --target` **rc=0** ✓
  (dist-info: METADATA/RECORD/WHEEL) — ambiente live intacto


## Incremento 4 (2026-09-20): prefix-cache guard de 3 estados + fail-fast de minor

Defect (diretor, lendo o workflow): o passo "Drop stale prefix cache entry" deletava a
entrada semanal em QUALQUER `miss` — inclusive no cross-minor (dispatch py3.13 contra
entrada 3.14), destruindo a entrada BOA da semana (~390s cold vs ~150s hit por run
restante). PR **#13** `fix/prefix-cache-guard` (`447c9ec` feature + `0a3ee08` lint):

1. `build-in-termux.sh`: `prefix_cache_restore` classifica cada recusa em
   `CACHE_MISS_REASON` → `state.txt` ∈ {hit, miss-cold, miss-other-minor, miss-corrupt};
   par meio-presente/0-byte = corrupt (não cold — actions/cache restaurou algo
   inutilizável); default não-classificado = miss-corrupt (delete de chave fria é no-op,
   entrada podre custa a semana toda).
2. `build-wheel.yml`: self-heal dispara SÓ em `^miss-corrupt$` ancorado (comentário
   documenta os 3 estados e por que miss-other-minor DEVE sobreviver).
3. Fail-fast honesto (exit 9, sem fallback): minor solicitado insatisfatível → mensagem
   acionável em vez de wheel cp314 registrado como py3.13 (metadada mentirosa é pior
   que erro claro). Válvula após o bootstrap, ANTES do `prefix_cache_save` (evita re-tar
   inútil de 223 MB); inalcançável em HIT (restore já recusa com miss-other-minor).
   Espec: qualquer fallback futuro DEVE derivar o id do interpretador REAL.
4. SPEC-uv-build-pipeline.md: self-heal em 3 estados + honesty gate + critério 6.

Evidência (dispatches no branch, exercitando o código do fix):
- **#1 35533973087** (py3.14): `Cache hit for: prefix-termux-v2-2026-W38` ·
  `HIT (restored in 25s)` · state=hit · grep sem match · entrada sobreviveu
  byte-idêntica (232.671.761 B, createdAt 2026-09-19T19:03:34Z) ✓ · wheel publicado ✓
- **#2 35533979629** (py3.13): `prefix cache holds 'Python 3.14.6', requested 3.13` ·
  `MISS/miss-other-minor` · pkg NÃO tem python-3.13 (WARN) · FAIL exit 9 com mensagem
  acionável · publish/registry pulados · **entrada da semana NÃO deletada** ✓ (o código
  antigo a teria deletado)
- Caminho corrupto: **IMPROVÁVEL via dispatch** (entradas de cache são imutáveis — não
  há como envenenar via gh); classificação coberta por harness local com a função real
  (cold/other-minor/corrupt/half → 4 classificações corretas).
- Artefato preexistente exposto (fora do escopo): dispatch de BRANCH não empurra
  registry.json (clone shallow depth-1 corta ancestralidade → push HEAD:main rejeitado
  non-FF localmente; runs de main não afetados). Follow-up sugerido: unshallow no passo
  de registry.
