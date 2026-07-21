# cw-rag Generation-Model Swap — llama3.1:8b → Qwen3 (Runbook)

**Status:** DRAFT (blind-drafted; reversible, invariant + rollback structure).
**Goal:** Replace the cw-rag **generation** LLM on `.91` (Ollama) with a lighter,
faster CPU-only model. **Embeddings are NOT touched** — retrieval stays on
`nomic-embed-text`, so the Qdrant corpus and its vectors are unaffected.
**Blocked on:** `.91` reachable. As of 2026-07-21 it is **not** (Ollama `:11434`
returns empty, SSH `:22` = "No route to host"). Do Phase 0 first — if the host is
down, this runbook does not start; recover the host (inventory Section 4) then return.

---

## 0. Model selection (set once, used everywhere)

```bash
export MODEL="qwen3:4b"          # default — see table below
export OLD_MODEL="llama3.1:8b"   # current generation model (rollback target)
```

"Qwen3 3B" is not an official size. Pick the intended tag:

| `MODEL` value | What it is | Approx RAM (Q4) | When to pick |
|---|---|---|---|
| `qwen3:4b` *(default)* | Qwen3 dense 4B — newest gen, closest real model to "3B" | ~2.5–3 GB | **CPU-only balance. Recommended.** |
| `qwen3:30b-a3b` | Qwen3 MoE, ~3B active/token (fast on CPU) | ~18–20 GB | Only if `.91` has the RAM (verify in Phase 0). |
| `qwen2.5:3b` | Literal 3B, older Qwen2.5 gen | ~2 GB | RAM very tight and Qwen3-4B won't fit. |

Everything below is tag-agnostic — it uses `$MODEL`.

## 1. Invariants

1. **Retrieval is untouched.** Only the generation model changes. `nomic-embed-text`,
   Qdrant collections (`cw_skills`, `conversation_catalog`), and the wrapper's retrieval
   path stay exactly as-is.
2. **Old model stays pulled until the new one is proven.** Do NOT `ollama rm $OLD_MODEL`
   until Phase 5 verify passes — that keeps rollback to a one-line config revert + restart.
3. **Verify-before-cutover.** The new model is pulled and smoke-tested on the box *before*
   the wrapper is repointed. A model that won't load never reaches the live query path.
4. **Fail closed on RAM.** If loading `$MODEL` drives the box into heavy swap (Phase 2),
   abort — a swapping model is slower than the 8B it replaced and can OOM the wrapper.
5. **One reversible knob.** The cutover is a single config value (the model string the
   FastAPI wrapper hands to Ollama) + a wrapper restart. Rollback = restore the value.

## 2. Phase 0 — Pre-flight (host up? enough RAM? where's the config?)

Run on `.91` (or from `.78` for the reachability checks).

```bash
# Reachability (from .78):
ping -c2 192.168.1.91
nc -vz 192.168.1.91 22 8200 11434 6333

# On .91 — headroom check. Compare 'available' against the RAM column above:
free -h
ollama ps        # what's loaded now
ollama list      # what's pulled

# Find WHERE the wrapper sets the generation model (this is the knob to change).
# It is one of: an env var, a compose file, or a hardcoded string in the app.
sudo grep -rn "$OLD_MODEL\|llama3\|OLLAMA_MODEL\|LLM_MODEL\|GEN_MODEL\|model" \
     /opt/cw-rag /home/*/cw-rag /etc/cw-rag 2>/dev/null | grep -vi embed | head
systemctl cat cw-rag 2>/dev/null | grep -i model      # if systemd-run
docker inspect cw-rag 2>/dev/null | grep -i model     # if containerised
```

**Gate:** do not proceed unless (a) `.91` answers on `:8200` and `:11434`, (b) `free -h`
shows enough `available` RAM for `$MODEL` with headroom for the wrapper + embeddings, and
(c) you have located the exact place the generation model string lives. Record all three.

## 3. Phase 1 — Baseline snapshot

```bash
curl -s http://localhost:8200/health ; echo
curl -s http://localhost:8200/stats  ; echo   # note the model name the wrapper reports
# Save a known-good query for the after/before comparison:
curl -s -X POST http://localhost:8200/query \
  -H 'Content-Type: application/json' \
  -d '{"question":"What skills are in the catalog?","top_k":3}' | tee /tmp/rag_before.json
# Back up the config file you found in Phase 0 (whichever it was):
sudo cp <CONFIG_FILE> <CONFIG_FILE>.pre-qwen.bak    # rollback artifact
```

Record the exact `$OLD_MODEL` string and the config file path. This is the rollback target.

## 4. Phase 2 — Pull + smoke-test the new model (wrapper still on old model)

```bash
ollama pull "$MODEL"
ollama list | grep "$MODEL"        # confirm present + size on disk

# Load it and watch memory while it runs — abort if it swaps hard:
( ollama ps ; free -h )
ollama run "$MODEL" "Reply with exactly: OK" --verbose   # first token = cold-load time
ollama ps                          # confirm it loaded; note SIZE + PROCESSOR (CPU)
```

**Verify:** model returns a coherent short answer, `ollama ps` shows it on CPU, and
`free -h` still has headroom (invariant 4). If it swaps or OOMs → stop, `ollama rm $MODEL`,
reconsider tag (drop to `qwen2.5:3b`) — the wrapper is still safely on `$OLD_MODEL`.

## 5. Phase 3–5 — Cutover, restart, verify

```bash
# Phase 3 — repoint the wrapper to $MODEL (edit the knob from Phase 0; example forms):
#   env/compose:  OLLAMA_MODEL=qwen3:4b   (was llama3.1:8b)
#   hardcoded:    sudo sed -i "s/$OLD_MODEL/$MODEL/" <CONFIG_FILE>

# Phase 4 — restart ONLY the wrapper (Ollama keeps running):
sudo systemctl restart cw-rag        # or: docker compose -f <path> up -d --force-recreate

# Phase 5 — verify against the Phase 1 baseline:
curl -s http://localhost:8200/health ; echo
curl -s http://localhost:8200/stats | grep -i model      # should now report $MODEL
curl -s -X POST http://localhost:8200/query \
  -H 'Content-Type: application/json' \
  -d '{"question":"What skills are in the catalog?","top_k":3}' | tee /tmp/rag_after.json
```

**Pass criteria:** `/health` OK; `/stats` reports `$MODEL`; `/query` returns a coherent,
grounded answer that still cites retrieved chunks (retrieval unchanged → sources should
match `/tmp/rag_before.json`); first-token latency acceptable. Compare before/after.

## 6. Rollback (one line + restart, at any point)

| Failure point | Action | Blast radius |
|---|---|---|
| Phase 2 (won't load / swaps) | `ollama rm $MODEL` — wrapper never moved. | None. |
| Phase 3–4 (wrapper won't start / errors) | Restore `<CONFIG_FILE>.pre-qwen.bak`, restart wrapper. | Seconds; `$OLD_MODEL` still pulled. |
| Phase 5 (answers worse / too slow) | Revert config to `$OLD_MODEL`, restart wrapper. | One restart; retrieval never changed. |

**Rollback trigger (pre-agreed):** wrapper fails health, `/query` errors, answers lose
grounding, or first-token latency is worse than the 8B baseline. `$OLD_MODEL` stays on disk
until Phase 5 has passed for at least one real workload (invariant 2).

## 7. Cleanup (only after Phase 5 holds)

```bash
# Optional, once qwen is proven over a day of real queries:
ollama rm "$OLD_MODEL"     # reclaim disk. Skip if you want instant rollback kept warm.
```

Then update the `cw-fabric-access` skill's model line (`llm llama3.1:8b` → `llm $MODEL`)
so the fabric reference matches reality.

---

*Blind-drafted for the CPU-only model improvement on cw-rag `.91`. Cannot execute while
`.91` is unreachable — Phase 0 is the gate. Embeddings/retrieval are deliberately out of
scope; this only swaps the generation LLM, so the change is cheap and fully reversible.*
