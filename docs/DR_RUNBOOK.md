# Zeroth Cloud v3 — Disaster Recovery Runbook
## Public IP Topology | RTO: 2 hours | RPO: 4 hours

---

## Site Definitions

| Label | Role | WireGuard gateway |
|---|---|---|
| Site A | Primary — all services active | wg-gateway-a (public endpoint) |
| Site B | Warm standby — WireGuard always active, services ready to start | wg-gateway-b (public endpoint) |

---

## Automated Safeguards (always active)

- **wg-gateway-b** is always live — org client failover is automatic within 25s
- **Keepalived** promotes Site B HAProxy to MASTER if Site A HAProxy fails
- **OpenSearch snapshots** run daily at 02:00 UTC to `/data/backups/opensearch-snapshots`
- **DNS failover record** (60s TTL) pre-configured pointing to active HAProxy public IP

---

## Scenario 1 — HAProxy Failure (single node)

**Alert:** `HAProxyBackendDown` or `NodeDown` for haproxy-site-a

**Resolution:** Keepalived automatically promotes `haproxy-site-b` to MASTER
and takes the VIP. No manual action required. Update DNS failover record to
point to Site B public IP if VIP is not floating correctly.

**Verify:**
```bash
ansible haproxy-site-b -i ansible/inventory/hosts.yml \
  -m command -a "ip addr show | grep <haproxy_public_ip>" --become
# VIP should now appear on Site B
```

---

## Scenario 2 — WireGuard Gateway A Failure

**Alert:** `WireGuardTunnelDown` for org peers

**Resolution:** Org clients have both gateways configured as peers.
WireGuard roaming switches to Site B gateway automatically — no client
reconfiguration needed. Monitor Prometheus for tunnel recovery.

**Note:** Org device configs route infrastructure traffic (<REDACTED_IP_2>/24) only
through Gateway A. During Gateway A failure, org devices can still reach
their org subnet via Gateway B but cannot reach HAProxy for Wazuh. Monitor
Gateway A recovery closely or reconfigure HAProxy to be reachable via
Gateway B as well.

---

## Scenario 3 — Wazuh Manager Failure

**Alert:** `WazuhManagerSilent` for a specific manager

**For a dedicated manager (one org affected):**
```bash
# 1. SSH via JumpServer to the affected manager
# 2. Restart Wazuh and the alert forwarder
systemctl restart wazuh-manager
systemctl restart wazuh-forward

# 3. Verify alert forwarding resumed
journalctl -u wazuh-forward --since '1 min ago' | tail -5

# 4. If server is unrecoverable, provision a spare and re-run playbook
ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/wazuh_managers.yml \
  --limit wazuh-mgr-NN
```

**For a shared manager (multiple orgs affected):**
```bash
# 1. Restart first
systemctl restart wazuh-manager
systemctl restart wazuh-forward

# 2. If unrecoverable, provision pre-staged spare
ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/wazuh_managers.yml --limit wazuh-shared-NN

# 3. HAProxy reload adds new backend with zero downtime
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/haproxy.yml
```

---

## Scenario 4 — OpenSearch Node Failure

**Alert:** `OpenSearchNodeDown` — cluster turns YELLOW

**With 1 node down (YELLOW — still functional):**
```bash
# Restart OpenSearch on the affected node
ansible opensearch-NN -i ansible/inventory/hosts.yml \
  -m systemd -a "name=opensearch state=restarted" --become

# Monitor cluster health
curl -s http://<REDACTED_IP_8>:9200/_cluster/health?pretty | jq .status
```

**With 2+ nodes down (RED — data unavailable):** Proceed to Scenario 7.

---

## Scenario 5 — Alert Forwarder Failure

**Alert:** `WazuhForwardDown` or alerts not appearing in OpenSearch

**Resolution:**
```bash
# Check forwarder status on affected manager
ssh root@<REDACTED_IP_13> "systemctl is-active wazuh-forward"

# Check for errors
ssh root@<REDACTED_IP_13> "journalctl -u wazuh-forward --since '10 min ago' | tail -10"

# Restart the forwarder
ssh root@<REDACTED_IP_13> "systemctl restart wazuh-forward"

# Verify alerts are flowing (wait 30 seconds)
curl -s "http://<REDACTED_IP_8>:9200/wazuh-alerts-org01-*/_count"
# count should increase after a minute
```

**If forwarder repeatedly crashes:**
```bash
# Check the position file isn't corrupted
ssh root@<REDACTED_IP_13> "cat /var/lib/filebeat/wazuh-forward.pos"

# Reset position to end of file (skip backlog, start fresh)
ssh root@<REDACTED_IP_13> "wc -c /var/ossec/logs/alerts/alerts.json | awk '{print \$1}' > /var/lib/filebeat/wazuh-forward.pos"
ssh root@<REDACTED_IP_13> "systemctl restart wazuh-forward"
```

---

## Scenario 6 — LUKS Volume Fails to Unlock on Reboot

**Alert:** `LUKSDeviceNotMounted` — node unreachable after reboot

**Cause:** Tang server was unreachable during boot, or Tang itself failed.

**Resolution:**
```bash
# 1. Check Tang status on tang-01
ansible tang -i ansible/inventory/hosts.yml \
  -m command -a "systemctl is-active tangd.socket" --become

# 2. If Tang is down, restart it first
ansible tang -i ansible/inventory/hosts.yml \
  -m systemd -a "name=tangd.socket state=started" --become

# 3. For the locked node — access via IPMI/KVM console
#    At the dracut emergency prompt:
curl http://<REDACTED_IP_3>/adv   # test Tang reachability from node
clevis luks unlock -d /dev/sdb -n data_crypt   # manual unlock if Tang OK
# Or enter emergency LUKS passphrase (from password manager)
```

**Prevention:** Never reboot Tang and a data node simultaneously.
Always verify Tang is healthy before any planned data node reboot.

---

## Scenario 7 — Full Site A Failure (complete DR event)

**Estimated recovery time: < 2 hours**

### Step 1 — Update DNS failover record (5 minutes)
Point the DNS failover record to Site B HAProxy public IP.
With 60s TTL, propagation is near-instant.

### Step 2 — Confirm Site B WireGuard is serving org clients (already active)
```bash
ansible wg-gateway-b -i ansible/inventory/hosts.yml \
  -m command -a "wg show wg0 | grep peer" --become
# Should show all enrolled org peers
```

### Step 3 — Start services on Site B standby host (60-90 minutes)
```bash
# From the Ansible controller (jumpserver-01 on Site A)
# If jumpserver-01 is also down, SSH directly to standby-rebuild-01
# using the deploy key from your local machine.

ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/site.yml \
  --limit siteb_standby \
  --skip-tags wireguard    # wg-gateway-b already active
```

### Step 4 — Restore OpenSearch from snapshot (15-30 minutes)
```bash
ansible standby-rebuild-01 -i ansible/inventory/hosts.yml \
  -m command -a "curl -s -X POST \
  'http://<REDACTED_IP_8>:9200/_snapshot/zeroth-snapshots/_all/_restore' \
  -H 'Content-Type: application/json' \
  -d '{\"indices\":\"*\",\"ignore_unavailable\":true}'" --become
```

### Step 5 — Verify alert forwarders on all rebuilt managers
```bash
ansible wazuh_managers -i ansible/inventory/hosts.yml \
  -m command -a "systemctl is-active wazuh-forward" --become
# All should show active

# If any are inactive:
ansible wazuh_managers -i ansible/inventory/hosts.yml \
  -m systemd -a "name=wazuh-forward state=started enabled=true" --become
```

### Step 6 — Validate
```bash
bash scripts/integration_test.sh
make dr-test
```

### Step 7 — Notify analysts
Alertmanager sends Signal notification automatically when services come up.
Manually notify org analysts of the RPO window (max 4 hours of data gap).

---

## Monthly DR Test (non-destructive)

```bash
make dr-test
```

Validates: OpenSearch snapshot success, Site B WireGuard active,
Ansible playbooks current on standby, Docker ready on Site B.
Results logged to Grafana. Run from cron on the controller:
```bash
# Add to root crontab on jumpserver-01
0 3 1 * * cd /root/zeroth-cloud && make dr-test >> /var/log/zeroth-dr-test.log 2>&1
```

---

## Emergency Contacts & Credentials

Store the following in your password manager (NOT in this repo):

- LUKS emergency passphrases for each data node
- IPMI credentials for each server (for KVM console access)
- Ansible vault password
- JumpServer admin credentials
- DNS registrar credentials (for failover record updates)
- Wazuh registration password (for re-enrolling agents)

---

*Zeroth Cloud v3 | Resilience Technologies Limited | CONFIDENTIAL*
