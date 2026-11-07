#!/bin/bash
# Zeroth Cloud v3 — Integration Test Suite
# Tests all platform components and org01 enrollment
set -uo pipefail

PASS=0
FAIL=0
WARN=0

pass() { echo "  ✅ $1"; ((PASS++)); }
fail() { echo "  ❌ $1"; ((FAIL++)); }
warn() { echo "  ⚠️  $1"; ((WARN++)); }

check() {
  local desc="$1"; shift
  if eval "$@" > /dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

echo ""
echo "══════════════════════════════════════════════════"
echo "  ZEROTH CLOUD v3 — INTEGRATION TEST"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "══════════════════════════════════════════════════"

# ── 1. OVERLAY NETWORK ──────────────────────────────────────────────────────
echo ""
echo "── 1. WireGuard Overlay Network ─────────────────"
for host in <REDACTED_IP_42>:gateway-a \
            <REDACTED_IP_14>:jumpserver-01 \
            <REDACTED_IP_5>:haproxy-site-a \
            <REDACTED_IP_13>:wazuh-mgr-01 \
            <REDACTED_IP_8>:opensearch-01 \
            <REDACTED_IP_16>:opensearch-02 \
            <REDACTED_IP_17>:opensearch-03 \
            <REDACTED_IP_10>:analytics-01 \
            <REDACTED_IP_11>:llama-01 \
            <REDACTED_IP_9>:postgresql-01 \
            <REDACTED_IP_12>:monitoring-01 \
            <REDACTED_IP_3>:tang-01; do
  IP="${host%%:*}"
  NAME="${host##*:}"
  check "Ping $NAME ($IP)" "ping -c1 -W2 $IP"
done

# ── 2. JUMPSERVER ────────────────────────────────────────────────────────────
echo ""
echo "── 2. JumpServer IAM ────────────────────────────"
check "JumpServer HTTP responds" \
  "curl -sf -o /dev/null -w '%{http_code}' http://localhost/api/health/ | grep -q 200"

JS_TOKEN=$(curl -sf http://localhost/api/v1/authentication/auth/ \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"REDACTED"}' 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)

if [ -n "$JS_TOKEN" ]; then
  pass "JumpServer admin auth"
  check "JumpServer org01 asset group exists" \
    "curl -sf http://localhost/api/v1/assets/nodes/ -H 'Authorization: Bearer $JS_TOKEN' | grep -q org01"
else
  fail "JumpServer admin auth"
fi

# ── 3. WIREGUARD GATEWAYS ───────────────────────────────────────────────────
echo ""
echo "── 3. WireGuard Gateways ────────────────────────"
check "Gateway A WireGuard running" \
  "ssh -i ~/.ssh/zeroth_deploy -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@<REDACTED_IP_29> 'wg show wg0' 2>/dev/null"
check "Gateway A has org01 peer" \
  "ssh -i ~/.ssh/zeroth_deploy -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@<REDACTED_IP_29> 'wg show wg0 | grep -q <REDACTED_IP_6>'"
check "Gateway A iptables infra exceptions" \
  "ssh -i ~/.ssh/zeroth_deploy -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@<REDACTED_IP_29> 'iptables -L FORWARD -n | grep -q <REDACTED_IP_2>/24'"
check "Gateway A admin routing service active" \
  "ssh -i ~/.ssh/zeroth_deploy -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@<REDACTED_IP_29> 'systemctl is-active zeroth-admin-routing'"

# ── 4. OPENSEARCH CLUSTER ───────────────────────────────────────────────────
echo ""
echo "── 4. OpenSearch Cluster ────────────────────────"
OS_HEALTH=$(curl -sf http://<REDACTED_IP_8>:9200/_cluster/health 2>/dev/null)
if echo "$OS_HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('status') in ('green','yellow') else 1)" 2>/dev/null; then
  OS_STATUS=$(echo "$OS_HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null)
  OS_NODES=$(echo "$OS_HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('number_of_nodes',0))" 2>/dev/null)
  if [ "$OS_STATUS" = "green" ]; then pass "Cluster health: $OS_STATUS ($OS_NODES nodes)"; 
  else warn "Cluster health: $OS_STATUS ($OS_NODES nodes)"; fi
else
  fail "OpenSearch cluster unreachable or RED"
fi
check "Org01 index template exists" \
  "curl -sf http://<REDACTED_IP_8>:9200/_index_template/wazuh-org01"

# ── 5. WAZUH MANAGERS ───────────────────────────────────────────────────────
echo ""
echo "── 5. Wazuh Managers ────────────────────────────"
check "Wazuh-mgr-01 running" \
  "ssh -i ~/.ssh/zeroth_deploy -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@<REDACTED_IP_13> 'systemctl is-active wazuh-manager'"
check "Wazuh-mgr-01 org01 agent group exists" \
  "ssh -i ~/.ssh/zeroth_deploy -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@<REDACTED_IP_13> 'test -d /var/ossec/etc/shared/org01'"

# Check Wazuh registration port via HAProxy
HAPROXY_IP=$(grep haproxy_site_a ~/zeroth-cloud/ansible/inventory/hosts.yml 2>/dev/null | head -1)
check "Wazuh registration port (1515) reachable via HAProxy" \
  "timeout 3 bash -c 'echo | nc -w2 <REDACTED_IP_5> 1515'"

# ── 6. ANALYTICS STACK ──────────────────────────────────────────────────────
echo ""
echo "── 6. Analytics Stack (analytics-01) ────────────"
check "TheHive API responds" \
  "curl -sf http://<REDACTED_IP_10>:9000/api/status"
check "Cortex API responds" \
  "curl -sf -u 'admin:CrtClAccessZer0t26' http://<REDACTED_IP_10>:9001/api/status"
check "Shuffle frontend responds" \
  "curl -sf -o /dev/null http://<REDACTED_IP_10>:3001"
check "Docker-WireGuard forwarding active" \
  "ssh -i ~/.ssh/zeroth_deploy -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@<REDACTED_IP_10> 'systemctl is-active zeroth-iptables'"

# ── 7. MONITORING ────────────────────────────────────────────────────────────
echo ""
echo "── 7. Monitoring Stack ──────────────────────────"
check "Prometheus responds" \
  "curl -sf http://<REDACTED_IP_12>:9090/api/v1/status/config"
check "Grafana responds" \
  "curl -sf -o /dev/null http://<REDACTED_IP_12>:3000"

PROM_TARGETS=$(curl -sf http://<REDACTED_IP_12>:9090/api/v1/targets 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); t=d.get('data',{}).get('activeTargets',[]); \
  up=sum(1 for x in t if x.get('health')=='up'); \
  print(f'{up}/{len(t)}')" 2>/dev/null)
if [ -n "$PROM_TARGETS" ]; then
  pass "Prometheus targets: $PROM_TARGETS UP"
else
  warn "Could not check Prometheus targets"
fi

# ── 8. POSTGRESQL ────────────────────────────────────────────────────────────
echo ""
echo "── 8. PostgreSQL ────────────────────────────────"
check "PostgreSQL accepting connections" \
  "ssh -i ~/.ssh/zeroth_deploy -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@<REDACTED_IP_9> 'pg_isready -h <REDACTED_IP_9>'"

# ── 9. TANG (LUKS KEY SERVER) ───────────────────────────────────────────────
echo ""
echo "── 9. Tang LUKS Key Server ──────────────────────"
check "Tang socket active" \
  "ssh -i ~/.ssh/zeroth_deploy -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@<REDACTED_IP_3> 'systemctl is-active tangd.socket'"

# ── 10. ORG01 ENROLLMENT ────────────────────────────────────────────────────
echo ""
echo "── 10. Org01 Enrollment Verification ────────────"
check "Org01 metadata file exists" \
  "test -f ~/zeroth-cloud/ansible/inventory/orgs/org01.yml"
check "Org01 WireGuard client config exists" \
  "test -f ~/zeroth-cloud/ansible/output/org01-wg.conf"

# ── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
echo "  RESULTS: $PASS passed | $FAIL failed | $WARN warnings"
echo "══════════════════════════════════════════════════"

if [ $FAIL -eq 0 ]; then
  echo "  ✅ ALL INTEGRATION TESTS PASSED"
else
  echo "  ❌ $FAIL TEST(S) FAILED — review output above"
fi
echo ""
exit $FAIL
