#!/bin/bash
# Zeroth Cloud v3 — Per-Device WireGuard Onboarding
# Usage: bash scripts/add_device.sh --org org01 --device laptop-alice
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INVENTORY="$REPO_ROOT/ansible/inventory"
OUTPUT_DIR="$REPO_ROOT/ansible/output"
MAIN_VARS="$REPO_ROOT/ansible/group_vars/all/main.yml"
WG_CONF="/etc/wireguard/wg0.conf"
DEPLOY_KEY="$HOME/.ssh/zeroth_deploy"
ORG_NAME=""; DEVICE_NAME=""
usage() { echo "Usage: $0 --org <org-name> --device <device-name>"; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)    ORG_NAME="$2";    shift 2 ;;
    --device) DEVICE_NAME="$2"; shift 2 ;;
    *)        usage ;;
  esac
done
[[ -z "$ORG_NAME" || -z "$DEVICE_NAME" ]] && usage
DEVICE_NAME=$(echo "$DEVICE_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
ORG_META="$INVENTORY/orgs/${ORG_NAME}.yml"
[[ ! -f "$ORG_META" ]] && { echo "[x] Org '$ORG_NAME' not found. Run 'make enroll' first."; exit 1; }
ORG_ID=$(grep "org_id:" "$ORG_META" | awk '{print $2}')
SUBNET="10.${ORG_ID}.0"
echo ""; echo "======================================================"
echo "  ZEROTH CLOUD v3 — DEVICE ONBOARDING"
echo "  Org: $ORG_NAME | Device: $DEVICE_NAME | Subnet: ${SUBNET}.0/24"
echo "======================================================"; echo ""
DEVICE_DIR="$INVENTORY/orgs/devices"
DEVICE_REGISTRY="$DEVICE_DIR/${ORG_NAME}-devices.yml"
mkdir -p "$DEVICE_DIR"
if [[ ! -f "$DEVICE_REGISTRY" ]]; then
  cat > "$DEVICE_REGISTRY" << EOF
org_name: $ORG_NAME
org_id: $ORG_ID
next_ip: 2
devices: []
EOF
fi
if grep -q "name: $DEVICE_NAME" "$DEVICE_REGISTRY" 2>/dev/null; then
  echo "[!] Device '$DEVICE_NAME' already exists."
  EXISTING_IP=$(grep -A2 "name: $DEVICE_NAME" "$DEVICE_REGISTRY" | grep "ip:" | awk '{print $2}')
  read -rp "    Regenerate config? [y/N]: " REGEN
  [[ "$REGEN" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  DEVICE_IP="$EXISTING_IP"
  REGENERATE=true
else
  REGENERATE=false
  DEVICE_IP=$(grep "next_ip:" "$DEVICE_REGISTRY" | awk '{print $2}')
  [[ "$DEVICE_IP" -gt 254 ]] && { echo "[x] No IPs available in ${SUBNET}.0/24"; exit 1; }
  echo "[+] Assigned IP: ${SUBNET}.${DEVICE_IP}/24"
fi
command -v wg >/dev/null 2>&1 || { echo "[x] wireguard-tools not installed"; exit 1; }
WG_PRIVATE_KEY=$(wg genkey)
WG_PUBLIC_KEY=$(echo "$WG_PRIVATE_KEY" | wg pubkey)
echo "[+] WireGuard keypair generated (pubkey: $WG_PUBLIC_KEY)"
GW_A_PUBKEY=$(grep -A2 "GATEWAY A" "$WG_CONF" | grep PublicKey | awk '{print $NF}')
GW_B_PUBKEY=$(grep -A2 "GATEWAY B" "$WG_CONF" | grep PublicKey | awk '{print $NF}')
GW_A_IP=$(grep "^wg_gateway_a_public_ip:" "$MAIN_VARS" | awk -F'"' '{print $2}')
GW_B_IP=$(grep "^wg_gateway_b_public_ip:" "$MAIN_VARS" | awk -F'"' '{print $2}')
[[ -z "$GW_A_PUBKEY" || -z "$GW_B_PUBKEY" ]] && { echo "[x] Cannot read gateway keys from $WG_CONF"; exit 1; }
echo "[+] Adding peer to gateways..."
for GW_IP in "$GW_A_IP" "$GW_B_IP"; do
  ssh -i "$DEPLOY_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${GW_IP}" "
    wg set wg0 peer $WG_PUBLIC_KEY allowed-ips ${SUBNET}.${DEVICE_IP}/32
    if ! grep -q '${ORG_NAME}-${DEVICE_NAME}' /etc/wireguard/wg0.conf 2>/dev/null; then
      cat >> /etc/wireguard/wg0.conf << PEER
# BEGIN DEVICE ${ORG_NAME}-${DEVICE_NAME}
[Peer]
# Device: ${DEVICE_NAME} | Org: ${ORG_NAME} | IP: ${SUBNET}.${DEVICE_IP}
PublicKey  = ${WG_PUBLIC_KEY}
AllowedIPs = ${SUBNET}.${DEVICE_IP}/32
# END DEVICE ${ORG_NAME}-${DEVICE_NAME}
PEER
    fi
  " 2>/dev/null && echo "    Gateway $GW_IP: done" || echo "    Gateway $GW_IP: FAILED"
done
mkdir -p "$OUTPUT_DIR"
CONFIG_FILE="$OUTPUT_DIR/${ORG_NAME}-${DEVICE_NAME}-wg.conf"
cat > "$CONFIG_FILE" << WGEOF
# Zeroth Cloud v3 — WireGuard Device Config
# Org: ${ORG_NAME} | Device: ${DEVICE_NAME} | IP: ${SUBNET}.${DEVICE_IP}
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# CONFIDENTIAL — Deliver via Signal or PGP-encrypted email.
[Interface]
Address    = ${SUBNET}.${DEVICE_IP}/24
PrivateKey = ${WG_PRIVATE_KEY}
DNS        = 1.1.1.1, 8.8.8.8
[Peer]
# Site A — Primary gateway
PublicKey           = ${GW_A_PUBKEY}
Endpoint            = ${GW_A_IP}:51820
AllowedIPs          = ${SUBNET}.0/24, <REDACTED_IP_2>/24
PersistentKeepalive = 25
[Peer]
# Site B — Failover gateway
PublicKey           = ${GW_B_PUBKEY}
Endpoint            = ${GW_B_IP}:51820
AllowedIPs          = ${SUBNET}.0/24
PersistentKeepalive = 25
WGEOF
chmod 600 "$CONFIG_FILE"
if [[ "$REGENERATE" == "false" ]]; then
  NEXT_IP=$((DEVICE_IP + 1))
  sed -i "s/^next_ip: .*/next_ip: $NEXT_IP/" "$DEVICE_REGISTRY"
  cat >> "$DEVICE_REGISTRY" << ENTRY
  - name: $DEVICE_NAME
    ip: $DEVICE_IP
    overlay_ip: ${SUBNET}.${DEVICE_IP}
    public_key: $WG_PUBLIC_KEY
    added_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ENTRY
fi
echo ""
echo "======================================================"
echo "  DEVICE ONBOARDED — ${DEVICE_NAME}"
echo "======================================================"
echo "  Org:        $ORG_NAME"
echo "  Device:     $DEVICE_NAME"
echo "  Overlay IP: ${SUBNET}.${DEVICE_IP}"
echo "  Config:     $CONFIG_FILE"
echo "======================================================"
echo ""
echo "  Next steps:"
echo "  1. Deliver config via Signal or PGP email"
echo "  2. Install WireGuard + import config"
echo "  3. Install Wazuh agent (manager: <REDACTED_IP_5>, group: ${ORG_NAME})"
echo "  4. Delete config after delivery"
echo ""
