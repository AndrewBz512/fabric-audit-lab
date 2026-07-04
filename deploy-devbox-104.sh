#!/usr/bin/env bash
# deploy-devbox-104.sh — provision devbox-104 on the standalone ESXi host.
#
# Normally invoked via run-deploy-104.sh (which owns the gate checks + govc
# install). Standalone-ESXi constraints baked in:
#   - no vCenter, BIOS firmware only
#   - OVF/vApp properties transport is broken -> cloud-init is fed via a
#     NoCloud seed ISO instead
#   - the cloud-init netplan file gets stomped on reboot, so the PNetLab
#     route lives in its own /etc/netplan/60-static-routes.yaml (reboot-safe)
#
# Result: 8 vCPU / 16 GB / 80 GB Ubuntu VM at 192.168.1.104 running N8N
# (:5678) + code-server (:8443), with a static route to 172.100.1.0/24 via
# the PNetLab host 192.168.1.11.
set -euo pipefail

VM_NAME="${VM_NAME:-devbox-104}"
TARGET_IP="${TARGET_IP:-192.168.1.104}"
CIDR_BITS=24
GATEWAY="192.168.1.1"
DNS_SERVERS="192.168.1.1 1.1.1.1"
PNETLAB_NET="172.100.1.0/24"
PNETLAB_GW="192.168.1.11"          # PNetLab host — routes into the lab mgmt net
NETBOX_IP="192.168.1.56"
DATASTORE="${GOVC_DATASTORE:-datastore1}"
VM_NETWORK="${GOVC_NETWORK:-VM Network}"
OVA_URL="${OVA_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.ova}"
OVA_CACHE="${OVA_CACHE:-$HOME/.cache/ovas/noble-server-cloudimg-amd64.ova}"
WORKDIR="$(mktemp -d /tmp/deploy-104.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "${SSH_PUBKEY:-}" ]] || die "SSH_PUBKEY not set"
command -v govc >/dev/null || die "govc not on PATH (run via run-deploy-104.sh)"

# ------------------------------------------------------------------ OVA
if [[ ! -f "$OVA_CACHE" ]]; then
  log "downloading Ubuntu cloud OVA (one-time, ~600MB)"
  mkdir -p "$(dirname "$OVA_CACHE")"
  curl -fL --retry 3 -o "$OVA_CACHE.part" "$OVA_URL" && mv "$OVA_CACHE.part" "$OVA_CACHE"
fi

if govc vm.info "$VM_NAME" 2>/dev/null | grep -q "$VM_NAME"; then
  die "VM '$VM_NAME' already exists on ESXi — refusing to clobber (destroy it first: govc vm.destroy $VM_NAME)"
fi

log "importing OVA as $VM_NAME (this ignores OVF properties — vApp transport is broken on standalone ESXi)"
cat > "$WORKDIR/import.spec" <<SPEC
{
  "DiskProvisioning": "thin",
  "MarkAsTemplate": false,
  "PowerOn": false,
  "Name": "${VM_NAME}",
  "NetworkMapping": [{"Name": "VM Network", "Network": "${VM_NETWORK}"}]
}
SPEC
govc import.ova -ds "$DATASTORE" -options "$WORKDIR/import.spec" "$OVA_CACHE"

log "resizing: 8 vCPU / 16 GB RAM / 80 GB disk, BIOS firmware"
govc vm.change -vm "$VM_NAME" -c 8 -m 16384 -firmware bios
DISK=$(govc device.ls -vm "$VM_NAME" | awk '/disk-/ {print $1; exit}')
govc vm.disk.change -vm "$VM_NAME" -disk.name "$DISK" -size 80G

# ------------------------------------------------------------- seed ISO
log "building NoCloud seed ISO (cloud-init via cidata volume)"

cat > "$WORKDIR/meta-data" <<EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_NAME}
EOF

# Base NIC config. The PNetLab route deliberately does NOT live here — see
# 60-static-routes.yaml below, which survives cloud-init netplan rewrites.
cat > "$WORKDIR/network-config" <<EOF
version: 2
ethernets:
  primary:
    match: { name: "en*" }
    set-name: ens160
    addresses: [${TARGET_IP}/${CIDR_BITS}]
    routes: [{ to: default, via: ${GATEWAY} }]
    nameservers:
      addresses: [$(echo "$DNS_SERVERS" | tr ' ' ',')]
EOF

cat > "$WORKDIR/user-data" <<EOF
#cloud-config
hostname: ${VM_NAME}
fqdn: ${VM_NAME}.lab.local
users:
  - name: ubuntu
    groups: [sudo, docker]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - ${SSH_PUBKEY}
package_update: true
packages: [docker.io, curl, git, python3-pip, ansible, sshpass]
write_files:
  # Reboot-safe PNetLab route: separate netplan file, never touched by
  # cloud-init's 50-cloud-init.yaml rewrites.
  - path: /etc/netplan/60-static-routes.yaml
    permissions: "0600"
    content: |
      network:
        version: 2
        ethernets:
          ens160:
            routes:
              - to: ${PNETLAB_NET}
                via: ${PNETLAB_GW}
runcmd:
  - netplan apply
  - systemctl enable --now docker
  # N8N — workflows persisted in a named volume
  - >
    docker run -d --name n8n --restart unless-stopped -p 5678:5678
    -e N8N_SECURE_COOKIE=false -e N8N_HOST=${TARGET_IP}
    -e WEBHOOK_URL=http://${TARGET_IP}:5678/
    -v n8n_data:/home/node/.n8n docker.n8n.io/n8nio/n8n
  # code-server — browser IDE fallback on :8443
  - curl -fsSL https://code-server.dev/install.sh | sh
  - mkdir -p /home/ubuntu/.config/code-server
  - |
    printf 'bind-addr: 0.0.0.0:8443\nauth: password\n' > /home/ubuntu/.config/code-server/config.yaml
  - chown -R ubuntu:ubuntu /home/ubuntu/.config
  - systemctl enable --now code-server@ubuntu
  # Playbook checkout target (repo clone or rsync from laptop comes later)
  - mkdir -p /opt/pnetlab-playbooks && chown ubuntu:ubuntu /opt/pnetlab-playbooks
  # Smoke test — gateway, PNetLab host, NetBox
  - |
    { for t in ${GATEWAY} ${PNETLAB_GW} ${NETBOX_IP}; do
        if ping -c 2 -W 2 \$t >/dev/null 2>&1; then echo "SMOKE \$t OK"; else echo "SMOKE \$t FAIL"; fi
      done
      ip route show ${PNETLAB_NET}
    } > /var/log/devbox-smoke.log 2>&1
final_message: "devbox-104 cloud-init complete"
EOF

if command -v genisoimage >/dev/null; then
  genisoimage -quiet -output "$WORKDIR/seed.iso" -volid cidata -joliet -rock \
    "$WORKDIR/user-data" "$WORKDIR/meta-data" "$WORKDIR/network-config"
elif command -v mkisofs >/dev/null; then
  mkisofs -quiet -output "$WORKDIR/seed.iso" -volid cidata -joliet -rock \
    "$WORKDIR/user-data" "$WORKDIR/meta-data" "$WORKDIR/network-config"
else
  die "need genisoimage or mkisofs to build the seed ISO (apt install genisoimage)"
fi

log "uploading seed ISO and attaching CD-ROM"
govc datastore.upload -ds "$DATASTORE" "$WORKDIR/seed.iso" "${VM_NAME}/seed.iso"
CDROM=$(govc device.cdrom.add -vm "$VM_NAME")
govc device.cdrom.insert -vm "$VM_NAME" -device "$CDROM" -ds "$DATASTORE" "${VM_NAME}/seed.iso"
govc device.connect -vm "$VM_NAME" "$CDROM"

# -------------------------------------------------------------- power on
log "powering on and waiting for cloud-init (typically 4-8 min: packages + docker pulls)"
govc vm.power -on "$VM_NAME"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes"
for i in $(seq 1 60); do
  if ssh $SSH_OPTS "ubuntu@${TARGET_IP}" true 2>/dev/null; then break; fi
  [[ $i -eq 60 ]] && die "no SSH on ${TARGET_IP} after 10 min — check ESXi console"
  sleep 10
done
log "SSH up — waiting for cloud-init to finish"
ssh $SSH_OPTS "ubuntu@${TARGET_IP}" "cloud-init status --wait" \
  || die "cloud-init reported an error — see: ssh ubuntu@${TARGET_IP} sudo cat /var/log/cloud-init-output.log"

log "ejecting seed ISO"
govc device.cdrom.eject -vm "$VM_NAME" -device "$CDROM" || true

# ----------------------------------------------------------- health check
log "post-deploy health checks"
for i in $(seq 1 18); do
  if curl -sf --max-time 5 "http://${TARGET_IP}:5678/healthz" | grep -q ok; then break; fi
  [[ $i -eq 18 ]] && die "N8N healthz not OK after 3 min — ssh in and check: docker logs n8n"
  sleep 10
done
curl -sf --max-time 5 -o /dev/null "http://${TARGET_IP}:8443/" \
  || log "WARN: code-server :8443 not answering yet (non-fatal)"
ssh $SSH_OPTS "ubuntu@${TARGET_IP}" "cat /var/log/devbox-smoke.log" || true

echo
echo "=================================================================="
echo " ${VM_NAME} DEPLOYED — ${TARGET_IP}"
echo "   N8N:         http://${TARGET_IP}:5678"
echo "   code-server: http://${TARGET_IP}:8443  (password: ssh in, see ~/.config/code-server/config.yaml)"
echo "   Next: bash register-netbox-104.sh"
echo "=================================================================="
