#!/bin/bash
# Zeroth Cloud — JumpServer web port lockdown (security-assessor #13).
# Docker publishes 8443 via DNAT, bypassing ufw; needs DOCKER-USER + raw.
set -u

OVERLAY="<REDACTED_IP_2>/8"

# NOTE: ICMP echo scoping lives in /etc/ufw/before.rules (ufw-before-input),
# NOT in INPUT. Rules appended to INPUT sit below the ufw jump and never match.
# See ansible/playbooks/icmp-fix.yml.

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^jms_web$'; then
  iptables -C DOCKER-USER ! -s "${OVERLAY}" -p tcp --dport 8443 -j DROP 2>/dev/null \
    || iptables -I DOCKER-USER 1 ! -s "${OVERLAY}" -p tcp --dport 8443 -j DROP
  iptables -t raw -C PREROUTING ! -s "${OVERLAY}" -p tcp --dport 8443 -j DROP 2>/dev/null \
    || iptables -t raw -I PREROUTING 1 ! -s "${OVERLAY}" -p tcp --dport 8443 -j DROP
fi

exit 0
