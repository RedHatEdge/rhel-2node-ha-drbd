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

**Architecture diagram:** [`docs/diagrams/drbd-architecture.png`](docs/diagrams/drbd-architecture.png)
— both hosts, the two replicated volumes, and which node is Primary for each.
[`drbd-live-migration.png`](docs/diagrams/drbd-live-migration.png) covers the one
constraint worth knowing before you design around this.

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
cp inventory/hosts.yml.example           inventory/hosts.yml
cp inventory/group_vars/all.yml.example  inventory/group_vars/all.yml

# hosts.yml  — the three addresses, matching the MAC table in bootc/config.toml
# all.yml    — work down it; anything marked REPLACE will not work until changed

make discover       # each node records its own disks and NICs
make substrate      # cluster, quorum, fencing
make admin          # admin account and Cockpit on :9090
make drbd           # replicated volumes under Pacemaker
make guests         # Ubuntu guests on the replicated storage
```

`make discover` comes first for a reason: it pins every disk and interface to an
identifier that cannot change on reboot. Skip it and the build works until
something is renumbered, then writes to the wrong disk.

You do **not** create `inventory/host_vars/` by hand — `make discover` generates
those from the hardware, and hand-written files there are overwritten. The
`.example` files show the shape only.

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

### One key, three places it has to go

You do not need three keys. Create one — `~/.ssh/store-cluster` in Stage 0
step 4 — and put that same public half in all three places. They are separate
settings applied at different stages, so each has to be filled in individually:

| where you put it | what it gets you | applied |
|---|---|---|
| `bootc/config.toml` | `root` on the nodes, which is how Ansible reaches them | baked into the ISO at build time |
| `admin_ssh_key` in `all.yml` | the `admin` account, alongside its password | `make admin` |
| `guest_ssh_key` in `all.yml` | the guests | `make guests` |

Only the first is fixed when the image is built; the other two can be changed
later by editing `all.yml` and re-running. Different keys work fine if you want
them, but there is no reason to start that way.

One more key exists that you never touch: Ansible generates a root keypair on
each node and authorises it on the other, so the nodes can reach each other as
root. Live migration depends on it. It is created automatically and does not
belong in any inventory file.
