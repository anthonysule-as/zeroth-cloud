#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORG_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in --org) ORG_NAME="$2"; shift 2 ;; *) echo "Usage: $0 --org <org-name>"; exit 1 ;; esac
done
[[ -z "$ORG_NAME" ]] && { echo "Usage: $0 --org <org-name>"; exit 1; }
REGISTRY="$REPO_ROOT/ansible/inventory/orgs/devices/${ORG_NAME}-devices.yml"
[[ ! -f "$REGISTRY" ]] && { echo "No devices registered for $ORG_NAME"; exit 0; }
ORG_ID=$(grep "org_id:" "$REGISTRY" | awk '{print $2}')
NEXT_IP=$(grep "next_ip:" "$REGISTRY" | awk '{print $2}')
DEVICE_COUNT=$(grep -c "^  - name:" "$REGISTRY" 2>/dev/null || echo 0)
echo ""
echo "======================================================"
echo "  DEVICES — $ORG_NAME (subnet 10.${ORG_ID}.0.0/24)"
echo "======================================================"
printf "\n  %-25s %-18s %-15s\n" "DEVICE" "OVERLAY IP" "ADDED"
printf "  %-25s %-18s %-15s\n" "-------------------------" "------------------" "---------------"
grep -A4 "^  - name:" "$REGISTRY" | while IFS= read -r line; do
  if echo "$line" | grep -q "name:"; then NAME=$(echo "$line" | awk '{print $3}')
  elif echo "$line" | grep -q "overlay_ip:"; then IP=$(echo "$line" | awk '{print $2}')
  elif echo "$line" | grep -q "added_at:"; then
    DATE=$(echo "$line" | awk '{print $2}' | tr -d '"' | cut -d'T' -f1)
    printf "  %-25s %-18s %-15s\n" "$NAME" "$IP" "$DATE"
  fi
done
echo ""
echo "  Total: $DEVICE_COUNT | Next IP: 10.${ORG_ID}.0.${NEXT_IP} | Remaining: $((254 - NEXT_IP + 1))"
echo ""
