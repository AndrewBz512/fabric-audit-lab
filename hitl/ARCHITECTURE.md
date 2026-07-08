# HITL Webhook Architecture — Slack ChatOps for the Fabric/PNetLab Stack

Status: **proposed** (design doc; implementation workflows to follow on this branch)

This document specifies how human-in-the-loop (HITL) approval gates work for
agent- and ChatOps-driven changes to the lab fabric (Ansible playbooks executed
over SSH against PNetLab / cEOS nodes), and how approval decisions are routed
back to the waiting execution.

---

## 1. Components

```
Slack user
   │  slash command / mention
   ▼
[Slack app] ──HTTP POST──► [N8N: chatops webhook]
                                │ parse intent, classify risk
                                ├─ low-risk ──────────────► execute
                                └─ high-risk
                                     │ create pending-approval record
                                     ▼
                              [HITL gate: Slack Block Kit message
                               with Approve / Reject buttons]
                                     │ button click
                                     ▼
[Slack interactivity] ──HTTP POST──► [N8N: interactive handler webhook]
                                     │ verify Slack signature
                                     │ look up pending record by token
                                     ▼
                              resume waiting execution ──► SSH → ansible-playbook
                                     │
                                     ▼
                              post result to originating Slack thread
```

Execution target: Ansible playbooks (`site.yml` + phase playbooks) run over SSH
against the lab management network. The executor host is the devbox VM
(deployed by `deploy-devbox-104.sh`), which has the static route into the
PNetLab lab segment.

## 2. The callback question: `_RT` / `_CB`, not `callback_url`

Observed gateway button payloads carry `{"_RT": "<token>"}` and
`{"_CB": "<id>"}` — **an opaque routing token and callback id, not a raw
callback URL**. This is deliberate and the design this repo adopts:

> **Never place the callback URL in the Slack button payload.** Button values
> round-trip through Slack (a third party), appear in Slack's message payloads
> and logs, and can be replayed. A handler that POSTs to whatever URL arrives
> in the click payload is an SSRF/forgery primitive.

Instead:

1. When the HITL gate fires, the gateway generates an opaque routing token
   (`_RT`) and stores a **pending-approval record server-side**, keyed by that
   token:

   ```json
   {
     "rt":          "<random 128-bit token>",
     "cb":          "<callback id — which resume mechanism to use>",
     "resume_url":  "<n8n Wait-node resumeWebhookUrl, stored server-side only>",
     "requester":   "<slack user id>",
     "channel":     "<channel id>", "ts": "<message ts>",
     "action":      "<summarized command / playbook + limit + tags>",
     "expires_at":  "<now + TTL>",
     "state":       "pending"
   }
   ```

2. The Slack message buttons carry only `{"_RT": ..., "_CB": ...}`.

3. The **interactive handler**:
   - verifies the Slack signing secret (`X-Slack-Signature`,
     `X-Slack-Request-Timestamp`, ±5 min replay window) **before anything else**;
   - looks up the pending record by `_RT`; unknown/expired/already-decided
     token → update the Slack message with "expired / already handled", stop;
   - marks the record decided **atomically** (first click wins — idempotent
     under Slack retries and double-clicks);
   - routes the decision using the server-side record (§3);
   - **replaces** the original message (`response_url`, `replace_original:
     true`) so the buttons disappear and the audit trail shows who decided,
     what, and when.

## 3. Decision routing: push (recommended) vs poll

### 3a. Push — N8N Wait-node resume webhook (recommended)

The ChatOps workflow uses an N8N **Wait** node in "on webhook call" mode. At
gate time it stores its `resumeWebhookUrl` in the pending record. The
interactive handler POSTs `{decision, decided_by, decided_at}` to that URL;
the waiting workflow resumes and branches on approve/reject.

- No polling, no extra store beyond the pending-approval table.
- The resume URL never leaves the server side.
- Wait node timeout = record TTL → timeout path auto-rejects and updates the
  Slack message ("expired, no action taken").

### 3b. Pull — decision store polling (fallback only)

For executors that cannot accept inbound HTTP (behind NAT, no tunnel): the
handler only writes `state: approved|rejected` to the record; the executor
polls the record until decided or TTL. Use only when 3a is impossible; adds
latency and a shared-store dependency.

The `_CB` field selects the mechanism per request, so both patterns coexist
behind one gateway.

## 4. Integration scope: one gateway, not a parallel path

The PNetLab/devbox ChatOps executor registers as a **downstream consumer of
the existing HITL gateway** rather than standing up a second, parallel
approval path:

- one Slack app / signing secret / interactivity endpoint to protect;
- one pending-approval store and one audit log — every fabric change,
  agent-initiated or human-initiated, appears in the same trail;
- risk policy (what requires approval) lives in one place.

The executor's only contract with the gateway: accept a resume POST (3a) or
poll a record (3b), and report completion back to the originating thread.

## 5. Security requirements (non-negotiable)

| Control | Detail |
|---|---|
| Slack signature verification | On **both** webhooks (chatops + interactive), before parsing. |
| Opaque tokens | ≥128-bit random `_RT`; server-side lookup only; single-use. |
| TTL + auto-reject | Pending approvals expire (default 15 min); expiry edits the Slack message. |
| Idempotency | First decision wins; late/duplicate clicks get "already handled". |
| Authorization | Approver allowlist (Slack user ids / group); requester ≠ approver for high-risk actions. |
| Least-privilege SSH | Dedicated key for the executor; restricted to `ansible-playbook` invocation on the devbox; no interactive shell. |
| Audit log | Append-only record of request → decision → execution result, keyed by `_RT`. |
| No secrets in Slack | Button payloads, message text, and threads never contain URLs, keys, or hostnames beyond what the requester already sees. |

## 6. Failure paths

- **Executor unreachable at resume time** → handler marks record
  `approved_undelivered`, posts failure to the thread; a retry action button
  re-attempts delivery (token stays single-decision, delivery may retry).
- **Slack retry storms** (3 s timeout) → webhooks ACK 200 immediately and do
  work async; dedupe on `(message_ts, action_id)`.
- **N8N restart with in-flight Waits** → Wait-node resume URLs survive
  restarts (execution-id based); pending records are persisted, not in-memory.

## 7. Artifacts and recovery

The prior working session produced these artifacts, which were **deployed but
not committed** (the remote session container was ephemeral and has been
reclaimed):

| Artifact | Recover from |
|---|---|
| `chatops_slack_pnetlab.json`, `hitl_interactive_handler.json` (N8N workflows) | Export from the running N8N instance: UI → workflow → *Download*, or `n8n export:workflow --all --output=…` on the devbox container. |
| `run-deploy-104.sh`, `deploy-devbox-104.sh` | Copy from the host they were run on, if retained; otherwise re-author. |
| Phase playbooks + `site.yml` + inventory (`172.100.1.0/24`) | Copy from the devbox executor path used by the ChatOps workflow. |

Once recovered, commit them under `hitl/` in this repo so the next session
does not start from zero. **Rule going forward: anything built in a remote
session gets committed and pushed the same session.**
