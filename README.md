# Zeroth Cloud v3 — Infrastructure Repository

**Automated Threat Detection, Response and Intelligence Sharing for Civil Society and Helpdesks in Africa**

> Resilience Technologies Limited | OTF-Funded Pilot | 30+ Beneficiary Organizations | 18-Month Duration
> Colocation Facility | Ubuntu 24.04 LTS | Public IPs | No Provider API

---

## Architecture

Five-layer design with self-monitoring, disaster recovery, IAM, and per-org network isolation.

| Layer | Components |
|---|---|
| Layer 5 — Communications | Signal, PGP Email, Grafana Dashboards |
| Layer 4 — Analysis & Response | TheHive 5, Shuffle SOAR, MISP + Cortex, Llama 3.1 8B |
| Layer 3 — Processing & Storage | OpenSearch 3-Node HA, PostgreSQL + pgvector, LUKS + Tang |
| Layer 2 — Network & Ingestion | Dual WireGuard Gateways, HAProxy + Keepalived, 10 Wazuh Managers |
| Layer 1 — Client Endpoints | Wazuh Agents (Linux/Win/Mac/Android), WireGuard Clients, PiRogue |
| IAM | JumpServer — all machine access gated through bastion, MFA enforced |
| Self-Monitoring | Prometheus, Alertmanager, Grafana |
| Disaster Recovery | Warm Standby (Site B), Ansible Rebuild, 2h RTO / 4h RPO |

## Network Topology — Public IP / Colocation

```
BEFORE WireGuard:
  Ansible controller (jumpserver-01)
    └── SSH on public IPs → all servers (locked to controller IP by bootstrap.sh)

AFTER WireGuard (Step 3):
  All inter-server traffic → WireGuard overlay (<REDACTED_IP_2>/8)
  Service ports bind to overlay IPs — never public IPs
  Only Wazuh agent ports (1514, 1515) remain public-facing via HAProxy

ORG CLIENTS:
  WireGuard tunnel → Site A gateway (primary) / Site B gateway (failover)
  Each org gets a dedicated Class C /24 (10.<org_id>.0.0/24)
  Inter-org routing is blocked at gateway level (iptables + WireGuard AllowedIPs)
```

---

## First-Time Setup

### 1. Set up the Ansible controller (jumpserver-01)

```bash
# From your local machine — run once on jumpserver-01
scp scripts/setup_controller.sh root@<jumpserver-public-ip>:/tmp/
ssh root@<jumpserver-public-ip> bash /tmp/setup_controller.sh
```

### 2. Fill in your server IPs

```bash
# On the controller
cd /root/zeroth-cloud
vim ansible/inventory/hosts.yml          # replace all FILL_ME with public IPs
vim ansible/group_vars/all/main.yml      # fill controller_public_ip and gateway IPs
```

### 3. Generate WireGuard keys for all servers

```bash
make keygen
# Copy output into ansible/group_vars/all/secrets.yml
# Then DELETE the generated key file
```

### 4. Fill and encrypt secrets

```bash
vim ansible/group_vars/all/secrets.yml   # fill all FILL_ME values
ansible-vault encrypt ansible/group_vars/all/secrets.yml
echo "strong-password" > ~/.zeroth_vault_pass && chmod 600 ~/.zeroth_vault_pass
```

### 5. Bootstrap all servers

```bash
# First — paste your deploy public key into scripts/bootstrap.sh (DEPLOY_PUBKEY variable)
cat ~/.ssh/zeroth_deploy.pub             # copy this output

vim scripts/bootstrap.sh                 # paste into DEPLOY_PUBKEY="..."

# Run bootstrap on all servers
bash scripts/bootstrap_all.sh
```

### 6. Validate connectivity

```bash
make preflight    # checks for FILL_ME, encrypted vault, deploy key
make ping         # every host must return pong
```

### 7. Deploy (step by step)

```bash
make jumpserver   # Step 1 — IAM
make tang         # Step 2 — LUKS key server
make wireguard    # Step 3 — overlay network (all inter-server traffic moves here)
make haproxy      # Step 4 — load balancing
make luks         # Step 5 — disk encryption
make opensearch   # Step 6 — log storage
make postgresql   # Step 7 — knowledge base
make wazuh        # Step 8 — security monitoring
make analytics    # Step 9 — TheHive + MISP + Shuffle + Cortex
make llama        # Step 10 — AI analysis
make monitoring   # Step 11 — observability
make dr-test      # Step 12 — disaster recovery validation
```

Or all at once: `make deploy`

---

## Enrolling a New Organization

```bash
make enroll ORG=org31 ID=31 TIER=shared SUBNET=<REDACTED_IP_1>/24
```

Zero downtime for existing orgs. Supports up to 255 organizations. See [docs/ONBOARDING.md](docs/ONBOARDING.md).

---

## Repository Structure

```
zeroth-cloud/
├── Makefile                            # All operational commands
├── ansible/
│   ├── inventory/hosts.yml             # Server inventory (fill public IPs)
│   ├── group_vars/all/
│   │   ├── main.yml                    # Non-secret config (fill gateway IPs)
│   │   └── secrets.yml                 # Vault-encrypted secrets (never plaintext)
│   ├── playbooks/                      # One playbook per component
│   │   ├── site.yml                    # Master playbook (runs all steps)
│   │   ├── jumpserver.yml              # Step 1
│   │   ├── tang.yml                    # Step 2
│   │   ├── wireguard.yml               # Step 3 — critical: overlay network
│   │   ├── haproxy.yml                 # Step 4
│   │   ├── luks.yml                    # Step 5
│   │   ├── opensearch.yml              # Step 6
│   │   ├── postgresql.yml              # Step 7
│   │   ├── wazuh_managers.yml          # Step 8
│   │   ├── analytics.yml               # Step 9
│   │   ├── llama.yml                   # Step 10
│   │   ├── monitoring.yml              # Step 11
│   │   ├── dr_test.yml                 # Step 12
│   │   └── enroll_org.yml              # Org enrollment (called by enroll_org.sh)
│   ├── requirements.yml                # Ansible Galaxy collections
│   └── templates/                      # Jinja2 config templates per service
├── scripts/
│   ├── setup_controller.sh             # Run first on jumpserver-01
│   ├── bootstrap.sh                    # Run once per server (locks down SSH)
│   ├── bootstrap_all.sh                # Bootstraps every server from controller
│   ├── generate_wg_keys.sh             # Generates WireGuard keypairs for all hosts
│   ├── enroll_org.sh                   # Zero-downtime org enrollment
│   └── pxe/ubuntu-autoinstall.yml      # PXE preseed for scale-out
├── docker/
│   └── analytics-stack.yml             # TheHive + Shuffle + MISP + Cortex
├── rules/
│   └── zeroth_custom.xml               # Custom Wazuh detection rules
├── grafana/dashboards/
│   └── org-template.json.j2            # Per-org Grafana dashboard template
└── docs/
    ├── DEPLOYMENT.md                   # Full deployment guide
    ├── ONBOARDING.md                   # Org enrollment runbook
    ├── DR_RUNBOOK.md                   # Disaster recovery procedures
    └── NETWORK.md                      # Network architecture
```

---

## Security Notes

- **Never commit secrets.** `secrets.yml` must be vault-encrypted before every commit.
- **Never commit WireGuard keys.** Generated key files are gitignored.
- **Never commit org client configs.** Deliver via Signal or PGP-encrypted email.
- **All SSH** goes through JumpServer after Step 1. Direct SSH is disabled by bootstrap.
- **All service ports** bind to WireGuard overlay IPs after Step 3. Public internet cannot reach OpenSearch, PostgreSQL, Llama, or Grafana directly.
- **LUKS** encrypts all data disks. Tang server provides network-bound key release — stolen hardware cannot decrypt.

---

*Zeroth Cloud v3 | Resilience Technologies Limited | CONFIDENTIAL*
