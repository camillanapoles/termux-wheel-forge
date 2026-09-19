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

## Follow-up (novo incremento, R1: precisa de critérios antes de branch)

- [ ] Proposta: cache do bootstrap pkg/`$PREFIX` (tar do toolchain no actions/cache) —
      alvo: os ~2–3 min de dpkg sob QEMU por run. Requer spec de invalidação
      (stale toolchain vs builds). **Ask-first** (muda estratégia de build).
