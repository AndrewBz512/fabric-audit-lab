# fabric-audit-lab

Two related labs live here:

1. **eBGP Clos underlay on Containerlab** (`ebgp/`) — the original local-fabric
   path: 4 Arista cEOS nodes on `clab-host2` (192.168.1.103). Docs start at
   [Topology](#topology) below.
2. **PNetLab ChatOps platform** (repo root) — 5-phase network playbook rollout
   against 11 PNetLab devices (172.100.1.0/24), driven from Slack `#ops-agent`
   through N8N on devbox-104 (192.168.1.104). Next section.

---

## PNetLab ChatOps platform

```
Slack #ops-agent ──POST──► N8N (devbox-104 :5678) ──SSH──► ansible-playbook
                                                              │
                              192.168.1.104 ──via .11──► 172.100.1.0/24 (PNetLab)
```

| Piece | Files |
|-------|-------|
| VM provisioning (ESXi .62, on-segment only) | `run-deploy-104.sh` → `deploy-devbox-104.sh`, then `register-netbox-104.sh` |
| Ansible project | `ansible.cfg`, `inventory/pnetlab.yml`, `site.yml`, `playbooks/phases/phase{1..5}_*.yml` |
| N8N workflows | `n8n_webhooks/*.json` — import order + credentials in `n8n_webhooks/README.md` |
| VSCode Remote SSH | `pnetlab.code-workspace` (open on devbox-104 at `/opt/pnetlab-playbooks`) |

Phases (each verifies itself and gates the next; results POST to N8N → Slack):

1. **Core switching** — VLANs, rapid-PVST, trunk/access (IOS)
2. **Routing underlay** — OSPF area 0, loopbacks, timers (IOS)
3. **Overlay** — BGP EVPN, NVE, VNI mapping (NX-OS, feature pre-flight)
4. **Edge WAN** — NAT/PAT, ACL, default route (IOS)
5. **Client onboard** — DHCP, E2E ping, traceroute (Linux)

Quick start on devbox-104:

```bash
cd /opt/pnetlab-playbooks
ansible-vault create inventory/group_vars/all/vault.yml   # vault_device_password, vault_client_password
# update inventory/pnetlab.yml with the ACTUAL node mgmt IPs from the PNetLab UI
ansible all -m ping --ask-vault-pass                      # connectivity gate
ansible-playbook site.yml --check --diff --ask-vault-pass # dry run
ansible-playbook site.yml --tags phase1 --ask-vault-pass  # then phase2..phase5
```

Deploy gotchas baked into the scripts: the 192.168.1.0/24 segment has a
**phantom ICMP responder** (free-IP checks use NetBox + ARP, never ping); the
ESXi host is standalone (**no vCenter, vApp transport broken** → NoCloud seed
ISO); the PNetLab route lives in its own netplan file (`60-static-routes.yaml`)
so reboots don't eat it. Deploy scripts are authored here but **run on-segment
only** (.100/.95/.103) — never from a sandbox.

---

## eBGP Clos underlay (Containerlab)

Containerlab spine-leaf lab + Ansible IaC for an **eBGP Clos underlay**, running on
`clab-host2` (192.168.1.103). Four Arista cEOS nodes (2 spine, 2 leaf), configured
and verified entirely through Ansible.

## Topology

```
        spine1 (65100)        spine2 (65200)
         /        \            /        \
        /          \          /          \
   leaf1 (65001)        leaf2 (65002)
        |                     |
   client1               client2   (optional endpoints)
```

Leaf↔spine full mesh; each leaf peers eBGP with both spines.

## Addressing

| Node   | ASN   | Loopback0  | Eth1 (/31)            | Eth2 (/31)            | mgmt        |
|--------|-------|------------|-----------------------|-----------------------|-------------|
| spine1 | 65100 | 10.255.0.1 | 10.0.0.0  ↔ leaf1     | 10.0.0.2  ↔ leaf2     | 172.20.20.11|
| spine2 | 65200 | 10.255.0.2 | 10.0.1.0  ↔ leaf1     | 10.0.1.2  ↔ leaf2     | 172.20.20.12|
| leaf1  | 65001 | 10.255.1.1 | 10.0.0.1  ↔ spine1    | 10.0.1.1  ↔ spine2    | 172.20.20.21|
| leaf2  | 65002 | 10.255.1.2 | 10.0.0.3  ↔ spine1    | 10.0.1.3  ↔ spine2    | 172.20.20.22|

Loopbacks + p2p /31s are advertised via BGP `network` statements; `maximum-paths 4`
for ECMP. (cEOS `eth1/eth2` map to `Ethernet1/Ethernet2`.)

## Repo layout

```
.
├── containerlab/
│   └── spine-leaf-4node.clab.yml   # the topology
└── ebgp/
    ├── ansible.cfg                 # network_cli over SSH; paramiko host-key checks off
    ├── inventory.yml               # 4 nodes, mgmt IPs, admin/admin
    ├── group_vars/all.yml          # ecmp_paths
    ├── host_vars/{spine,leaf}*.yml # per-node ASN, loopback, p2p links + peers
    ├── 10-underlay-ebgp.yml        # configure: ip routing, ifaces, BGP, AF activation
    ├── 20-verify-bgp.yml           # assert every peer Established (fails on 0 peers)
    └── requirements.yml            # arista.eos, ansible.netcommon
```

## Run

Prereqs on the host: Docker, Containerlab, Ansible, `python3-paramiko`.

```bash
# 1) bring up the fabric
cd containerlab
sudo containerlab deploy -t spine-leaf-4node.clab.yml

# 2) configure + verify eBGP
cd ../ebgp
ansible-galaxy collection install -r requirements.yml
ansible-playbook 10-underlay-ebgp.yml      # idempotent
ansible-playbook 20-verify-bgp.yml         # all peers Established
```

## cEOS gotchas baked into the playbook

These tripped up the first bring-up and are now handled in `10-underlay-ebgp.yml`:

1. **`ip routing` is OFF by default** — cEOS boots as an L2 switch, so the default
   VRF reports *"BGP is disabled"* until `ip routing` is enabled. First task does it.
2. **Multi-agent BGP needs neighbor activation** — `service routing protocols model
   multi-agent` is the cEOS default; neighbors won't form until they're `activate`d
   under `address-family ipv4`. Dedicated task handles it.
3. **Routed interfaces need `no switchport`** before an `ip address`.

## Verify manually

```bash
sudo docker exec clab-fabric-audit-4node-spine1 Cli -p15 -c "show ip bgp summary"
# each node: 2 peers, Session State = Established
```

## Notes

- Default device creds are `admin/admin` (clab cEOS). Use a vault for anything real.
- This is the local-fabric path. Slack→n8n→Ansible HITL orchestration (PRD Phase 2)
  builds on these playbooks.
- `.gitignore` blocks secrets (`*.env`, keys, vault, `known_hosts`). Never commit creds.
