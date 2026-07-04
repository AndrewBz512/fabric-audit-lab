#!/usr/bin/env bash
# register-netbox-104.sh — record devbox-104 in NetBox (source of record).
#
# Run right after deploy-devbox-104.sh succeeds. Idempotent: re-running
# updates rather than duplicates. Requires: NETBOX_TOKEN; optional NETBOX_URL
# (default http://192.168.1.56).
set -euo pipefail

NETBOX_URL="${NETBOX_URL:-http://192.168.1.56}"
TARGET_IP="${TARGET_IP:-192.168.1.104}"
DNS_NAME="devbox-104.lab.local"
DESCRIPTION="devbox-104: N8N + code-server + Ansible control for PNetLab ChatOps"

[[ -n "${NETBOX_TOKEN:-}" ]] || { echo "FAIL: NETBOX_TOKEN not set" >&2; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required" >&2; exit 1; }

api() { # api METHOD PATH [JSON_BODY]
  local method=$1 path=$2 body=${3:-}
  curl -sf --max-time 15 -X "$method" \
    -H "Authorization: Token ${NETBOX_TOKEN}" \
    -H "Content-Type: application/json" \
    ${body:+-d "$body"} \
    "${NETBOX_URL}/api${path}"
}
jsonq() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

echo "[netbox] verifying API at ${NETBOX_URL}"
api GET /status/ >/dev/null || { echo "FAIL: NetBox unreachable" >&2; exit 1; }

# ------------------------------------------------------------------ tags
TAGS=(role-dev-ops workload-n8n workload-pycharm-remote workload-pnetlab-control env-staging)
tag_ids=()
for slug in "${TAGS[@]}"; do
  count=$(api GET "/extras/tags/?slug=${slug}" | jsonq 'd["count"]')
  if [[ "$count" == "0" ]]; then
    echo "[netbox] creating tag ${slug}"
    id=$(api POST /extras/tags/ "{\"name\": \"${slug}\", \"slug\": \"${slug}\"}" | jsonq 'd["id"]')
  else
    id=$(api GET "/extras/tags/?slug=${slug}" | jsonq 'd["results"][0]["id"]')
  fi
  tag_ids+=("$id")
done
tags_json=$(printf '%s\n' "${tag_ids[@]}" | python3 -c \
  'import sys,json; print(json.dumps([{"id": int(l)} for l in sys.stdin if l.strip()]))')
echo "[netbox] tags ready: ${TAGS[*]}"

# ------------------------------------------------------------- IP address
ip_body=$(python3 - "$TARGET_IP" "$DNS_NAME" "$DESCRIPTION" "$tags_json" <<'PY'
import sys, json
ip, dns, desc, tags = sys.argv[1:5]
print(json.dumps({
    "address": f"{ip}/24",
    "status": "active",
    "dns_name": dns,
    "description": desc,
    "tags": json.loads(tags),
}))
PY
)
existing=$(api GET "/ipam/ip-addresses/?address=${TARGET_IP}")
if [[ "$(echo "$existing" | jsonq 'd["count"]')" == "0" ]]; then
  echo "[netbox] registering ${TARGET_IP}/24 (dns_name=${DNS_NAME})"
  api POST /ipam/ip-addresses/ "$ip_body" >/dev/null
else
  ip_id=$(echo "$existing" | jsonq 'd["results"][0]["id"]')
  echo "[netbox] ${TARGET_IP} exists (id=${ip_id}) — updating in place"
  api PATCH "/ipam/ip-addresses/${ip_id}/" "$ip_body" >/dev/null
fi

echo "[netbox] devbox-104 registered: ${TARGET_IP}/24 -> ${DNS_NAME}, tags: ${TAGS[*]}"
