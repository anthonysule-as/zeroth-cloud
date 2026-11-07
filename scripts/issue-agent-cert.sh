#!/bin/bash
# Zeroth Cloud — issue a Wazuh agent certificate.
#
# Agent enrollment is authenticated by client certificate (security-assessor #7): authd
# rejects any TLS handshake without a cert signed by the Zeroth Wazuh CA. Every
# agent therefore needs one of these before it can enroll.
#
# Usage: bash scripts/issue-agent-cert.sh --name <agent-name> [--days 365]
#
# Outputs to ansible/output/agent-certs/<name>/ :
#   <name>.pem       agent certificate   -> /var/ossec/etc/agent.pem      (0640)
#   <name>-key.pem   agent private key   -> /var/ossec/etc/agent-key.pem  (0600)
#   rootCA.pem       the CA              -> /var/ossec/etc/rootCA.pem     (0640)
#
# The CA private key is required. It lives in files/wazuh/pki/ (gitignored) and
# is mirrored in the vault as vault_wazuh_ca_key_b64. If the local copy is
# missing, restore it first:
#   ansible-vault view ansible/group_vars/all/secrets.yml \
#     --vault-password-file ~/.zeroth_vault_pass \
#     | grep vault_wazuh_ca_key_b64 | cut -d'"' -f2 | base64 -d \
#     > files/wazuh/pki/zeroth-wazuh-ca.key && chmod 600 files/wazuh/pki/zeroth-wazuh-ca.key
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PKI="$REPO/files/wazuh/pki"
NAME=""; DAYS=365

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    *) echo "Usage: $0 --name <agent-name> [--days 365]"; exit 1 ;;
  esac
done
[[ -z "$NAME" ]] && { echo "[x] --name is required"; exit 1; }

# agent names become the cert CN; keep them predictable
NAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')

[[ -f "$PKI/zeroth-wazuh-ca.key" ]]  || { echo "[x] CA key missing at $PKI/zeroth-wazuh-ca.key — restore from vault (see header)"; exit 1; }
[[ -f "$PKI/zeroth-wazuh-ca.cert" ]] || { echo "[x] CA cert missing at $PKI/zeroth-wazuh-ca.cert"; exit 1; }

OUT="$REPO/ansible/output/agent-certs/$NAME"
if [[ -d "$OUT" ]]; then
  echo "[!] $OUT already exists — refusing to overwrite an issued certificate."
  echo "    Remove it explicitly if you intend to re-issue."
  exit 1
fi
mkdir -p "$OUT"; chmod 700 "$OUT"

umask 077
openssl genrsa -out "$OUT/$NAME-key.pem" 4096 2>/dev/null
openssl req -new -key "$OUT/$NAME-key.pem" -out "$OUT/$NAME.csr" \
  -subj "/C=NG/O=Zeroth Cloud/OU=Agent/CN=$NAME" 2>/dev/null
openssl x509 -req -in "$OUT/$NAME.csr" \
  -CA "$PKI/zeroth-wazuh-ca.cert" -CAkey "$PKI/zeroth-wazuh-ca.key" -CAcreateserial \
  -sha256 -days "$DAYS" -out "$OUT/$NAME.pem" 2>/dev/null
rm -f "$OUT/$NAME.csr"
cp "$PKI/zeroth-wazuh-ca.cert" "$OUT/rootCA.pem"
chmod 600 "$OUT/$NAME-key.pem"; chmod 644 "$OUT/$NAME.pem" "$OUT/rootCA.pem"

echo ""
echo "  issued:  $(openssl x509 -in "$OUT/$NAME.pem" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
echo "  expires: $(openssl x509 -in "$OUT/$NAME.pem" -noout -enddate | cut -d= -f2)"
echo -n "  chain:   "; openssl verify -CAfile "$PKI/zeroth-wazuh-ca.cert" "$OUT/$NAME.pem"
echo ""
echo "  files in $OUT :"
ls -1 "$OUT" | sed 's/^/    /'
echo ""
echo "  Deliver over Signal. The key is a credential — it is NOT in git"
echo "  (ansible/output/ is gitignored). Record the expiry: certificates do not"
echo "  auto-renew and enrollment fails silently at the TLS layer when they lapse."
