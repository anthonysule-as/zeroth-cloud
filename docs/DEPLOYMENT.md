# Zeroth Cloud v3 — Deployment Guide
## Public IP Topology | Colocation | Ubuntu 24.04 LTS | No Provider API

---

## The Deployment Model

```
Physical rack → OS installed → setup_controller.sh (once on jumpserver-01)
  → bootstrap_all.sh (once per server — locks down public SSH exposure)
    → make ping (verify all hosts respond)
      → make deploy (or step by step)
        → bash scripts/integration_test.sh (validate all components)
```

After `bootstrap.sh` runs on a server, SSH is locked to the controller IP only.
After `make wireguard` (Step 3), all inter-server traffic moves to the
WireGuard overlay (`<REDACTED_IP_2>/8`). Public exposure is then minimal.

---

## Prerequisites

### Physical
- All servers racked, powered, Ubuntu 24.04 LTS installed
- SSH root access working on public IPs
- Two DC locations — Site A (primary), Site B (warm standby)

### Before any commands
1. Fill all `FILL_ME` values in `ansible/inventory/hosts.yml`
2. Fill all `FILL_ME` values in `ansible/group_vars/all/main.yml`
3. Run `make keygen` → fill keys into `secrets.yml`
4. Fill all remaining values in `secrets.yml`
5. Encrypt: `ansible-vault encrypt ansible/group_vars/all/secrets.yml`

---

## Step 0 — Set Up the Ansible Controller

Run this **from your local machine**, once, on `jumpserver-01`:

```bash
scp scripts/setup_controller.sh root@<jumpserver-public-ip>:/tmp/
ssh root@<jumpserver-public-ip> bash /tmp/setup_controller.sh
```

This installs git, Ansible, clones the repo, and gives you instructions
for the remaining manual steps (key injection, inventory fill, etc.).

---

## Step 0b — Bootstrap All Servers

After filling inventory and bootstrap.sh (DEPLOY_PUBKEY):

```bash
# From /root/zeroth-cloud on jumpserver-01
bash scripts/bootstrap_all.sh
```

This script:
- Copies `bootstrap.sh` to every server via SSH
- Locks SSH access to the controller IP **immediately** on each server
- Installs base packages, UFW, fail2ban, node_exporter, WireGuard tools
- Marks each server with its role in `/etc/zeroth/`

**Gate:** Every server must complete bootstrap before proceeding.

---

## Step 0c — Verify Connectivity

```bash
make preflight   # checks FILL_ME, vault encryption, deploy key
make ping        # every host must return pong
```

Do not proceed past a failed ping. Fix the failing host first.

---

## Step 1 — JumpServer IAM

```bash
make jumpserver
```

**What it does:** Deploys JumpServer via Docker Compose. Enforces MFA for all
analyst accounts. Records all SSH/RDP sessions. Creates RBAC-scoped asset
groups per org.

**After this step:** All human SSH access to any server must go through
JumpServer. Direct SSH remains available to the controller only for Ansible.

**Verify:**
```bash
curl -s http://<jumpserver-public-ip>/api/health/ | jq .
# Expected: {"status": "ok"}
```

---

## Step 2 — Tang LUKS Key Server

```bash
make tang
```

**What it does:** Deploys Tang on `tang-01` (overlay IP `<REDACTED_IP_3>`).
Tang provides network-bound disk encryption — data nodes unlock LUKS
automatically at boot if they can reach Tang over the WireGuard overlay.

**Critical:** Tang must be deployed and healthy before running `make luks`.
Tang must also be reachable over the overlay before any data node reboots.

**Verify:**
```bash
ansible tang -i ansible/inventory/hosts.yml -m command \
  -a "systemctl is-active tangd.socket" --become
# Expected: active
```

---

## Step 3 — WireGuard Dual Gateway + Overlay

```bash
make wireguard
```

**What it does:**
- Deploys WireGuard on both gateways (Site A + Site B public endpoints)
- Joins every infrastructure server to the `<REDACTED_IP_2>/8` overlay
- Applies per-org iptables isolation rules on gateways (with infrastructure and admin subnet exceptions)
- Deploys `zeroth-admin-routing` systemd service for admin client access (<REDACTED_IP_4>/24)
- Adds UFW rules allowing SSH from infrastructure (<REDACTED_IP_2>/24) and admin (<REDACTED_IP_4>/24) subnets on all servers
- Tightens UFW on all servers: service ports restricted to `<REDACTED_IP_2>/8` only

**This is the network security pivot point.** After this step, service ports
are no longer reachable from the public internet. Only WireGuard (:51820/udp),
SSH from the controller, and Wazuh agent ports (via HAProxy) remain public.

**iptables isolation rule order on gateways:**
1. Infrastructure ↔ infrastructure (<REDACTED_IP_2>/24) — ACCEPT
2. Infrastructure ↔ all overlay — ACCEPT
3. Admin clients (<REDACTED_IP_4>/24) ↔ all overlay — ACCEPT
4. Any → HAProxy (<REDACTED_IP_5>) on ports 1514/1515 — ACCEPT (Wazuh agents)
5. All other wg0→wg0 traffic — DROP (inter-org isolation)

**Verify:**
```bash
# Check overlay connectivity
ansible opensearch-01 -i ansible/inventory/hosts.yml \
  -m command -a "ping -c 3 <REDACTED_IP_3>" --become
# Expected: 3 packets received, 0% packet loss

# Verify WireGuard is up on both gateways
ansible wireguard_gateways -i ansible/inventory/hosts.yml \
  -m command -a "wg show wg0" --become

# Verify admin routing service
ansible wireguard_gateways -i ansible/inventory/hosts.yml \
  -m command -a "systemctl is-active zeroth-admin-routing" --become
```

---

## Step 4 — HAProxy + Keepalived

```bash
make haproxy
```

**What it does:** Deploys HAProxy on Site A (MASTER) and Site B (BACKUP).
Keepalived provides a floating VIP between them. Wazuh agent ports are
load-balanced across the shared manager pool. Dedicated org traffic is
routed to the correct Wazuh manager based on source IP ACLs.

**Per-org routing (auto-generated from inventory):**
- Traffic from <REDACTED_IP_6>/24 (org01) → wazuh-mgr-01
- Traffic from <REDACTED_IP_7>/24 (org02) → wazuh-mgr-02
- Traffic from shared-tier orgs → shared manager pool (leastconn)

Stats and API ports are restricted to the WireGuard overlay.

**Verify:**
```bash
# Check HAProxy is running
ansible haproxy -i ansible/inventory/hosts.yml \
  -m command -a "systemctl is-active haproxy" --become

# Verify config includes per-org routing
ansible haproxy-site-a -i ansible/inventory/hosts.yml \
  -m command -a "grep -c 'dedicated_org' /etc/haproxy/haproxy.cfg" --become
```

---

## Step 5 — LUKS Disk Encryption

```bash
make luks
```

**What it does:** Formats `/dev/sdb` with LUKS2 on all data nodes and binds
the key to Tang. Servers unlock automatically at boot as long as Tang is
reachable on `<REDACTED_IP_3>` (WireGuard overlay).

**Warning:** This destroys all data on `/dev/sdb`. Run only on fresh servers.

**Verify:**
```bash
ansible data_nodes -i ansible/inventory/hosts.yml \
  -m command -a "mountpoint /data" --become
# Expected: /data is a mountpoint (on every data node)
```

---

## Step 6 — OpenSearch 3-Node HA Cluster

```bash
make opensearch
```

**What it does:** Deploys OpenSearch on three nodes. All nodes bind to their
WireGuard overlay IPs. Cluster discovery uses overlay IPs. Per-org index
templates and ILM policy (30-day hot → 90-day warm → delete) are applied.

**Verify:**
```bash
# Check cluster health — must be GREEN before proceeding
curl -s http://<REDACTED_IP_8>:9200/_cluster/health?pretty | jq .status
# Expected: "green"

# Confirm all 3 nodes in cluster
curl -s http://<REDACTED_IP_8>:9200/_cat/nodes?v
```

---

## Step 7 — PostgreSQL + pgvector

```bash
make postgresql
```

**What it does:** Deploys PostgreSQL 16 with pgvector extension. Binds to
overlay IP `<REDACTED_IP_9>`. Creates isolated databases for TheHive, MISP, and
the Llama RAG knowledge base.

**Verify:**
```bash
ansible postgresql -i ansible/inventory/hosts.yml \
  -m command -a "pg_isready -h <REDACTED_IP_9>" --become
# Expected: <REDACTED_IP_9>:5432 - accepting connections
```

---

## Step 8 — Wazuh Managers

```bash
make wazuh
```

**What it does:** Deploys all 10 Wazuh managers (6 dedicated + 4 shared).
Applies custom Zeroth Cloud detection rules. Configures agent group isolation
on shared managers. Deploys the `wazuh-forward.py` alert forwarder to ship
alerts from each manager to OpenSearch with per-org index prefixes.

**Note:** The alert forwarder (`wazuh-forward.py`) replaces Filebeat, which
has a segfault issue on Ubuntu 24.04 kernels. Each dedicated manager forwards
to `wazuh-alerts-<org-name>-*` indices; shared managers forward to
`wazuh-alerts-shared-*`.

**Verify:**
```bash
# Check all managers are running
ansible wazuh_managers -i ansible/inventory/hosts.yml \
  -m command -a "systemctl is-active wazuh-manager" --become
# Expected: active (on all 10 managers)

# Check alert forwarder is running
ansible wazuh_managers -i ansible/inventory/hosts.yml \
  -m command -a "systemctl is-active wazuh-forward" --become
# Expected: active (on all 10 managers)

# Test agent registration port is reachable via HAProxy
nc -zv <REDACTED_IP_5> 1515
```

---

## Step 9 — Analytics Stack

```bash
make analytics
```

**What it does:** Deploys TheHive 5 + Cassandra + Shuffle SOAR + MISP +
MariaDB + Redis + Cortex via Docker Compose on `analytics-01`. Enables
Cortex analyzers (VirusTotal, AbuseIPDB, MalwareBazaar, URLhaus).
Deploys `zeroth-iptables` systemd service for Docker-to-WireGuard overlay
forwarding.

**Verify:**
```bash
# TheHive health
curl -s http://<REDACTED_IP_10>:9000/api/status | jq .versions

# Cortex health
curl -s http://<REDACTED_IP_10>:9001/api/status | jq .

# Shuffle frontend
curl -si http://<REDACTED_IP_10>:3001 | head -1
# Expected: HTTP/1.1 200 OK

# Docker-WireGuard forwarding
ansible analytics -i ansible/inventory/hosts.yml \
  -m command -a "systemctl is-active zeroth-iptables" --become
```

---

## Step 10 — Llama 3.1 8B

```bash
make llama
```

**What it does:** Downloads the AWQ-quantized Llama 3.1 8B model from
HuggingFace and runs it via vLLM. Binds to overlay IP `<REDACTED_IP_11>` only —
never accessible from the public internet.

Note: Model download is ~5GB and may take 10–20 minutes depending on bandwidth.

**Verify:**
```bash
ansible llama -i ansible/inventory/hosts.yml \
  -m command -a "curl -s http://<REDACTED_IP_11>:8000/health" --become
# Expected: {"status":"ok"}
```

---

## Step 11 — Prometheus + Alertmanager + Grafana

```bash
make monitoring
```

**What it does:** Deploys Prometheus (scraping all overlay IPs), Alertmanager
(routing to Signal + PGP email), and Grafana (per-org dashboards + aggregate
infrastructure view). All scrape targets use WireGuard overlay IPs.

**Verify:**
```bash
# Prometheus targets — all should be UP
curl -s http://<REDACTED_IP_12>:9090/api/v1/targets | jq '.data.activeTargets | length'

# Grafana login
curl -si http://<REDACTED_IP_12>:3000 | head -1
```

---

## Step 12 — Disaster Recovery Validation

```bash
make dr-test
```

**What it does:** Creates an OpenSearch snapshot, validates Site B WireGuard
is active, confirms Ansible playbooks are current on the standby host, and
verifies Docker is ready on Site B for a sub-2-hour rebuild.

**Verify:** DR test playbook prints a summary. All checks must pass.
Schedule monthly: add `make dr-test` to cron on the controller.

---

## Step 13 — Integration Test

```bash
bash scripts/integration_test.sh
```

**What it does:** Runs 35 automated checks across all platform components:
overlay connectivity (12 servers), JumpServer auth and org groups, WireGuard
gateway config and iptables rules, OpenSearch cluster health and index templates,
Wazuh manager and agent group, analytics stack (TheHive, Cortex, Shuffle),
monitoring stack (Prometheus, Grafana), PostgreSQL, Tang, and org enrollment
verification.

**All 35 checks must pass before enrolling organizations.**

---

## Post-Deployment: Enroll First Organization

```bash
make enroll ORG=org01 ID=1 TIER=dedicated SUBNET=<REDACTED_IP_6>/24
```

Then onboard devices:

```bash
make add-device ORG=org01 DEVICE=laptop-alice
# Deliver ansible/output/org01-laptop-alice-wg.conf via Signal
# User installs WireGuard + Wazuh agent (see ONBOARDING.md)
```

See [ONBOARDING.md](ONBOARDING.md) for the full enrollment and device onboarding runbook.

---

## Troubleshooting Reference

| Symptom | Likely cause | Fix |
|---|---|---|
| `make ping` fails on a host | Wrong IP in hosts.yml, or UFW blocking | Check IP; verify bootstrap.sh ran |
| WireGuard peers not connecting | Key mismatch in secrets.yml | Regenerate keys with `make keygen` |
| OpenSearch cluster RED | Node can't reach others on overlay | Verify WireGuard is up on all nodes |
| LUKS not unlocking on reboot | Tang unreachable | Check Tang is up; use KVM console |
| HAProxy backend all DOWN | Wazuh managers not on overlay | Verify WireGuard step completed |
| Llama slow / OOM | Insufficient RAM | Confirm dedicated server has ≥64GB |
| Overlay routing broken after enrollment | iptables isolation flushed infra exceptions | Verify isolation script has infra/admin ACCEPT before DROP |
| Org device can't reach Wazuh (1514/1515) | iptables or HAProxy missing org rules | Check HAProxy ACLs and iptables org→HAProxy rules |
| Wazuh alerts not in OpenSearch | wazuh-forward.py not running | `systemctl restart wazuh-forward` on the affected manager |
| Grafana dashboard empty | OpenSearch datasource UID mismatch | Re-import dashboard via Grafana API |
| JumpServer 401 on enrollment | Password mismatch between vault and JumpServer | Reset via `docker exec jms_core python manage.py changepassword admin` |
| Ping from org device times out | ICMP blocked (only TCP 1514/1515 allowed) | Use `Test-NetConnection` or `nc -zv` to test TCP connectivity |
| Device traffic goes to wrong gateway | Overlapping AllowedIPs between peers | Gateway B AllowedIPs should only have org subnet, not <REDACTED_IP_2>/24 |

---

*Zeroth Cloud v3 | Resilience Technologies Limited | CONFIDENTIAL*
