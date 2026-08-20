# Two-node store platform — control node tasks.
#
#   make venv        create .venv and install pinned deps + collections
#   make ping        connectivity check against the inventory
#   make discover    gather hardware, write inventory/host_vars
#   make substrate   cluster, quorum, fencing, KVM  (both options need this)
#   make drbd        stage Option B
#   make svsan       stage Option A
#   make reset       tear the storage layer back to bare substrate
#   make status      pcs status from node1
#
# Everything runs inside .venv, so the system Ansible is never used.

VENV    := .venv
ANSIBLE := $(VENV)/bin/ansible
PLAYBOOK:= $(VENV)/bin/ansible-playbook
GALAXY  := $(VENV)/bin/ansible-galaxy
FENCE   ?= redfish

.PHONY: venv lock ping discover substrate drbd svsan reset status test clean

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

substrate: venv
	$(PLAYBOOK) playbooks/00-substrate.yml -e fence_backend=$(FENCE)

drbd: venv
	$(PLAYBOOK) playbooks/20-storage-drbd.yml -e storage_backend=drbd

reset: venv
	$(PLAYBOOK) playbooks/90-reset-storage.yml -e confirm_reset=yes

status: venv
	@$(ANSIBLE) node1 -a 'pcs status' 2>/dev/null || echo "cluster not formed yet"

test:
	tests/run-matrix.sh

clean:
	rm -rf $(VENV) collections

# ── Option A: appliance image ──────────────────────────────────────────────
# Converts the Hyper-V package to a KVM boot image. Uses the Hyper-V VHD rather
# than the vSphere OVA: the two disks are byte-identical, but the OVA declares
# transport com.vmware.guestInfo and ships no CD-ROM, so it expects config over
# the VMware Tools channel that KVM does not have.
#
#   make vsa-image ZIP=~/Downloads/svsan_6-7_windows_installer_plus_powershell.zip
diagrams:
	@python3 -c "\
import re,pathlib; \
h=pathlib.Path('docs/diagrams/svsan-architecture.html').read_text(); \
svgs=re.findall(r'(<svg viewBox=\"([^\"]+)\".*?</svg>)',h,flags=re.S); \
[ (lambda b,vb,n: pathlib.Path('docs/diagrams/%s.svg'%n).write_text( \
  '<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n' + \
  re.sub(r'<!--(.*?)-->', lambda m: '<!-- '+re.sub(r'-{2,}',' ',m.group(1)).strip()+' -->', \
    b.replace('<svg viewBox=','<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%s\" height=\"%s\" viewBox='%(vb.split()[2],vb.split()[3]),1) \
     .replace('>','><rect width=\"%s\" height=\"%s\" fill=\"#ffffff\"/>'%(vb.split()[2],vb.split()[3]),1), flags=re.S)+'\n'))(b,vb,n) \
  for (b,vb),n in zip(svgs,['svsan-architecture','svsan-quorum'])]"
	@for f in svsan-architecture svsan-quorum; do \
	  inkscape docs/diagrams/$$f.svg --export-type=png --export-filename=docs/diagrams/$$f.png --export-dpi=192 >/dev/null 2>&1; \
	  inkscape docs/diagrams/$$f.svg --export-type=pdf --export-filename=docs/diagrams/$$f.pdf >/dev/null 2>&1; \
	  echo "  docs/diagrams/$$f.{svg,png,pdf}"; \
	done

# Log the hosts in to the mirrored target and verify multipath.
# Requires the host IQNs to be in the target's ACL on the VSA first.
guests: venv
	$(VENV)/bin/ansible-playbook -i inventory playbooks/30-guests.yml \
	  -e storage_backend=$(or $(BACKEND),svsan)

# Apply iSCSI/multipath failover timing and rebuild sessions so it takes effect.