# Zeroth Cloud v3 — Organization Onboarding Runbook
## Public IP Topology

Organizations are enrolled as they apply. No fixed limit — architecture
supports up to 255 orgs without redesign. Zero downtime to existing orgs.

---

## Pre-Enrollment Checklist

- [ ] Org approved by Resilience Technologies Limited
- [ ] Risk tier determined (dedicated or shared)
- [ ] Next available org ID assigned (check `ansible/inventory/orgs/`)
- [ ] WireGuard /24 subnet confirmed free
- [ ] If `dedicated`: spare server bootstrapped and ready
- [ ] If `shared`: least-loaded shared manager has capacity (< 6 orgs)

---

## Running Enrollment

```bash
# From /root/zeroth-cloud on jumpserver-01
make enroll ORG=org31 ID=31 TIER=shared SUBNET=<REDACTED_IP_1>/24
```

Total time: 3–8 minutes. Zero downtime to existing enrolled orgs.

---

## What Gets Provisioned

| Step | Component | Action | Downtime to existing orgs |
|---|---|---|---|
| 1 | WireGuard gateways | `wg syncconf` — peer appended, no restart | None |
| 2 | JumpServer | Asset group created via API | None |
| 3 | Wazuh | Agent group dir + config deployed | None |
| 4 | OpenSearch | Index template created via API | None |
| 5 | TheHive | Organisation created via API | None |
| 6 | Grafana | Dashboard JSON provisioned, reload | None |

---

## Delivering Credentials to the Org

Deliver all of the following via **Signal** or **PGP-encrypted email**.
Never send via unencrypted email, SMS, or WhatsApp.

### 1. WireGuard client config
Generated at `ansible/output/<org-name>-wg.conf` by the enrollment playbook.

```ini
[Interface]
Address    = 10.<org_id>.0.2/24
PrivateKey = <generated-private-key>
DNS        = 1.1.1.1, 8.8.8.8

[Peer]  # Site A — Primary
PublicKey           = <gateway-a-pubkey>
Endpoint            = <site-a-public-ip>:51820
AllowedIPs          = 10.<org_id>.0.0/24, <REDACTED_IP_2>/24
PersistentKeepalive = 25

[Peer]  # Site B — Automatic failover
PublicKey           = <gateway-b-pubkey>
Endpoint            = <site-b-public-ip>:51820
AllowedIPs          = 10.<org_id>.0.0/24, <REDACTED_IP_2>/24
PersistentKeepalive = 25
```

**Delete the local copy immediately after delivery.**

### 2. Wazuh agent enrollment command
```bash
# Linux / macOS
WAZUH_MANAGER='<haproxy-public-ip>' \
WAZUH_REGISTRATION_PASSWORD='<vault_wazuh_registration_password>' \
WAZUH_AGENT_GROUP='<org-name>' \
bash <wazuh-agent-install-script>

# Windows (PowerShell — run as Administrator)
msiexec /i wazuh-agent.msi \
  WAZUH_MANAGER="<haproxy-public-ip>" \
  WAZUH_AGENT_GROUP="<org-name>"
```

### 3. JumpServer credentials
- URL: `https://<jumpserver-public-ip>`
- Username: provided separately
- MFA: required on first login (TOTP — use Aegis or similar)

---

## Risk Tier Guide

| Indicator | Tier |
|---|---|
| State-level targeting confirmed or suspected | Dedicated |
| High-repression operating context | Dedicated |
| Active incident in past 12 months | Dedicated |
| > 20 endpoints | Dedicated |
| Medium-risk civil society, < 20 endpoints | Shared |
| Helpdesk with < 10 staff | Shared |

### Upgrading Shared → Dedicated
```bash
# 1. Bootstrap a new dedicated server
bash scripts/bootstrap.sh wazuh-mgr-07 wazuh_dedicated <controller-ip>

# 2. Add it to inventory, then re-enroll the org at dedicated tier
make enroll ORG=org07 ID=7 TIER=dedicated SUBNET=<REDACTED_IP_24>/24

# 3. Migrate agents to new manager (Wazuh API)
# 4. Remove org from shared manager's wazuh_org_ids and re-run:
make wazuh
```

---

## Subnet Allocation Register

Update this table as orgs are enrolled.
Each row maps to a file in `ansible/inventory/orgs/`.

| Org ID | Name | Subnet | Tier | Status |
|---|---|---|---|---|
| 1 | org01 | <REDACTED_IP_6>/24 | dedicated | pending |
| 2 | org02 | <REDACTED_IP_7>/24 | dedicated | pending |
| 3 | org03 | <REDACTED_IP_23>/24 | dedicated | pending |
| 4 | org04 | <REDACTED_IP_25>/24 | dedicated | pending |
| 5 | org05 | <REDACTED_IP_26>/24 | dedicated | pending |
| 6 | org06 | <REDACTED_IP_27>/24 | dedicated | pending |
| 7–12 | org07–org12 | 10.7–12.0.0/24 | shared (pool 1) | pending |
| 13–18 | org13–org18 | 10.13–18.0.0/24 | shared (pool 2) | pending |
| 19–24 | org19–org24 | 10.19–24.0.0/24 | shared (pool 3) | pending |
| 25–30 | org25–org30 | 10.25–30.0.0/24 | shared (pool 4) | pending |
| 31+ | org31+ | 10.31+.0.0/24 | TBD at enrollment | — |

---

*Zeroth Cloud v3 | Resilience Technologies Limited | CONFIDENTIAL*
