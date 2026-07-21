# fabric-ops docs

Operational policy and runbooks for the broader fabric this lab plugs into
(the Slack→n8n→Ansible HITL path referenced in the root README, PRD Phase 2).
Kept separate from the eBGP Clos lab under `ebgp/`.

| File | What | Status |
|---|---|---|
| `token-rotation-policy.md` | 90-day rotation + freshness gate + `.secrets/fabric.env` as SSOT | DRAFT (item 6.6) |
| `qdrant-auth-cutover-runbook.md` | Zero-drop cutover of Qdrant `.91` to API-key auth | DRAFT SKELETON (item 5.5) |
| `qwen-model-swap-runbook.md` | Swap cw-rag generation LLM `llama3.1:8b` → Qwen3 (CPU-only), reversible | DRAFT |

Paired tooling:

- `../../scripts/scrub-bak-secrets.py` — finds/redacts cleartext secrets in `*.bak`
  and sibling backup files (item 6.7). Run `--self-check` to validate the detectors;
  default mode is report-only (no mutation without `--quarantine`/`--delete`).

These are blind drafts staged for HITL review — invariants and structure are complete;
`_TODO_` markers flag facts that require the live fabric (or the Section 3 read-only
observation ladders) to fill in.
