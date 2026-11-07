#!/bin/bash
# Zeroth — restrict public ICMP echo-request to jumpserver only.
# Overlay (<REDACTED_IP_2>/8) ping preserved; other ICMP types untouched (PMTU-safe).
# Idempotent; reapplied at boot by zeroth-icmp.service.
set -u
JUMP="<REDACTED_IP_47>"
iptables -C INPUT -s "$JUMP" -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null \
  || iptables -I INPUT 1 -s "$JUMP" -p icmp --icmp-type echo-request -j ACCEPT
iptables -C INPUT -s <REDACTED_IP_2>/8 -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null \
  || iptables -I INPUT 2 -s <REDACTED_IP_2>/8 -p icmp --icmp-type echo-request -j ACCEPT
iptables -C INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null \
  || iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
