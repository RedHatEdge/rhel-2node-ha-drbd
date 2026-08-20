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
0. decide the two networks             on paper, before anything else
1. accounts and subscriptions          you, on the web
2. a build host                        one RHEL 9 machine or VM
3. read the MACs out of BIOS/BMC       no OS needed — the machines have no OS yet
4. write MACs and addresses into bootc/config.toml
5. build the image, then the ISO       on the build host
6. install both nodes from that ISO
7. fill in the inventory               copy the .example files, edit them
8. make discover                       the nodes describe their own hardware
9. the lettered sections below         cluster, storage, guests
```

Steps 3 and 8 look similar but are not. Step 3 is you, reading two MACs off a
screen so the installer can tell the two machines apart. Step 8 is the cluster
recording every disk and interface by an identifier that cannot move — a
different job, and only possible once there is an OS to ask.

### 0. Decide the two networks first

| segment | subnet | carries |
|---|---|---|
| management | 172.16.7.0/24 (example) | corosync ring0, host and VSA management, witness |
| storage | 172.18.8.0/24 (example) | corosync ring1, mirror, iSCSI |

Use your own subnets — the examples above are what this was built on, and the
inventory ships with them as defaults, so reusing them saves editing.

**The storage segment must have no DHCP server, no gateway and no DNS.**

This is not tidiness. A pristine VSA takes DHCP on *every* interface and treats
each as management. If the storage segment answers DHCP, the appliance acquires a
second default route, and which one wins is a race. On two identical hosts running
the identical play, one appliance completed setup and the other could not reach
the network it needed. The build brings the appliances up on management first for
that reason; a storage segment handing out leases is also worth avoiding on its
own merits.

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

### 7. Fill in the inventory

Everything the playbooks need about *your* environment lives in three files. Each
ships as a `.example` — copy it, then edit. Nothing is generated for you at this
point except the per-node hardware facts in step 8.

```
cp inventory/hosts.yml.example          inventory/hosts.yml
cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml
```

**`inventory/hosts.yml`** — which machines, and how Ansible reaches them. Set
`ansible_host` for `node1`, `node2` and the arbiter to the management addresses
you chose in step 0.

**`inventory/group_vars/all.yml`** — everything else, and the one file worth
reading top to bottom. Anything marked `REPLACE` must change; the rest has a
working default. The values that matter most:

| | |
|---|---|
| `lan_gateway`, `lan_dns` | your management network |
| `repl_network` | your storage segment |
| `redfish_user`, `redfish_password` | BMC credentials — fencing does not work without them |
| `admin_ssh_key` | your public key, or you cannot log in |
| `admin_password_hash` | needed for Cockpit, which authenticates via PAM |
| `bootc_image` | where the nodes pull their OS from |

The real `hosts.yml` and `all.yml` are gitignored, so your addresses and
credentials stay out of version control while the `.example` files remain as the
template.

You do **not** create `inventory/host_vars/` by hand. The examples there show
what the files look like, but step 8 generates the real ones from the hardware
itself, which is more reliable than transcribing MAC addresses.

### 8. Now let the nodes describe themselves

```
make discover
```

This runs against each node and writes `inventory/host_vars/<node>.yml`,
recording disks by `/dev/disk/by-id/` and interfaces by MAC — overwriting
anything already there, which is why step 7 says not to write them yourself.

**This is not optional and it is easy to skip**, because the rest of the guide
does not obviously fail without it — it fails later, on the wrong disk. Kernel
names move: `/dev/nvme0n1` can become `/dev/nvme1n1` after a reboot or a drive
swap, and interface names shift when firmware changes. Anything written into
configuration has to be pinned to something that cannot move, and this is the
step that captures it.

Read the generated files before continuing:

```
cat inventory/host_vars/node1.yml
```

Check `storage_device` is the disk you intend to give to storage and **not** the
OS disk, and that `control_mac` and `repl_mac` are the right way round. If a node
picked wrong, correct the file now — not after it has been overwritten.

### 9. Continue

From here, work through the lettered sections below in order.

---

## Using Ansible directly instead of make

`make` is a thin wrapper. Every target runs an ordinary playbook, and you can run
them yourself if you prefer — nothing in this repository requires make.

What the wrapper does add is worth knowing before you skip it:

- **A pinned toolchain.** `make venv` builds a virtualenv from `requirements.txt`
  (`ansible-core>=2.16,<2.20`) and installs the collections into `./collections`,
  deliberately never touching system Python. Run playbooks with a distro Ansible
  and you get whatever version it ships, against collections that may not match.
- **The flags that matter.** `00-substrate.yml` reconfigures host networking
  according to `storage_backend`, so running it with the wrong value against a
  live cluster reconfigures the storage NIC underneath a running system — while
  reporting success. The make targets pin the value for you. If you call the
  playbooks directly, pass it yourself and pass it correctly.

Activate the virtualenv first so you get the pinned Ansible:

```
make venv                      # once
source .venv/bin/activate
```

Run from the repository root — `ansible.cfg` there supplies the inventory path,
the roles path and the collections path, so the commands below need no `-i`.

Then each target maps to:

| make | ansible-playbook |
|---|---|
| `make discover` | `ansible-playbook playbooks/01-discover.yml` |
| `make substrate` | `ansible-playbook playbooks/00-substrate.yml -e storage_backend=drbd -e fence_backend=redfish` |
| `make admin` | `… playbooks/00-substrate.yml -e storage_backend=drbd -e fence_backend=redfish --tags admin` |
| `make drbd` | `… playbooks/20-storage-drbd.yml -e storage_backend=drbd` |
| `make guests` | `… playbooks/30-guests.yml -e storage_backend=drbd` |

`FENCE` defaults to `redfish`; override with `make substrate FENCE=ipmilan` or by
changing `-e fence_backend=`.

The image build is not Ansible at all — `bootc/build.sh` is a shell script and is
run directly either way.

Useful additions when running playbooks by hand:

```
--check --diff        # dry run, show what would change
--limit node1         # one host
--tags admin          # one part of a play
-v                    # or -vvv when something is not doing what you expect
```

`--check` is worth knowing about: several plays in here are destructive by
design, and a dry run tells you which tasks would fire before they do.

---

## A. Install the two nodes

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

## B. Cluster, quorum, fencing

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

## C. Replicated storage

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

## D. Guests

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

## E. Verify

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
