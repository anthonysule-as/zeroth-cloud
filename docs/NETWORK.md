# Zeroth Cloud v3 — Network Architecture
## Public IP Topology | Colocation | Ubuntu 24.04 LTS

---

## Topology Overview

This deployment uses **public IPs only** — there is no private management VLAN.
Inter-server communication happens over a WireGuard overlay (`<REDACTED_IP_2>/8`) that is
established in Step 3 of deployment. Before WireGuard is up, Ansible reaches
servers via SSH on their public IPs, locked to the controller's IP only.

```
PHASE 1 — Bootstrap (before WireGuard)
┌─────────────────────────────────────────────────┐
│  Ansible controller (jumpserver-01)              │
│  Public IP: A.A.A.1                             │
│                                                  │
│  SSH (port 22, restricted to A.A.A.1 only)      │
│  └──► All servers on their public IPs            │
│       UFW blocks all other inbound traffic       │
└─────────────────────────────────────────────────┘

PHASE 2 — After WireGuard (Step 3 onwards)
┌─────────────────────────────────────────────────┐
│  WireGuard Overlay: <REDACTED_IP_2>/8                  │
│  ┌─────────────────────────────────────────┐    │
│  │ <REDACTED_IP_14>   jumpserver-01 (controller)   │    │
│  │ <REDACTED_IP_5>  haproxy-site-a               │    │
│  │ <REDACTED_IP_15>  haproxy-site-b               │    │
│  │ <REDACTED_IP_8>  opensearch-01                │    │
│  │ <REDACTED_IP_16>  opensearch-02                │    │
│  │ <REDACTED_IP_17>  opensearch-03                │    │
│  │ <REDACTED_IP_10>  analytics-01                 │    │
│  │ <REDACTED_IP_11>  llama-01                     │    │
│  │ <REDACTED_IP_9>  postgresql-01                │    │
│  │ <REDACTED_IP_12>  monitoring-01                │    │
│  │ <REDACTED_IP_3> tang-01                      │    │
│  │ <REDACTED_IP_13>-35  wazuh-mgr-01..06         │    │
│  │ <REDACTED_IP_18>-43  wazuh-shared-01..04      │    │
│  └─────────────────────────────────────────┘    │
│                                                  │
│  All service ports bind to 10.0.0.x ONLY        │
│  UFW blocks service ports from public internet   │
│  Only WireGuard (51820/udp) remains public       │
└─────────────────────────────────────────────────┘
```

---

## IP Allocation

| Network | Purpose |
|---|---|
| `<REDACTED_IP_2>/24` | Infrastructure overlay — all servers |
| `<REDACTED_IP_4>/24` | Admin clients — platform administrators |
| `<REDACTED_IP_6>/24` | Org 1 (dedicated) — per-device IPs |
| `<REDACTED_IP_7>/24` | Org 2 (dedicated) — per-device IPs |
| `10.N.0.0/24` | Org N — supports up to N=255 |
| Public IPs | WireGuard gateway endpoints only |

---

## Per-Device WireGuard Model

Each org device receives a unique WireGuard keypair and overlay IP via
`make add-device ORG=<org> DEVICE=<name>`. Devices are tracked in per-org
registries at `ansible/inventory/orgs/devices/<org>-devices.yml`.

```
Org01 device registry:
  <REDACTED_IP_19>  laptop-alice
  <REDACTED_IP_20>  desktop-bob
  <REDACTED_IP_21>  server-fileserver
  ...
  <REDACTED_IP_22>  (max 253 devices per org)
```

Each device config routes:
- **Gateway A (primary):** `AllowedIPs = 10.<org_id>.0.0/24, <REDACTED_IP_2>/24`
  (org subnet + infrastructure for Wazuh access)
- **Gateway B (failover):** `AllowedIPs = 10.<org_id>.0.0/24`
  (org subnet only — prevents routing conflicts)

---

## Per-Org Network Isolation

Each enrolled organization receives a **dedicated Class C (/24) subnet**.
Isolation is enforced at two independent layers:

**Layer 1 — WireGuard AllowedIPs**
Each device peer entry specifies `AllowedIPs = 10.N.0.X/32`.
WireGuard only routes packets for that device's IP through that peer.

**Layer 2 — iptables FORWARD rules on gateways**

```bash
# Infrastructure and admin traffic — ACCEPT
iptables -A FORWARD -i wg0 -o wg0 -s <REDACTED_IP_2>/24 -d <REDACTED_IP_2>/24 -j ACCEPT
iptables -A FORWARD -i wg0 -o wg0 -s <REDACTED_IP_2>/24 -d <REDACTED_IP_2>/8 -j ACCEPT
iptables -A FORWARD -i wg0 -o wg0 -s <REDACTED_IP_2>/8 -d <REDACTED_IP_2>/24 -j ACCEPT
iptables -A FORWARD -i wg0 -o wg0 -s <REDACTED_IP_4>/24 -d <REDACTED_IP_2>/8 -j ACCEPT
iptables -A FORWARD -i wg0 -o wg0 -s <REDACTED_IP_2>/8 -d <REDACTED_IP_4>/24 -j ACCEPT

# Org devices → HAProxy for Wazuh (1514/1515) — ACCEPT
iptables -A FORWARD -i wg0 -o wg0 -d <REDACTED_IP_5>/32 -p tcp -m multiport --dports 1514,1515 -j ACCEPT
iptables -A FORWARD -i wg0 -o wg0 -s <REDACTED_IP_5>/32 -p tcp -m multiport --sports 1514,1515 -m state --state ESTABLISHED,RELATED -j ACCEPT

# Inter-org lateral movement — DROP (must be last)
iptables -A FORWARD -i wg0 -o wg0 -j DROP
```

Both layers must fail simultaneously for isolation to break.

**What orgs can and cannot reach:**

| From | To | Result |
|---|---|---|
| Org N device | HAProxy (<REDACTED_IP_5>:1514/1515) | Allowed — Wazuh agent traffic |
| Org N device | Any other org's /24 | Dropped |
| Org N device | Infrastructure (<REDACTED_IP_2>/24) except HAProxy Wazuh ports | Dropped |
| Admin client (10.0.1.x) | Any overlay IP | Allowed |
| Infrastructure server | Any overlay IP | Allowed |

---

## Per-Org HAProxy Routing

HAProxy routes each dedicated org's Wazuh traffic to their assigned manager
using source IP ACLs. This is auto-generated from the Ansible inventory.

```
frontend wazuh_events (port 1514):
  <REDACTED_IP_6>/24 → backend wazuh_dedicated_org01 (wazuh-mgr-01)
  <REDACTED_IP_7>/24 → backend wazuh_dedicated_org02 (wazuh-mgr-02)
  <REDACTED_IP_23>/24 → backend wazuh_dedicated_org03 (wazuh-mgr-03)
  ...
  default     → backend wazuh_shared_managers (leastconn pool)

frontend wazuh_registration (port 1515):
  Same ACL routing as above with per-org registration backends.
```

**Data flow for a dedicated org device:**

```
[Org01 Device <REDACTED_IP_19>]
  │  WireGuard tunnel
  ▼
[Gateway A] ──► iptables: org→HAProxy ACCEPT
  │
  ▼
[HAProxy <REDACTED_IP_5>:1514]
  │  ACL: src <REDACTED_IP_6>/24 → wazuh_dedicated_org01
  ▼
[wazuh-mgr-01 <REDACTED_IP_13>:1514]
  │  Alert generated → alerts.json
  ▼
[wazuh-forward.py]
  │  Index: wazuh-alerts-org01-YYYY.MM.DD
  ▼
[OpenSearch <REDACTED_IP_8>-52]
  │
  ▼
[Grafana Dashboard — org01]
```

---

## Admin Client Access

Platform administrators use the `<REDACTED_IP_4>/24` subnet for management access.
The `zeroth-admin-routing` systemd service on both gateways handles forwarding
and NAT for admin traffic.

Admin WireGuard configs use `AllowedIPs = <REDACTED_IP_2>/8` for full overlay access.
Admins can reach all services in their browser:

| Service | URL |
|---|---|
| Grafana | http://<REDACTED_IP_12>:3000 |
| Prometheus | http://<REDACTED_IP_12>:9090 |
| TheHive | http://<REDACTED_IP_10>:9000 |
| Cortex | http://<REDACTED_IP_10>:9001 |
| Shuffle | http://<REDACTED_IP_10>:3001 |
| MISP | http://<REDACTED_IP_10>:8443 |
| OpenSearch | http://<REDACTED_IP_8>:5601 |
| JumpServer | http://<REDACTED_IP_14>:80 |
| HAProxy Stats | http://<REDACTED_IP_5>:8404/stats |

---

## UFW Rules (per server, after WireGuard)

All servers allow SSH from two sources:
- Controller public IP (set during bootstrap)
- Infrastructure overlay: `<REDACTED_IP_2>/24`
- Admin clients: `<REDACTED_IP_4>/24`

Service-specific ports are restricted to the overlay (`<REDACTED_IP_2>/8`).

---

## Public-Facing Ports (after full deployment)

Only these ports are reachable from the public internet:

| Port | Protocol | Service | Allowed From |
|---|---|---|---|
| 22 | TCP | SSH | Controller public IP only |
| 51820 | UDP | WireGuard | Anywhere (org + admin clients) |

**Everything else** (OpenSearch :9200, PostgreSQL :5432, Grafana :3000,
Llama :8000, TheHive :9000, HAProxy :1514/:1515, etc.) is accessible only
on the WireGuard overlay and is blocked by UFW from the public internet.

---

## Dual WireGuard Gateway Architecture

```
Org device wg config (per-device, unique keypair):

[Peer] # Site A — Primary
PublicKey  = <gateway-a-pubkey>
Endpoint   = <site-a-public-ip>:51820
AllowedIPs = 10.<org_id>.0.0/24, <REDACTED_IP_2>/24
PersistentKeepalive = 25

[Peer] # Site B — Failover (org subnet only)
PublicKey  = <gateway-b-pubkey>
Endpoint   = <site-b-public-ip>:51820
AllowedIPs = 10.<org_id>.0.0/24
PersistentKeepalive = 25
```

Gateway B only handles the org subnet (not infrastructure) to prevent
routing conflicts where traffic intended for Gateway A goes to Gateway B.
WireGuard roaming handles failover transparently within the keepalive window
(25 seconds). No client reconfiguration is needed when Site A fails.

---

## Alert Forwarding Pipeline

Each Wazuh manager runs `wazuh-forward.py` as a systemd service. This
lightweight Python script replaces Filebeat (which has a segfault issue
on Ubuntu 24.04 kernels). It tails `/var/ossec/logs/alerts/alerts.json`
and POSTs each alert to OpenSearch with per-org index prefixes.

- Dedicated managers: `WAZUH_INDEX_PREFIX=wazuh-alerts-<org-name>`
- Shared managers: `WAZUH_INDEX_PREFIX=wazuh-alerts-shared`

The forwarder tracks its file position in `/var/lib/filebeat/wazuh-forward.pos`
and resumes from the last position after restart.

---

*Zeroth Cloud v3 | Resilience Technologies Limited | CONFIDENTIAL*
