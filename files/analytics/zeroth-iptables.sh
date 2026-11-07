#!/bin/bash
# Zeroth Cloud — analytics-01 Docker<->WireGuard forwarding + public-block rules.
# Idempotent (check-then-insert): safe to run at every boot without duplicating.
# Called by zeroth-iptables.service (oneshot, After=docker + wg-quick@wg0).
set -u

# --- Docker bridge <-> overlay forwarding (containers reach overlay services) ---
iptables -C FORWARD -s <REDACTED_IP_48>/16 -d <REDACTED_IP_2>/8 -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 1 -s <REDACTED_IP_48>/16 -d <REDACTED_IP_2>/8 -j ACCEPT
iptables -C FORWARD -s <REDACTED_IP_2>/8 -d <REDACTED_IP_48>/16 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 1 -s <REDACTED_IP_2>/8 -d <REDACTED_IP_48>/16 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s <REDACTED_IP_48>/16 -d <REDACTED_IP_2>/8 -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s <REDACTED_IP_48>/16 -d <REDACTED_IP_2>/8 -j MASQUERADE

# --- Public-block: analytics ports reachable from overlay (<REDACTED_IP_2>/8) only ---
# Defense-in-depth behind the compose overlay-bind (services listen on <REDACTED_IP_10>).
for p in 8080 8443 3001 9000 9443 9001 5160; do
  iptables -C DOCKER-USER ! -s <REDACTED_IP_2>/8 -p tcp -m tcp --dport "$p" -j DROP 2>/dev/null \
    || iptables -I DOCKER-USER ! -s <REDACTED_IP_2>/8 -p tcp -m tcp --dport "$p" -j DROP
done
# 8080/3001 DNAT to container port 80, so also block pre-DNAT in the raw table.
for p in 8080 3001; do
  iptables -t raw -C PREROUTING ! -s <REDACTED_IP_2>/8 -p tcp -m tcp --dport "$p" -j DROP 2>/dev/null \
    || iptables -t raw -I PREROUTING ! -s <REDACTED_IP_2>/8 -p tcp -m tcp --dport "$p" -j DROP
done
