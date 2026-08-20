# Two-node store platform — control node tasks.
#
#   make venv        create .venv and install pinned deps + collections
#   make ping        connectivity check against the inventory
#   make discover    gather hardware, write inventory/host_vars
#   make substrate   cluster, quorum, fencing, KVM
#   make admin       admin account + Cockpit only (safe on a live cluster)
#   make drbd        replicated storage under Pacemaker
#   make guests      workload guests on the replicated volumes
#   make status      pcs status from node1
#   make test        acceptance matrix (CONFIRM=yes for the disruptive ones)
#
# Everything runs inside .venv, so the system Ansible is never used.

VENV    := .venv
ANSIBLE := $(VENV)/bin/ansible
PLAYBOOK:= $(VENV)/bin/ansible-playbook
GALAXY  := $(VENV)/bin/ansible-galaxy
FENCE   ?= redfish

.PHONY: venv lock ping discover substrate drbd guests status test clean

venv: $(VENV)/.stamp
$(VENV)/.stamp: requirements.txt requirements.yml
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet --upgrade pip
	$(VENV)/bin/pip install --quiet -r requirements.txt
	$(GALAXY) collection install -r requirements.yml -p ./collections --force
	@touch $@
	@echo
	@$(ANSIBLE) --version | head -2
	@echo "ready — run 'make ping'"

lock: venv
	@$(VENV)/bin/pip freeze > requirements.lock
	@$(GALAXY) collection list -p ./collections 2>/dev/null | grep -E '^[a-z]' > collections.lock || true
	@echo "wrote requirements.lock and collections.lock"

ping: venv
	$(ANSIBLE) all -m ping

discover: venv
	$(PLAYBOOK) playbooks/01-discover.yml

# storage_backend is passed explicitly and pinned to this repository's backend.
#
# It is not cosmetic. The substrate play configures host networking and attaches
# the storage NIC according to storage_backend -- DRBD does not need the storage NIC bridged.
# Leaving it to a default means one wrong value silently reconfigures the
# storage network out from under a running cluster: bridge torn down, address
# moved to the physical NIC, every path dropped, and the play still reports
# success. Pin it.
substrate: venv
	$(PLAYBOOK) playbooks/00-substrate.yml \
	  -e storage_backend=drbd -e fence_backend=$(FENCE)

# Operator access only -- the admin account and Cockpit. Touches no networking,
# so it is safe against a live cluster. Prefer this over a full substrate run
# when that is all you need.
admin: venv
	$(PLAYBOOK) playbooks/00-substrate.yml \
	  -e storage_backend=drbd -e fence_backend=$(FENCE) --tags admin

drbd: venv
	$(PLAYBOOK) playbooks/20-storage-drbd.yml -e storage_backend=drbd

status: venv
	@$(ANSIBLE) node1 -a 'pcs status' 2>/dev/null || echo "cluster not formed yet"

test:
	tests/run-matrix.sh

clean:
	rm -rf $(VENV) collections


# Log the hosts in to the mirrored target and verify multipath.
# Requires the host IQNs to be in the target's ACL on the VSA first.
guests: venv
	$(VENV)/bin/ansible-playbook -i inventory playbooks/30-guests.yml \
	  -e storage_backend=drbd

# Apply iSCSI/multipath failover timing and rebuild sessions so it takes effect.
