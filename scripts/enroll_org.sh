#!/bin/bash
# Zeroth Cloud v3 — Organization Enrollment Script
# Wrapper for ansible/playbooks/enroll_org.yml
# Usage: bash scripts/enroll_org.sh --org-name ORG --org-id ID --risk-tier TIER --wireguard-subnet SUBNET

set -euo pipefail

INVENTORY="ansible/inventory/hosts.yml"
PLAYBOOK="ansible/playbooks/enroll_org.yml"
VAULT_PASS_FILE="${VAULT_PASS_FILE:-~/.zeroth_vault_pass}"

ORG_NAME=""; ORG_ID=""; RISK_TIER=""; WG_SUBNET=""

usage() {
  echo "Usage: $0 --org-name NAME --org-id ID --risk-tier TIER --wireguard-subnet SUBNET"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org-name)         ORG_NAME="$2";  shift 2 ;;
    --org-id)           ORG_ID="$2";   shift 2 ;;
    --risk-tier)        RISK_TIER="$2"; shift 2 ;;
    --wireguard-subnet) WG_SUBNET="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$ORG_NAME" || -z "$ORG_ID" || -z "$RISK_TIER" || -z "$WG_SUBNET" ]] && usage
[[ "$RISK_TIER" != "dedicated" && "$RISK_TIER" != "shared" ]] && { echo "[✗] risk-tier must be 'dedicated' or 'shared'"; exit 1; }
[[ "$ORG_ID" -lt 1 || "$ORG_ID" -gt 255 ]] 2>/dev/null && { echo "[✗] org-id must be 1–255"; exit 1; }

echo ""; echo "══════════════════════════════════════════════════"
echo "  ZEROTH CLOUD v3 — ORG ENROLLMENT"
echo "  Org: $ORG_NAME | ID: $ORG_ID | Tier: $RISK_TIER | Subnet: $WG_SUBNET"
echo "══════════════════════════════════════════════════"; echo ""
read -rp "Proceed? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

command -v wg >/dev/null 2>&1 || { echo "[✗] wireguard-tools not installed (need 'wg' command)"; exit 1; }

# ── Idempotency check — skip key generation if org already enrolled ──────────
ORG_META="/root/zeroth-cloud/ansible/inventory/orgs/${ORG_NAME}.yml"
REUSE_KEYS=false

if [[ -f "$ORG_META" ]]; then
  EXISTING_PUBKEY=$(grep "wg_public_key:" "$ORG_META" | awk '{print $2}')
  echo "[!] Org $ORG_NAME is already enrolled (found $ORG_META)"
  echo "    Existing public key: $EXISTING_PUBKEY"
  echo ""
  echo "    1) Re-provision with EXISTING keys (safe — does not invalidate client configs)"
  echo "    2) Generate NEW keys (will invalidate any previously delivered client configs)"
  echo "    3) Abort"
  read -rp "    Choice [1/2/3]: " KEY_CHOICE
  case "$KEY_CHOICE" in
    1)
      WG_PUBLIC_KEY="$EXISTING_PUBKEY"
      WG_PRIVATE_KEY="REUSE"
      REUSE_KEYS=true
      echo "[+] Re-using existing WireGuard keypair"
      echo "    Public key: $WG_PUBLIC_KEY"
      ;;
    2)
      WG_PRIVATE_KEY=$(wg genkey)
      WG_PUBLIC_KEY=$(echo "$WG_PRIVATE_KEY" | wg pubkey)
      echo "[+] NEW WireGuard keypair generated"
      echo "    Public key: $WG_PUBLIC_KEY"
      echo "[!] WARNING: Previously delivered client configs are now INVALID."
      ;;
    *)
      echo "Aborted."; exit 0 ;;
  esac
else
  WG_PRIVATE_KEY=$(wg genkey)
  WG_PUBLIC_KEY=$(echo "$WG_PRIVATE_KEY" | wg pubkey)
  echo "[+] WireGuard keypair generated"
  echo "    Public key: $WG_PUBLIC_KEY"
fi

VAULT_ARG="--vault-password-file $VAULT_PASS_FILE"
[[ ! -f "$VAULT_PASS_FILE" ]] && VAULT_ARG="--ask-vault-pass"

ansible-playbook -i "$INVENTORY" "$PLAYBOOK" $VAULT_ARG \
  -e "org_name=$ORG_NAME" \
  -e "org_id=$ORG_ID" \
  -e "risk_tier=$RISK_TIER" \
  -e "wireguard_subnet=$WG_SUBNET" \
  -e "wg_org_public_key=$WG_PUBLIC_KEY" \
  -e "wg_org_private_key=$WG_PRIVATE_KEY"

# ── Generate org WireGuard client config
if [[ "$REUSE_KEYS" == "true" ]]; then
  echo "[i] Skipping client config generation (re-using existing keys)."
else ──────────────────────────────────────
mkdir -p "$(dirname "$0")/../ansible/output"
source <(grep -E "^wg_gateway_[ab]_public_ip:" "$(dirname "$0")/../ansible/group_vars/all/main.yml" |   sed 's/:.*//' | while read var; do
    val=$(grep "^${var}:" "$(dirname "$0")/../ansible/group_vars/all/main.yml" | awk -F'"' '{print $2}')
    echo "export ${var}=\"${val}\""
  done)

GW_A_PUBKEY=$(grep -A2 "GATEWAY A" /etc/wireguard/wg0.conf | grep PublicKey | awk '{print $NF}')
GW_B_PUBKEY=$(grep -A2 "GATEWAY B" /etc/wireguard/wg0.conf | grep PublicKey | awk '{print $NF}')

cat > "$(dirname "$0")/../ansible/output/${ORG_NAME}-wg.conf" << WGEOF
# Zeroth Cloud v3 — WireGuard Client Config
# Org: ${ORG_NAME} | Subnet: ${WG_SUBNET}
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Deliver via Signal or PGP-encrypted email — delete after delivery.

[Interface]
Address    = 10.${ORG_ID}.0.2/24
PrivateKey = ${WG_PRIVATE_KEY}
DNS        = 1.1.1.1, 8.8.8.8

[Peer]
# Site A — Primary gateway
PublicKey           = ${GW_A_PUBKEY}
Endpoint            = ${wg_gateway_a_public_ip}:51820
AllowedIPs          = 10.${ORG_ID}.0.0/24, <REDACTED_IP_2>/24
PersistentKeepalive = 25

[Peer]
# Site B — Failover gateway
PublicKey           = ${GW_B_PUBKEY}
Endpoint            = ${wg_gateway_b_public_ip}:51820
AllowedIPs          = 10.${ORG_ID}.0.0/24, <REDACTED_IP_2>/24
PersistentKeepalive = 25
WGEOF

chmod 600 "$(dirname "$0")/../ansible/output/${ORG_NAME}-wg.conf"
fi
echo ""
echo "[✓] Enrollment complete for $ORG_NAME"
echo "    Client config: ansible/output/${ORG_NAME}-wg.conf"
echo "    Deliver via Signal or PGP-encrypted email — then delete the local copy."
