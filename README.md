# Two-node RHEL KVM HA cluster — DRBD storage

A complete, working two-node high-availability platform for edge sites: two RHEL 9
hosts running KVM guests, with storage replicated synchronously between them by
DRBD, quorum from a third arbiter, and real fencing.

Built to be reproduced in a lab or POC from bare hardware. Everything is Ansible;
nothing here is hand-configured.

**No shared storage array, no appliance in the data path.** DRBD replicates block
devices directly between the two hosts, Pacemaker promotes one side and mounts the
filesystem, and the guest runs on top. Fewer moving parts than any shared-storage
design, and every component is in RHEL.

## The shape of it

```
                        ┌─────────────────────────┐
                        │  ARBITER (datacenter)   │
                        │  corosync-qnetd :5403   │
                        └────────────┬────────────┘
                          third vote │
              ┌──────────────────────┴──────────────────────┐
    ┌─────────┴──────────┐                        ┌─────────┴──────────┐
    │  NODE 1  RHEL 9    │                        │  NODE 2  RHEL 9    │
    │  guest: app        │                        │  guest: database   │
    │  /var/store-a  ────┼──── DRBD protocol C ───┼────  /var/store-b  │
    │  LVM · NVMe        │      synchronous       │      LVM · NVMe    │
    └────────────────────┘                        └────────────────────┘
         ring0 management VLAN  ·  ring1 storage VLAN  ·  BMC fencing
```

Two DRBD resources, each Primary on a different node. Both hosts carry production
workload; neither is an idle standby. Either can run both guests during a failure
or a maintenance window.

## Why three votes

A two-node cluster cannot distinguish "my peer is dead" from "my peer cannot hear
me", and guessing produces split brain. `corosync-qnetd` on a third machine casts
the deciding vote.

Do **not** set `two_node: 1`, and do **not** set `no-quorum-policy=ignore`. Both
appear in a lot of two-node examples and both trade correctness for convenience.

## Requirements

| | |
|---|---|
| 2 × x86-64 servers | with BMCs reachable for fencing (Redfish or IPMI) |
| 1 × RHEL 9 host | the arbiter — can be a small VM elsewhere |
| 2 × NICs per node | management and storage on separate segments |
| A control node | with Ansible |

## Build it

```
cp inventory/hosts.yml.example              inventory/hosts.yml
cp inventory/host_vars/node1.yml.example    inventory/host_vars/node1.yml
cp inventory/host_vars/node2.yml.example    inventory/host_vars/node2.yml
cp inventory/group_vars/all.yml.example     inventory/group_vars/all.yml
# work down each one — anything marked REPLACE has to change
make substrate      # cluster, quorum, fencing
make drbd           # replicated volumes under Pacemaker
make guests         # Ubuntu guests on the replicated storage
```

Full walkthrough with the reasoning at each step: **[docs/BUILD.md](docs/BUILD.md)**.

Every value marked `REPLACE` has to be yours. The rest has a working default.

## Verify

```
pcs quorum status                  # Total votes: 3
pcs stonith fence node2            # must actually power-cycle it
drbdadm status                     # UpToDate/UpToDate
```

Fencing that has never been exercised is the most common way a two-node cluster
fails in production. Test it before you trust it.

## A note on the roles

They are written to support either DRBD or an appliance-based shared-storage
layer, and branch on `storage_backend`. This repository pins it to `drbd`, so the
other branch never fires — that is why the other technology is named in a few
conditions.
