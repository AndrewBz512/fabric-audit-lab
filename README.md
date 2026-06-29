# fabric-audit-lab

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
