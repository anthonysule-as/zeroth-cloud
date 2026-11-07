#!/bin/bash
# =============================================================================
# Zeroth Cloud v3 — Server Bootstrap Script
# PUBLIC IP TOPOLOGY | Ubuntu 24.04 LTS | Colocation Facility
#
# Run ONCE on each server immediately after OS installation.
# After this completes, all further management is via Ansible from the controller.
#
# CRITICAL SECURITY ACTION:
#   This script locks SSH access to the Ansible controller public IP ONLY.
#   Every server currently exposed on port 22 to the internet will be locked
#   down immediately when this script runs.
#
# Usage (run FROM the controller via ssh, or directly on the server):
#   bash bootstrap.sh <hostname> <role> <controller_public_ip>
#
# Roles:
#   jumpserver | wireguard | haproxy | wazuh_dedicated | wazuh_shared
#   opensearch | postgresql | analytics | llama | monitoring | tang | standby
#
# Example:
#   bash bootstrap.sh wazuh-mgr-01 wazuh_dedicated 41.216.x.x
# =============================================================================

set -euo pipefail

# ─── ARGS ────────────────────────────────────────────────────────────────────
if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <hostname> <role> <controller_public_ip>"
  echo "Example: $0 wazuh-mgr-01 wazuh_dedicated <REDACTED_IP_43>"
  exit 1
fi

HOSTNAME="$1"
ROLE="$2"
CONTROLLER_PUBLIC_IP="$3"

# ─── DEPLOY PUBLIC KEY ───────────────────────────────────────────────────────
# Contents of ~/.ssh/zeroth_deploy.pub from your controller
# This is injected here so the controller can SSH back after bootstrap.
DEPLOY_PUBKEY="ssh-ed25519 REDACTED_SSH_PUBKEY zeroth-cloud-deploy"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[✓] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Must run as root"
[[ "$DEPLOY_PUBKEY" == "FILL_ME"* ]] && die "Fill in DEPLOY_PUBKEY before running bootstrap"

log "=== Zeroth Cloud v3 Bootstrap: $HOSTNAME ($ROLE) ==="
log "=== Controller IP: $CONTROLLER_PUBLIC_IP ==="

# ─── HOSTNAME ────────────────────────────────────────────────────────────────
log "Setting hostname"
hostnamectl set-hostname "$HOSTNAME"
grep -q "$HOSTNAME" /etc/hosts || echo "<REDACTED_IP_44> $HOSTNAME" >> /etc/hosts
ok "Hostname: $HOSTNAME"

# ─── SSH HARDENING ────────────────────────────────────────────────────────────
log "Injecting deploy public key and hardening SSH"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "$DEPLOY_PUBKEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

cat > /etc/ssh/sshd_config.d/99-zeroth.conf << EOF
# Zeroth Cloud v3 — SSH hardening
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
Banner /etc/ssh/zeroth_banner
EOF

cat > /etc/ssh/zeroth_banner << EOF

  ╔══════════════════════════════════════════════════════╗
  ║          ZEROTH CLOUD v3 — RESTRICTED ACCESS         ║
  ║   Resilience Technologies Limited | CONFIDENTIAL     ║
  ║   Unauthorized access is strictly prohibited.        ║
  ╚══════════════════════════════════════════════════════╝

EOF

systemctl restart ssh
ok "SSH hardened — key-only authentication enforced"

# ─── SYSTEM UPDATE ────────────────────────────────────────────────────────────
log "Updating system packages (this may take a few minutes)"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
ok "System updated"

# ─── BASE PACKAGES ────────────────────────────────────────────────────────────
log "Installing base packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  python3 python3-pip python3-venv \
  git curl wget \
  ufw fail2ban \
  jq net-tools htop vim tmux unzip \
  gnupg lsb-release \
  ca-certificates apt-transport-https software-properties-common \
  chrony \
  clevis clevis-luks clevis-initramfs \
  wireguard wireguard-tools
ok "Base packages installed"

# ─── FIREWALL — PUBLIC IP LOCKDOWN ───────────────────────────────────────────
# CRITICAL: This is the security-critical step.
# Servers are currently exposed on port 22 to the open internet.
# After this block, ONLY the Ansible controller can SSH in.
log "Configuring UFW — locking down public SSH exposure"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH: controller only — block everything else
ufw allow from "$CONTROLLER_PUBLIC_IP" to any port 22 proto tcp \
  comment "Ansible controller SSH — zeroth-cloud"

# WireGuard: public — org clients need to reach this from anywhere
# (harmless on non-gateway servers — port just won't be used)
ufw allow 51820/udp comment "WireGuard VPN"

# Prometheus node exporter: WireGuard overlay only (set after WireGuard deploys)
# Added here as a placeholder — restricted further by wireguard.yml
ufw allow from <REDACTED_IP_2>/8 to any port 9100 proto tcp \
  comment "Prometheus node exporter — WireGuard overlay only"

ufw --force enable
ok "UFW enabled — SSH locked to controller ($CONTROLLER_PUBLIC_IP) only"

# ─── FAIL2BAN ────────────────────────────────────────────────────────────────
log "Configuring fail2ban"
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
ignoreip = 127.0.0.1/8 $CONTROLLER_PUBLIC_IP <REDACTED_IP_2>/8

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
maxretry = 3
EOF
systemctl enable --now fail2ban
ok "fail2ban enabled — SSH brute-force protection active"

# ─── TIME SYNC ────────────────────────────────────────────────────────────────
log "Configuring time sync (chrony)"
systemctl enable --now chrony
ok "Time sync active"

# ─── PROMETHEUS NODE EXPORTER ────────────────────────────────────────────────
log "Installing Prometheus node exporter"
NODE_EXPORTER_VERSION="1.8.1"
ARCH="linux-amd64"
NE_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz"

wget -q "$NE_URL" -O /tmp/node_exporter.tar.gz
tar xzf /tmp/node_exporter.tar.gz -C /tmp
mv "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}/node_exporter" /usr/local/bin/
chmod +x /usr/local/bin/node_exporter
rm -rf /tmp/node_exporter*

cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Prometheus Node Exporter — Zeroth Cloud
After=network.target

[Service]
Type=simple
User=root
# Bind to WireGuard overlay only after WireGuard is up.
# During bootstrap, listens on all interfaces but UFW restricts access.
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=0.0.0.0:9100 \
  --collector.systemd \
  --collector.processes
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter
ok "Node exporter running on :9100"

# ─── ANSIBLE ─────────────────────────────────────────────────────────────────
log "Installing Ansible"
pip3 install --break-system-packages --quiet ansible
ok "Ansible installed: $(ansible --version | head -1)"

# ─── SERVER IDENTITY ─────────────────────────────────────────────────────────
mkdir -p /etc/zeroth
echo "$ROLE"                           > /etc/zeroth/role
echo "$HOSTNAME"                       > /etc/zeroth/hostname
echo "$CONTROLLER_PUBLIC_IP"          > /etc/zeroth/controller_ip
date -u +%Y-%m-%dT%H:%M:%SZ          > /etc/zeroth/bootstrapped_at
ok "Server identity recorded in /etc/zeroth/"

# ─── MOTD ────────────────────────────────────────────────────────────────────
cat > /etc/motd << EOF

  ╔══════════════════════════════════════════════════════╗
  ║           ZEROTH CLOUD v3 — MANAGED NODE             ║
  ║   Resilience Technologies Limited | CONFIDENTIAL     ║
  ╠══════════════════════════════════════════════════════╣
  ║  Hostname   : $HOSTNAME
  ║  Role       : $ROLE
  ║  Controller : $CONTROLLER_PUBLIC_IP
  ║                                                      ║
  ║  All changes must be applied via Ansible only.       ║
  ╚══════════════════════════════════════════════════════╝

EOF

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
ok "Bootstrap complete: $HOSTNAME (role: $ROLE)"
echo ""
echo "  Security actions taken:"
echo "  ✓ SSH locked — only $CONTROLLER_PUBLIC_IP can connect"
echo "  ✓ Password auth disabled — key-only"
echo "  ✓ fail2ban active"
echo "  ✓ UFW enabled — all ports blocked except SSH + WireGuard"
echo ""
echo "  Next step — from the Ansible controller:"
echo "  ansible $HOSTNAME -i ansible/inventory/hosts.yml -m ping"
echo "════════════════════════════════════════════════════════════════"
