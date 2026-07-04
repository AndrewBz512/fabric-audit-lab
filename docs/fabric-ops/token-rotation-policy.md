# Token & Credential Rotation Policy

**Status:** DRAFT (blind-drafted, staged for review)
**Scope:** Fabric secrets — API keys, service tokens, admin passwords, JWTs, tunnel IDs.
**Canonical store:** `.secrets/fabric.env` (git-ignored via `*.env`; never committed).
**Owner of record:** fabric operator (HITL). Automation may *stage* rotations; it does not *apply* them.

---

## 1. Why this exists

The July 3 `.bak` incident exposed cleartext credentials in editor/backup sidecar files
(`*.bak` and siblings) that were never meant to persist. Rotation policy plus a freshness
gate limits the blast radius of any future leak: a credential that is rotated on a fixed
cadence and gated on freshness is only useful to an attacker for a bounded window.

This policy pairs with:

- `scripts/scrub-bak-secrets.py` — detects/quarantines cleartext secrets in backup files.
- The fabric SSOT freshness gate — refuses to act on stale credential material.

## 2. Principles

1. **Single source of truth.** `.secrets/fabric.env` is the only canonical credential store.
   Anything found in a `.bak`, a shell history, a note, or a second copy is drift and must be
   scrubbed, not synced.
2. **Rotation is HITL.** Only the operator (or an explicitly authorized service token flow)
   applies a rotation. Automation drafts the runbook and stages the new value; it never
   writes the live secret.
3. **Freshness gate.** Every credential carries a `*_ROTATED_AT` timestamp. Consumers check
   age at load; a credential older than its max age fails the gate loudly rather than being
   used silently.
4. **No cleartext at rest outside the canonical store.** Backups, exports, and `.bak` sidecars
   containing secrets are a policy violation, not an accident to tolerate.

## 3. Cadence

| Class | Example | Max age | Trigger for early rotation |
|---|---|---|---|
| External API keys | Anthropic, OpenRouter, USAJobs | 90 days | Any leak, `.bak` exposure, or vendor advisory |
| Service auth tokens | n8n JWT, CF Access service token | 90 days | Leak, role change, or tunnel reconfiguration |
| Admin passwords | n8n admin | 90 days | Leak, staff change |
| Infra identifiers | CF tunnel ID | Rotate on leak only¹ | Compromise of paired auth material |

¹ An identifier is not an authenticator. A leaked tunnel ID is medium priority — rotate the
paired credential (tunnel token/secret), not just the ID.

## 4. The freshness gate

Each secret in `.secrets/fabric.env` is paired with a rotation timestamp:

```env
OPENROUTER_API_KEY=...
OPENROUTER_API_KEY_ROTATED_AT=2026-07-04T00:00:00Z
```

Consumers MUST:

1. Read `<NAME>_ROTATED_AT` alongside `<NAME>`.
2. Reject (fail closed) if the timestamp is missing or older than the class max age.
3. Emit a warning (not a hard fail) once the credential enters the final 14 days before max age,
   so rotation can be scheduled inside a maintenance window rather than as an incident.

Fail-closed is the default because a silently-expired credential that keeps working is exactly
the leak-window this policy exists to close.

## 5. Rotation procedure (per credential)

1. **Generate** the new value in the vendor console / issuing system.
2. **Stage** it: write the new value + a fresh `_ROTATED_AT` into a scratch env, never into the
   live file directly from an automated seat.
3. **Cut over** consumers (HITL): update `.secrets/fabric.env`, restart/reload dependents.
4. **Verify** the new credential works against a read-only probe before revoking the old one.
5. **Revoke** the old value at the vendor.
6. **Scrub**: run `scripts/scrub-bak-secrets.py` to confirm no `.bak` sidecar captured either
   the old or new value during editing.
7. **Record** the rotation date and next-due date.

Verify-before-revoke (step 4 before 5) prevents a self-inflicted outage from a bad copy-paste.

## 6. Current rotation ledger

Populate from the live fabric; values below are the credentials flagged by the `.bak`
remediation and HITL queue, not their contents.

| Credential | Class | Priority | Last rotated | Next due | Owner |
|---|---|---|---|---|---|
| OpenRouter API key | External API | HIGH (`.bak` leak) | _TODO_ | _TODO_ | operator |
| n8n admin password | Admin password | HIGH if unrotated | _TODO_ | _TODO_ | operator (laptop2 verify) |
| n8n JWT | Service token | HIGH | _TODO_ | _TODO_ | laptop2 |
| Cloudflare tunnel ID | Infra identifier | MEDIUM (ID ≠ auth) | _TODO_ | _TODO_ | laptop2 |
| Anthropic API key | External API | — (top-up pending) | _TODO_ | _TODO_ | operator |
| USAJobs API key | External API | — (issuance pending) | _TODO_ | _TODO_ | operator |

## 7. Enforcement

- CI / pre-commit: reject any staged file matching `*.env`, `*vault*`, `*.key`, `*.pem`
  (already covered by `.gitignore`; a pre-commit hook makes it a hard stop, not a convention).
- Scheduled: run `scripts/scrub-bak-secrets.py` on the fabric hosts on the same cadence as the
  SSOT verification so cleartext drift is caught within one cycle.
- Freshness gate: any consumer that loads a credential without checking `_ROTATED_AT` is a bug.

---

*Blind-drafted from the task inventory (items 6.6, 8.x). Timestamps and ledger entries require
the live fabric to fill in; the structure and invariants above stand on their own.*
