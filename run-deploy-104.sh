#!/usr/bin/env bash
# run-deploy-104.sh — self-contained wrapper around deploy-devbox-104.sh.
#
# Runs the gate checks that MUST pass before any VM is created, installs govc
# if missing, then hands off to the deploy script. Designed to be run by a
# human from an on-segment host (192.168.1.100/.95/.103) — never from the
# sandbox.
#
# Required environment:
#   GOVC_URL=https://192.168.1.62   GOVC_USERNAME=root   GOVC_PASSWORD=...
#   GOVC_INSECURE=true              NETBOX_TOKEN=...
#   SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
# Optional:
#   NETBOX_URL   (default http://192.168.1.56)
#   TARGET_IP    (default 192.168.1.104)
set -euo pipefail

TARGET_IP="${TARGET_IP:-192.168.1.104}"
NETBOX_URL="${NETBOX_URL:-http://192.168.1.56}"
ESXI_HOST="${GOVC_URL#https://}"; ESXI_HOST="${ESXI_HOST#http://}"; ESXI_HOST="${ESXI_HOST%%/*}"
GOVC_VERSION="${GOVC_VERSION:-v0.48.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m[gate]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- GATE 0
log "GATE 0 — required environment variables"
for v in GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE NETBOX_TOKEN SSH_PUBKEY; do
  [[ -n "${!v:-}" ]] || die "$v is not set (see header of this script)"
done
ok "all required variables present"

# ---------------------------------------------------------------- GATE 0.5
log "GATE 0.5 — on-segment check (must run from 192.168.1.0/24)"
if ! ip -4 -o addr show 2>/dev/null | grep -q '192\.168\.1\.'; then
  die "no 192.168.1.x address on this host — run from .100, .95 or .103, not the sandbox"
fi
ok "host is on-segment"

# ---------------------------------------------------------------- GATE 1
# Phantom-responder guard: this segment answers ICMP for EVERY address, so a
# ping-based free-IP check always lies. We require BOTH:
#   (a) NetBox has no active record for TARGET_IP (source of record)
#   (b) ARP for TARGET_IP gets no reply (link-layer truth; phantom is L3-only)
log "GATE 1 — dual free-IP check for ${TARGET_IP} (NetBox + ARP, never ping)"

nb_hits=$(curl -sf --max-time 10 \
  -H "Authorization: Token ${NETBOX_TOKEN}" \
  "${NETBOX_URL}/api/ipam/ip-addresses/?address=${TARGET_IP}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["count"])') \
  || die "NetBox unreachable at ${NETBOX_URL} — cannot verify IP is free"
if [[ "$nb_hits" != "0" ]]; then
  die "NetBox already has ${nb_hits} record(s) for ${TARGET_IP} — pick another IP or clean up NetBox"
fi
ok "NetBox: ${TARGET_IP} unallocated"

command -v arping >/dev/null 2>&1 || {
  log "arping missing — installing (iputils-arping)"
  sudo apt-get install -y -qq iputils-arping >/dev/null || die "could not install arping"
}
IFACE=$(ip -4 -o addr show | awk '/192\.168\.1\./ {print $2; exit}')
if sudo arping -c 3 -w 3 -I "$IFACE" "$TARGET_IP" >/dev/null 2>&1; then
  die "ARP reply received for ${TARGET_IP} — something ALREADY owns it (phantom responder is L3-only; ARP replies are real)"
fi
ok "ARP: ${TARGET_IP} silent on ${IFACE} — genuinely free"

# ---------------------------------------------------------------- GATE 2
log "GATE 2 — ESXi reachability (${ESXI_HOST})"
curl -skf --max-time 10 "https://${ESXI_HOST}/" >/dev/null \
  || die "ESXi ${ESXI_HOST} not answering HTTPS"
ok "ESXi answering"

# ---------------------------------------------------------------- govc
log "govc — auto-install if missing"
if ! command -v govc >/dev/null 2>&1; then
  arch=$(uname -m); [[ "$arch" == "aarch64" ]] && arch=arm64 || arch=x86_64
  url="https://github.com/vmware/govmomi/releases/download/${GOVC_VERSION}/govc_Linux_${arch}.tar.gz"
  mkdir -p "$HOME/.local/bin"
  curl -sfL --max-time 120 "$url" | tar -xz -C "$HOME/.local/bin" govc \
    || die "govc download failed from $url"
  export PATH="$HOME/.local/bin:$PATH"
fi
govc about >/dev/null 2>&1 || die "govc cannot authenticate to ${GOVC_URL} — check GOVC_USERNAME/GOVC_PASSWORD"
ok "govc $(govc version | head -1) authenticated to ESXi"

# ---------------------------------------------------------------- deploy
log "all gates passed — handing off to deploy-devbox-104.sh"
exec bash "${SCRIPT_DIR}/deploy-devbox-104.sh"
