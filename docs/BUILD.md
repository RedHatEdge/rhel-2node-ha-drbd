# Build from nothing

Two-node RHEL 9 KVM HA cluster with DRBD replicated storage.

**Roughly 90 minutes**, most of it waiting for installs and the initial sync.

---

## Stage 0 — before you touch the servers

If you have two machines out of their boxes and nothing else, start here. This
stage is entirely about the things the rest of the guide assumes you already
have.

### The order, and why it is this order

The installer ISO decides which machine is which **by MAC address**, so you need
both MACs from both nodes *before* you can build it. But the nodes have no
operating system yet, so you cannot ask them. That is the one genuinely awkward
step, and it is resolved by reading the MACs out of firmware rather than from a
running system.

```
1. accounts and subscriptions          you, on the web
2. a build host                        one RHEL 9 machine or VM
3. read the MACs out of BIOS/BMC       no OS needed
4. write them into bootc/config.toml
5. build the image, then the ISO       on the build host
6. install both nodes from that ISO
7. make discover                       now the nodes can describe themselves
8. make substrate ... onwards          the rest of this guide
```

Steps 3 and 7 look similar but are not. Step 3 is you, reading two MACs off a
screen so the installer can tell the machines apart. Step 7 is the cluster
recording every disk and interface by an identifier that cannot move — which is
a different job, done once there is an OS to ask.

### 1. Accounts you will need

| | | |
|---|---|---|
| **Red Hat** | developers.redhat.com | free Developer Subscription covers 16 systems; entitles RHEL and the bootc base image |
| **registry.redhat.io** | same login | pulls the RHEL bootc base image |
| **An image registry** | quay.io free tier, or any OCI registry | the nodes pull their OS from here, so it must be reachable from the store |

The Red Hat account is the one to do first — the base image will not pull without
it, and everything else waits on that.

### 2. A build host

One RHEL 9 machine or VM. It builds the OS image and runs Ansible; it does not
become part of the cluster and can be switched off afterwards. Modest: 2 vCPU,
8 GB RAM, **40 GB free disk** — image builds are large.

```
sudo subscription-manager register --username <you>
sudo subscription-manager attach --auto
sudo dnf -y install podman git make python3-pip
```

Then log in to both registries — the first pulls the base image, the second is
where your built image goes:

```
podman login registry.redhat.io
podman login <your-registry>
```

**Build on RHEL, not Fedora or a Mac.** A subscribed RHEL host has entitlements
that podman passes into the build automatically, so the image can install RHEL
packages with no further configuration. On an unsubscribed host you have to feed
an activation key in as a build secret, which works but is a detour you do not
need.

### 3. Read the MACs out of firmware

Two per node — the management NIC and the storage NIC. No operating system
required:

- **From the BMC web interface**, if the machines have one. Usually under System
  or Network Inventory. This is also worth doing first because you need the BMC
  reachable later for fencing.
- **From the BIOS setup screen**, under the network or boot device list.
- **From a PXE or live-boot screen**, which prints the MAC as it requests an
  address.

Write down which physical port each belongs to. Getting management and storage
the wrong way round produces a node that installs cleanly and then cannot see its
own storage network, which is a confusing thing to debug later.

### 4. Put them in the MAC table

`bootc/config.toml` carries one line per node:

```
control_mac|hostname|control_ip|storage_mac|storage_ip
```

That table is what makes a single ISO able to install both machines: each one
matches its own MACs on boot and takes the matching hostname and addresses.
Nothing else distinguishes them, so this table has to be right.

Set your SSH public key in the same file while you are there — the build refuses
to proceed with the placeholder still in place, deliberately, because an image
you cannot log into is no use.

### 5. Build the image and the ISO

```
cd bootc
./build.sh --push --iso
```

The result is an installer ISO that installs either node. Write it to a USB stick
or attach it through the BMC's virtual media.

### 6. Install both nodes

Boot each machine from the ISO. It matches MACs, picks the OS disk by size, and
installs unattended. Nothing to answer.

If you PXE boot rather than using media: **most BIOSes ship with the network
stack disabled**, and it has to be turned on before the machine will PXE at all.

### 7. Now let the nodes describe themselves

```
cp inventory/hosts.yml.example inventory/hosts.yml     # put your addresses in
make discover
```

This runs against each node and writes `inventory/host_vars/<node>.yml`,
recording disks by `/dev/disk/by-id/` and interfaces by MAC.

**This is not optional and it is easy to skip**, because the rest of the guide
does not obviously fail without it — it fails later, on the wrong disk. Kernel
names move: `/dev/nvme0n1` can become `/dev/nvme1n1` after a reboot or a drive
swap, and interface names shift when firmware changes. Anything written into
configuration has to be pinned to something that cannot move, and this is the
step that captures it.

Read the generated files before continuing. If a node picked the wrong disk as
its storage device, now is the moment to notice — not after it has been
overwritten.

### 8. Continue

From here the rest of this guide applies, beginning with the networks section
below.

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
