#!/bin/bash
# =============================================================================
# Zeroth Cloud v3 — WireGuard Key Generation Helper
# PUBLIC IP TOPOLOGY
#
# Generates WireGuard keypairs for all servers and prints them in the exact
# format needed to fill ansible/group_vars/all/secrets.yml.
#
# Run this ONCE on the Ansible controller before encrypting secrets.
# Output goes to wg_keys_GENERATED.txt — fill secrets.yml then DELETE the file.
#
# Usage:
#   cd /root/zeroth-cloud
#   bash scripts/generate_wg_keys.sh
# =============================================================================

set -euo pipefail

command -v wg >/dev/null 2>&1 || { echo "[✗] wireguard-tools not installed. Run: apt install wireguard-tools"; exit 1; }

OUTPUT="wg_keys_GENERATED.txt"

echo "# Zeroth Cloud v3 — Generated WireGuard Keys"  > "$OUTPUT"
echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"  >> "$OUTPUT"
echo "# COPY values into secrets.yml then DELETE this file." >> "$OUTPUT"
echo "# NEVER commit this file to git."              >> "$OUTPUT"
echo ""                                              >> "$OUTPUT"

gen_keypair() {
  local name="$1"
  local private_key
  local public_key
  private_key=$(wg genkey)
  public_key=$(echo "$private_key" | wg pubkey)
  echo "vault_wg_host_private_key_${name}: \"${private_key}\""  >> "$OUTPUT"
  echo "vault_wg_host_public_key_${name}:  \"${public_key}\""   >> "$OUTPUT"
  echo ""                                                          >> "$OUTPUT"
  echo "  Generated: $name" >&2
}

echo "# ─── GATEWAY KEYS ───────────────────────────────────────────────────────" >> "$OUTPUT"
gen_keypair "gateway_a"
gen_keypair "gateway_b"

echo "# ─── INFRASTRUCTURE SERVER KEYS ─────────────────────────────────────────" >> "$OUTPUT"
for server in \
  jumpserver_01 \
  haproxy_site_a \
  haproxy_site_b \
  opensearch_01 \
  opensearch_02 \
  opensearch_03 \
  analytics_01 \
  llama_01 \
  postgresql_01 \
  monitoring_01 \
  tang_01 \
  standby_01; do
  gen_keypair "$server"
done

echo "# ─── WAZUH MANAGER KEYS ─────────────────────────────────────────────────" >> "$OUTPUT"
for server in \
  wazuh_mgr_01 wazuh_mgr_02 wazuh_mgr_03 \
  wazuh_mgr_04 wazuh_mgr_05 wazuh_mgr_06 \
  wazuh_shared_01 wazuh_shared_02 \
  wazuh_shared_03 wazuh_shared_04; do
  gen_keypair "$server"
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "[✓] Keys generated: $OUTPUT"
echo ""
echo "  NEXT STEPS:"
echo "  1. Copy the key values from $OUTPUT into secrets.yml"
echo "  2. Encrypt secrets: ansible-vault encrypt ansible/group_vars/all/secrets.yml"
echo "  3. DELETE $OUTPUT immediately: rm $OUTPUT"
echo "  4. Verify $OUTPUT is in .gitignore (it is)"
echo "════════════════════════════════════════════════════════════════"
