# Build from nothing

Two-node RHEL 9 KVM HA cluster with DRBD replicated storage.

**Roughly 90 minutes**, most of it waiting for installs and the initial sync.

---

## A. Networks

| segment | example subnet | carries |
|---|---|---|
| management | 172.16.7.0/24 | corosync ring0, host management, the arbiter |
| storage | 172.18.8.0/24 | corosync ring1, DRBD replication |

The storage segment needs **no gateway** — replication must not route anywhere.

Two rings matter. corosync uses knet with both links, so losing one network does
not partition the cluster. Put them on different physical adapters, and if you can,
different switches.

## B. Install the two nodes

```
cd bootc
./build.sh                 # RHEL 9 bootc container image
./build.sh --push --iso    # build, push, then make an installer ISO
```

One ISO installs both nodes. The kickstart matches each machine's own MACs against
a table and emits the right hostname and static addresses; a second `%pre` picks
the OS disk by size rather than by name.

That last part matters more than it sounds. Identical servers frequently enumerate
their NVMe devices in different orders, so anything referring to `nvme0n1` will
eventually point at the wrong disk on one of them. **Interfaces are bound by MAC
and disks by `/dev/disk/by-id/` throughout** — never by kernel name.

Edit the MAC table in `bootc/config.toml` for your hardware first.

If you PXE boot: **Network Stack is disabled by default in most BIOSes.**

## C. Cluster, quorum, fencing

```
make substrate
```

This builds the cluster, joins both nodes, registers the `corosync-qdevice`
against your arbiter, and configures fencing.

**Three votes, not two.** A two-node cluster cannot tell a dead peer from an
unreachable one. `corosync-qnetd` on the arbiter casts the deciding vote. Do not
set `two_node: 1` and do not set `no-quorum-policy=ignore`.

Verify before going further — everything downstream assumes this works:

```
pcs quorum status          # Total votes: 3, qdevice present
pcs stonith fence node2    # must actually power-cycle the machine
```

Fencing that has never been exercised is the most common way a two-node cluster
fails in production. A cluster that cannot fence will, at the worst possible
moment, decline to recover anything.

## D. Replicated storage

```
make drbd
```

Two DRBD resources on LVM logical volumes, protocol C (synchronous — a write is
acknowledged only once it is on both nodes), each promoted on a different node:

```
store-a   Primary node1   Secondary node2    -> /var/store-a
store-b   Primary node2   Secondary node1    -> /var/store-b
```

Both hosts carry workload; neither is an idle standby. Either can take both during
a failure or a maintenance window, so size each node to run everything.

The initial sync copies the whole device and takes as long as your link and disks
dictate — roughly an hour for 430 GB over 2.5 GbE. **The resources are usable
during it**, but a resource will not promote on a node whose copy is still
inconsistent, so placement will look wrong until it finishes. That is correct
behaviour, not a fault.

```
drbdadm status             # UpToDate/UpToDate on both when complete
```

## E. Guests

```
make guests
```

Ubuntu cloud images, one per node, as `ocf:heartbeat:VirtualDomain` resources —
not `libvirt-guests`, which is all-or-nothing and gives Pacemaker no per-VM health
signal or placement control.

### Live migration is not available with this storage layer

Measure this expectation before you set it with anyone. Single-primary DRBD
mounts the replicated filesystem on **one node at a time**, so the migration
target cannot open the guest's disk and libvirt refuses outright:

```
error: Unsafe migration: Migration without shared storage is unsafe
```

Pacemaker then falls back to stop-and-start, so the guest does move — it simply
reboots to get there. Measured on this configuration, a planned move cost about
**12 seconds** of guest downtime, against roughly 15 seconds for an unplanned
node loss. No timeout or tuning changes this; it is a property of the
architecture, not a misconfiguration.

If genuine live migration is a requirement, DRBD needs `allow-two-primaries`
plus a cluster filesystem (GFS2) so both nodes can mount concurrently. That adds
DLM and `lvmlockd` to every node and makes fencing correctness load-bearing
rather than merely important — a materially heavier design than this one, and
out of scope here.

The role still configures the three prerequisites below, because they are needed
for any future move to a shared-storage layer and each fails silently on its own:

- **SSH host keys** trusted between the nodes, as root
- **A unique libvirt host UUID.** libvirt derives it from the DMI system UUID, and
  some vendors ship the *same* one in firmware on every unit — libvirt then sees
  one host and refuses to migrate. `machine-id` is unique, so
  `host_uuid_source = "machine-id"` fixes it. On identical hardware deployed from
  one image, every site would hit this.
- **Ports 49152-49215** open, or migration authenticates, starts, then fails with
  "no route to host"

## F. Verify

```
pcs status                 # both guests Started, no failed actions
drbdadm status             # UpToDate both sides
pcs quorum status          # 3 votes
```

Then test what you actually care about:

```
pcs node standby node1     # planned maintenance — guest restarts, ~12s
pcs stonith fence node1    # unplanned loss — should fence and recover
```

Measure the second one against a workload that writes continuously, not an idle
VM. An idle guest surviving a failover proves very little.

---

## What you end up with

```
node1, node2   RHEL 9, KVM, Pacemaker, three-vote quorum, BMC fencing
               vgstore: lv-store-a, lv-store-b
               DRBD protocol C, cross-primary
arbiter        corosync-qnetd
guests         one per node, Pacemaker-managed (cold move only — see above)
```

No shared storage array, no appliance in the data path, and every component in
RHEL.
