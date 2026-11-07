#!/bin/bash
# =============================================================================
# Zeroth Cloud v3 — Bootstrap All Servers
# PUBLIC IP TOPOLOGY
#
# Runs bootstrap.sh on every server in the inventory sequentially.
# Run this from the Ansible controller (jumpserver-01) after setup_controller.sh.
#
# Prerequisites:
#   - scripts/bootstrap.sh has DEPLOY_PUBKEY filled in
#   - ansible/inventory/hosts.yml has all IPs filled in
#   - You can SSH to all servers as root using the deploy key
#
# Usage:
#   cd /root/zeroth-cloud
#   bash scripts/bootstrap_all.sh
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$REPO_DIR/scripts/bootstrap.sh"
INVENTORY="$REPO_DIR/ansible/inventory/hosts.yml"
DEPLOY_KEY="$HOME/.ssh/zeroth_deploy"
CONTROLLER_IP="$(curl -sf https://api.ipify.org || hostname -I | awk '{print $1}')"
SSH_OPTS="-i $DEPLOY_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes"

log()     { echo ""; echo "──────────────────────────────────────────────"; echo "[$(date '+%H:%M:%S')] $*"; }
ok()      { echo "  [✓] $*"; }
fail()    { echo "  [✗] $*"; FAILED_HOSTS+=("$*"); }
summary() { echo "  [→] $*"; }

FAILED_HOSTS=()

# ─── VALIDATE ────────────────────────────────────────────────────────────────
[[ ! -f "$BOOTSTRAP" ]]   && { echo "[✗] bootstrap.sh not found at $BOOTSTRAP"; exit 1; }
[[ ! -f "$DEPLOY_KEY" ]]  && { echo "[✗] Deploy key not found at $DEPLOY_KEY"; exit 1; }
[[ ! -f "$INVENTORY" ]]   && { echo "[✗] Inventory not found at $INVENTORY"; exit 1; }

grep -q "FILL_ME_WITH_CONTENTS_OF_zeroth_deploy.pub" "$BOOTSTRAP" && {
  echo "[✗] bootstrap.sh still has FILL_ME placeholders."
  echo "    Paste your deploy public key into the DEPLOY_PUBKEY variable first."
  exit 1
}

grep -q "FILL_ME" "$INVENTORY" && {
  echo "[✗] hosts.yml still has FILL_ME placeholders."
  echo "    Fill in all server public IPs before running this script."
  exit 1
}

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Zeroth Cloud v3 — Bootstrap All Servers"
echo "  Controller IP : $CONTROLLER_IP"
echo "  Deploy key    : $DEPLOY_KEY"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "This will:"
echo "  1. Copy bootstrap.sh to each server"
echo "  2. Run it — locking SSH to this controller ($CONTROLLER_IP) immediately"
echo "  3. Install base packages, UFW, fail2ban, node_exporter"
echo ""
read -rp "Proceed with bootstrapping ALL servers? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ─── SERVER MAP: hostname → public_ip → role ─────────────────────────────────
# Parse from inventory using Python (avoids yq dependency)
SERVER_MAP=$(python3 << 'PYEOF'
import yaml, sys

with open("ansible/inventory/hosts.yml") as f:
    inv = yaml.safe_load(f)

def walk(node, role_hint=None):
    results = []
    if not isinstance(node, dict):
        return results
    if "hosts" in node:
        for hname, hdata in (node["hosts"] or {}).items():
            if hdata and "ansible_host" in hdata:
                ip = hdata["ansible_host"]
                if ip != "FILL_ME":
                    results.append((hname, ip, role_hint or "generic"))
    if "children" in node:
        for gname, gdata in (node["children"] or {}).items():
            child_role = gname.rstrip("s").replace("_", "_")
            results.extend(walk(gdata or {}, child_role))
    return results

entries = walk(inv.get("all", {}))
seen = set()
for name, ip, role in entries:
    if name not in seen:
        seen.add(name)
        print(f"{name} {ip} {role}")
PYEOF
)

# ─── SCAN HOST KEYS ──────────────────────────────────────────────────────────
log "Scanning SSH host keys for all servers"
while IFS=' ' read -r hostname ip role; do
  ssh-keyscan -T 10 -H "$ip" >> ~/.ssh/known_hosts 2>/dev/null && \
    ok "Key scanned: $hostname ($ip)" || \
    warn "Could not scan: $hostname ($ip) — may already be in known_hosts"
done <<< "$SERVER_MAP"

# ─── BOOTSTRAP EACH SERVER ───────────────────────────────────────────────────
# Order matters: infrastructure first, then compute, then data, then apps

declare -A ROLE_ORDER=(
  [haproxy]=1
  [wireguard_gateways]=2
  [tang]=3
  [opensearch]=4
  [postgresql]=5
  [wazuh_dedicated]=6
  [wazuh_shared]=7
  [analytics]=8
  [llama]=9
  [monitoring]=10
  [siteb_standby]=11
  [jumpserver]=99   # Controller bootstraps itself last
)

bootstrap_server() {
  local hostname="$1"
  local ip="$2"
  local role="$3"

  log "Bootstrapping: $hostname ($ip) — role: $role"

  # Copy bootstrap script
  if ! scp $SSH_OPTS "$BOOTSTRAP" "root@${ip}:/tmp/bootstrap.sh" 2>/dev/null; then
    fail "$hostname ($ip) — SCP failed"
    return 1
  fi

  # Run bootstrap
  if ssh $SSH_OPTS "root@${ip}" "bash /tmp/bootstrap.sh '$hostname' '$role' '$CONTROLLER_IP'" 2>&1 | \
     sed "s/^/  [$hostname] /"; then
    ok "$hostname bootstrap complete"
  else
    fail "$hostname ($ip) — bootstrap script failed (exit $?)"
    return 1
  fi
}

# Sort by role order and bootstrap
while IFS=' ' read -r hostname ip role; do
  # Skip jumpserver (controller) — bootstrap itself last
  if [[ "$hostname" == "jumpserver-01" ]]; then
    continue
  fi
  bootstrap_server "$hostname" "$ip" "$role" || true
done <<< "$SERVER_MAP"

# Bootstrap the controller itself last
log "Bootstrapping controller (jumpserver-01) — self-bootstrap"
CONTROLLER_ENTRY=$(grep "jumpserver-01" <<< "$SERVER_MAP" || true)
if [[ -n "$CONTROLLER_ENTRY" ]]; then
  read -r js_hostname js_ip js_role <<< "$CONTROLLER_ENTRY"
  bash "$BOOTSTRAP" "$js_hostname" "$js_role" "$CONTROLLER_IP"
  ok "Controller self-bootstrap complete"
fi

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  BOOTSTRAP SUMMARY"
echo "════════════════════════════════════════════════════════════════"

TOTAL=$(echo "$SERVER_MAP" | wc -l)
FAILED=${#FAILED_HOSTS[@]}
PASSED=$((TOTAL - FAILED))

echo "  Total servers : $TOTAL"
echo "  Succeeded     : $PASSED"
echo "  Failed        : $FAILED"

if [[ $FAILED -gt 0 ]]; then
  echo ""
  echo "  Failed hosts (must resolve before proceeding):"
  for h in "${FAILED_HOSTS[@]}"; do
    echo "    ✗ $h"
  done
  echo ""
  echo "  Fix failures then re-run for failed hosts only:"
  echo "  bash scripts/bootstrap.sh <hostname> <role> $CONTROLLER_IP"
  exit 1
else
  echo ""
  echo "  All servers bootstrapped successfully."
  echo ""
  echo "  NEXT — verify Ansible connectivity to all hosts:"
  echo "  cd /root/zeroth-cloud && make ping"
fi
echo "════════════════════════════════════════════════════════════════"
