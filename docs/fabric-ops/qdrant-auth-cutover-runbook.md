# Qdrant Authenticated Cutover — Runbook (SKELETON)

**Status:** DRAFT SKELETON (blind-drafted; invariant + rollback structure only).
**Goal:** Move Qdrant on `.91` from open access to API-key-authenticated access with
**zero dropped clients** and a **bounded, tested rollback**.
**Blocked on:** shell to `.91` (Section 4 recovery) OR indirect discovery. The `_TODO_`
markers below are exactly the facts that Section 3 read-only observation ladders produce —
fill them in before scheduling the maintenance window; do not execute against guesses.

> This is deliberately a skeleton. The *sequence*, *invariants*, and *rollback* are the parts
> that must be right before touching a running vector store; the specific keys, client list,
> and run-method are gated on observation and are left as `_TODO_`.

---

## 1. Invariants (must hold before, during, and after)

1. **No client left un-authenticated.** Every client that talks to Qdrant is staged with the
   new key *before* the server begins enforcing auth. Enforcement is the last step, not the first.
2. **Read path stays up.** The RAG read path (retrieval) must not return errors to end users at
   any point. If a cutover step would break reads, it is staged behind a flag, not applied live.
3. **Reversible until the final step.** Every step before "enable enforcement" is a no-op to the
   running service (config staged, not activated). The single irreversible-ish step (enforcement)
   has a one-command rollback (disable enforcement / restart with prior config).
4. **Snapshot first.** Qdrant config (and, if cheap, collection state) is snapshotted before any
   change. Recovery path = restore snapshot + restart.
5. **One relay, one blast radius.** Changes are driven from a single designated relay host
   (`_TODO_ 5.4`) that can reach both `.91` (Qdrant) and `.78` (the other endpoint in scope), so
   the cutover has one auditable origin.

## 2. Pre-cutover discovery — fill these in (gated on Section 3 / shell)

| # | Fact needed | Source | Runbook value |
|---|---|---|---|
| 5.1 | Qdrant run method | `docker ps` / `systemctl list-units 'qdrant*'` on `.91` | _TODO_ (docker \| systemd \| bare) |
| 5.2 | RO/RW key split decision | operator architectural choice | _TODO_ (single key \| RO+RW split) |
| 5.3 | Complete client list | `journalctl -u qdrant` / `docker logs` on `.91` | _TODO_ (enumerate every source IP/service) |
| 5.4 | Relay host | reachable to `.91` and `.78` | _TODO_ |
| 3.1 | Data-plane liveness baseline | `:6333/collections`, `:11434/api/tags`, `.91:8200/health` | _TODO_ (record pre-change baseline) |

The cutover MUST NOT be scheduled while any row above is `_TODO_`. An unknown client (5.3) is the
single most likely cause of a post-enforcement outage.

## 3. Cutover sequence

Each phase lists its **precondition**, **action**, and **verify**. Do not advance a phase until
its verify passes.

### Phase 0 — Baseline & snapshot
- **Pre:** liveness baseline recorded (3.1); run method known (5.1).
- **Action:** snapshot Qdrant config (and collection metadata). Record where the snapshot lives.
- **Verify:** snapshot exists and is restorable; baseline `:6333/collections` matches expectation.

### Phase 1 — Provision key(s)
- **Pre:** RO/RW decision made (5.2).
- **Action:** generate the API key(s). Store in `.secrets/fabric.env` with a `_ROTATED_AT`
  timestamp per the token-rotation policy. Do NOT enable server enforcement yet.
- **Verify:** key present in canonical store; no `.bak` captured it (`scripts/scrub-bak-secrets.py`).

### Phase 2 — Stage all clients (the long pole)
- **Pre:** complete client list (5.3). Every client is accounted for.
- **Action:** for each client, configure it to *send* the API key. Qdrant is not yet enforcing,
  so a client that sends a key still works and a client that doesn't also still works — this phase
  is safe and idempotent by construction.
- **Verify:** each client observed sending the key (client logs / a request trace) while reads
  continue to succeed. This is the gate: 100% of the client list, or do not proceed.

### Phase 3 — Enable enforcement (the one live step)
- **Pre:** Phase 2 verify green for **every** client. Snapshot from Phase 0 confirmed restorable.
- **Action:** on the relay host, enable API-key enforcement on `.91` per the run method (5.1):
  - docker: update env/config, `docker compose up -d` (or restart the container).
  - systemd: update config, `systemctl restart qdrant`.
- **Verify:** unauthenticated request → rejected (401/403); authenticated request → 200;
  `:6333/collections` with key matches Phase 0 baseline; RAG read path returns results.

### Phase 4 — Confirm & close
- **Action:** re-run the liveness ladder (3.1) with the key. Confirm no client is erroring.
- **Verify:** every client from 5.3 is green post-enforcement. Record completion + timestamp.

## 4. Rollback

Rollback is defined per phase and is always a single, tested action:

| If failure at… | Rollback | Blast radius |
|---|---|---|
| Phase 0–2 | Abandon: nothing is enforced yet, discard staged config/keys. | None (service untouched). |
| Phase 3 (enforcement breaks a client) | Disable enforcement / restart with pre-change config (or restore Phase 0 snapshot) + restart. | Seconds of auth churn; reads stay up if snapshot restore is used. |
| Phase 4 (a straggler client surfaces) | Either stage the straggler (return to Phase 2) or roll back enforcement per row above. | One client until staged. |

**Rollback trigger (pre-agreed, not judged live):** any of —
- RAG read path returns errors to end users, OR
- an in-scope client from 5.3 errors post-enforcement and cannot be staged within the window, OR
- `:6333/collections` diverges from the Phase 0 baseline.

## 5. Maintenance window

- **Owner:** laptop2 (HITL), operator on call for the RO/RW decision if not pre-made.
- **Duration:** 60–90 min (per inventory 5.6), most of it Phase 2 client staging.
- **Snapshot Qdrant config first** — non-negotiable precondition (invariant 4).

---

*Blind-drafted from task inventory item 5.5 (partial). The invariant set and rollback table are
complete and stand alone; §2 discovery rows and the run-method-specific commands in Phase 3 are
gated on Section 3 observations / shell to `.91` and are intentionally left `_TODO_`.*
