# fabric-audit-lab — eBGP underlay (Phase 1b)

Configures and verifies an eBGP Clos underlay on the running 4-node cEOS fabric
(`fabric-audit-4node`) on clab-host2 (.103).

## Topology / addressing
| Node   | ASN   | Loopback0  | Eth1                      | Eth2                      |
|--------|-------|------------|---------------------------|---------------------------|
| spine1 | 65100 | 10.255.0.1 | 10.0.0.0/31 ↔ leaf1       | 10.0.0.2/31 ↔ leaf2       |
| spine2 | 65200 | 10.255.0.2 | 10.0.1.0/31 ↔ leaf1       | 10.0.1.2/31 ↔ leaf2       |
| leaf1  | 65001 | 10.255.1.1 | 10.0.0.1/31 ↔ spine1      | 10.0.1.1/31 ↔ spine2      |
| leaf2  | 65002 | 10.255.1.2 | 10.0.0.3/31 ↔ spine1      | 10.0.1.3/31 ↔ spine2      |

All loopbacks + p2p /31s advertised via BGP `network` statements; `maximum-paths 4` for ECMP.

## Prereqs (on .103, where the fabric runs)
1. Confirm mgmt IPs match `inventory.yml`: `sudo containerlab inspect --all`
   (cEOS mgmt is on clab net 172.20.20.0/24). Edit `ansible_host` if they differ.
2. Confirm interface names. cEOS clab links map to `Ethernet1/2…`; verify with the
   topology file or `show lldp neighbors` on a node.
3. Install collections: `ansible-galaxy collection install -r requirements.yml`

## Run
```bash
ansible-playbook 10-underlay-ebgp.yml      # push config (idempotent)
ansible-playbook 20-verify-bgp.yml         # assert all eBGP peers Established
```

## Notes
- Creds default to admin/admin (clab cEOS default). Override in inventory or via
  `--extra-vars`, and prefer a vault for anything real.
- This is the local-fabric path. Remote Cisco lab + VPN + Slack/n8n HITL are
  Phase 2 (see SESSION-CLOSEOUT.md).
