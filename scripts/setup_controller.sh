#!/bin/bash
# =============================================================================
# Zeroth Cloud v3 — Controller Setup Script
# PUBLIC IP TOPOLOGY
#
# Run this FIRST on jumpserver-01 (your Ansible controller).
# This is the only server you set up manually before Ansible takes over.
#
# Run from your LOCAL machine:
#   ssh root@<jumpserver-public-ip> 'bash -s' < scripts/setup_controller.sh
#
# Or copy it to the server and run directly:
#   scp scripts/setup_controller.sh root@<jumpserver-public-ip>:/tmp/
#   ssh root@<jumpserver-public-ip> bash /tmp/setup_controller.sh
# =============================================================================

set -euo pipefail

REPO_URL="https://github.com/upstream-owner/Zeroth-Cloud-v3-updated.git"
# Your zeroth_deploy PRIVATE key — paste the full contents between the markers
# Generate with: ssh-keygen -t ed25519 -C "zeroth-cloud-deploy" -f ~/.ssh/zeroth_deploy
DEPLOY_PRIVATE_KEY="FILL_ME_PASTE_PRIVATE_KEY_CONTENTS"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Must run as root"
[[ "$REPO_URL" == *"FILL_ME"* ]] && die "Set REPO_URL before running"
[[ "$DEPLOY_PRIVATE_KEY" == "FILL_ME"* ]] && die "Paste your deploy private key before running"

log "=== Zeroth Cloud v3 — Controller Setup ==="

# ─── SYSTEM UPDATE ────────────────────────────────────────────────────────────
log "Updating system"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git curl wget python3 python3-pip python3-venv \
  vim tmux jq net-tools unzip wireguard-tools
ok "System updated"

# ─── DEPLOY KEY ───────────────────────────────────────────────────────────────
log "Installing deploy SSH key"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "$DEPLOY_PRIVATE_KEY" > /root/.ssh/zeroth_deploy
chmod 600 /root/.ssh/zeroth_deploy
# Derive public key
ssh-keygen -y -f /root/.ssh/zeroth_deploy > /root/.ssh/zeroth_deploy.pub
ok "Deploy key installed"
echo "  Public key: $(cat /root/.ssh/zeroth_deploy.pub)"

# ─── ANSIBLE ─────────────────────────────────────────────────────────────────
log "Installing Ansible and dependencies"
pip3 install --break-system-packages --quiet ansible ansible-lint
ok "Ansible: $(ansible --version | head -1)"

# ─── CLONE REPO ───────────────────────────────────────────────────────────────
log "Cloning Zeroth Cloud repository"
if [[ -d /root/zeroth-cloud ]]; then
  warn "Repository already exists — pulling latest"
  cd /root/zeroth-cloud && git pull
else
  git clone "$REPO_URL" /root/zeroth-cloud
fi
cd /root/zeroth-cloud
ok "Repository cloned to /root/zeroth-cloud"

# ─── ANSIBLE GALAXY ──────────────────────────────────────────────────────────
log "Installing Ansible Galaxy collections"
ansible-galaxy install -r ansible/requirements.yml
ok "Galaxy collections installed"

# ─── VAULT PASSWORD FILE ──────────────────────────────────────────────────────
if [[ ! -f /root/.zeroth_vault_pass ]]; then
  log "Creating vault password file"
  echo "CHANGE_THIS_TO_A_STRONG_RANDOM_PASSWORD" > /root/.zeroth_vault_pass
  chmod 600 /root/.zeroth_vault_pass
  warn "IMPORTANT: Edit /root/.zeroth_vault_pass and set a strong password"
  warn "Then encrypt secrets: ansible-vault encrypt ansible/group_vars/all/secrets.yml"
fi

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
ok "Controller setup complete on $(hostname)"
echo ""
echo "  NEXT STEPS:"
echo ""
echo "  1. Fill in ALL placeholder IPs in:"
echo "     /root/zeroth-cloud/ansible/inventory/hosts.yml"
echo "     /root/zeroth-cloud/ansible/group_vars/all/main.yml"
echo ""
echo "  2. Fill secrets and encrypt:"
echo "     vim /root/zeroth-cloud/ansible/group_vars/all/secrets.yml"
echo "     ansible-vault encrypt ansible/group_vars/all/secrets.yml"
echo ""
echo "  3. Edit bootstrap.sh — paste your deploy public key:"
echo "     cat /root/.ssh/zeroth_deploy.pub"
echo "     vim /root/zeroth-cloud/scripts/bootstrap.sh  # paste into DEPLOY_PUBKEY"
echo ""
echo "  4. Run bootstrap_all.sh to bootstrap all other servers:"
echo "     bash /root/zeroth-cloud/scripts/bootstrap_all.sh"
echo ""
echo "  5. Verify all hosts respond:"
echo "     cd /root/zeroth-cloud && make ping"
echo "════════════════════════════════════════════════════════════════"
