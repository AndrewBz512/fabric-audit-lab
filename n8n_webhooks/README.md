# N8N workflows — PNetLab ChatOps

Import into N8N on devbox-104 (`http://192.168.1.104:5678`) **in this order**,
then activate all three (Workflows → Import from File):

| # | File | Webhooks | Purpose |
|---|------|----------|---------|
| 1 | `pnetlab_phase_orchestrator.json` | `phase{1..5}-start`, `phase{1..5}-result`, `deploy-complete` (11) | Ansible phase results in → ack + post to #ops-agent |
| 2 | `chatops_slack_pnetlab.json` | `slack-chatops` | Slack command → SSH devbox-104 → `ansible-playbook` → result to Slack |
| 3 | `hitl_interactive_handler.json` | `hitl-interactive` | Approve/Reject buttons → agent callback + Slack message update |

## Credentials to create after import (NOT variables — see risk register)

- **`Slack Bot (ops-agent)`** — Slack API credential, bot OAuth token from the
  Slack app (Phase D). Attach to every Slack node.
- **`devbox-104 SSH`** — SSH *private key* credential in the N8N **Credentials
  store** (never in Settings → Variables, which is plaintext). Attach to both
  SSH nodes in the ChatOps workflow.

Also on devbox-104: `echo '<vault-pass>' > ~/.vault_pass && chmod 600 ~/.vault_pass`
so ChatOps-triggered runs can decrypt the Ansible vault non-interactively.

## Smoke tests

```bash
curl -X POST http://192.168.1.104:5678/webhook/phase1-start \
  -H "Content-Type: application/json" -d '{"phase":"test","status":"ping"}'
# -> {"received":true,"phase":"test","status":"ping"}

curl -X POST http://192.168.1.104:5678/webhook/slack-chatops \
  -H "Content-Type: application/json" \
  -d '{"event":{"text":"help","channel":"C0BENNUJJT1"}}'
# -> {"ok":true}  (and the help card appears in #ops-agent)
```

## Known gaps (from the build doc)

- **HITL callback**: button `value` must be JSON `{callback_url, token, request_id}`
  (CW HITL Gateway `_RT`/`_CB` pattern) — confirm before production; the handler
  posts a warning to #ops-agent when `callback_url` is missing.
- **Slack Interactivity needs a public URL**: LAN-only `.104:5678` cannot receive
  button clicks — front it with a Cloudflare Tunnel or a VPS reverse proxy.
