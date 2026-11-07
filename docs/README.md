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
  Only WireGuard (51820/udp) remains public-facing

ORG DEVICES:
  Each device gets a unique WireGuard keypair and overlay IP
  WireGuard tunnel → Site A gateway (primary) / Site B gateway (failover)
  Each org gets a dedicated Class C /24 (10.<org_id>.0.0/24)
  Wazuh agents connect to HAProxy (<REDACTED_IP_5>) via the tunnel
  HAProxy routes dedicated orgs to their assigned Wazuh manager by source IP
  Inter-org routing is blocked at gateway level (iptables + WireGuard AllowedIPs)

ADMIN ACCESS:
  Platform admins connect via WireGuard (<REDACTED_IP_4>/24 admin subnet)
  Full overlay access to Grafana, TheHive, Cortex, Shuffle, MISP, Prometheus
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
make wireguard    # Step 3 — overlay network + admin routing + UFW overlay SSH
make haproxy      # Step 4 — load balancing + per-org Wazuh routing
make luks         # Step 5 — disk encryption
make opensearch   # Step 6 — log storage
make postgresql   # Step 7 — knowledge base
make wazuh        # Step 8 — security monitoring + alert forwarder
make analytics    # Step 9 — TheHive + MISP + Shuffle + Cortex + Docker-WG forwarding
make llama        # Step 10 — AI analysis
make monitoring   # Step 11 — observability
make dr-test      # Step 12 — disaster recovery validation
```

Or all at once: `make deploy`

### 8. Validate the deployment

```bash
bash scripts/integration_test.sh    # 35 checks across all components
```

---

## Enrolling a New Organization

```bash
make enroll ORG=org01 ID=1 TIER=dedicated SUBNET=<REDACTED_IP_6>/24
```

Zero downtime for existing orgs. Supports up to 255 organizations. See [docs/ONBOARDING.md](docs/ONBOARDING.md).

---

## Onboarding Devices to an Organization

```bash
# Generate a unique WireGuard config for each device
make add-device ORG=org01 DEVICE=laptop-alice
make add-device ORG=org01 DEVICE=desktop-bob

# List all registered devices for an org
make list-devices ORG=org01
```

Each device gets a unique WireGuard keypair and overlay IP. Deliver the config via Signal or PGP-encrypted email. The user installs WireGuard, then installs the Wazuh agent pointing to HAProxy at <REDACTED_IP_5>.

See [docs/ONBOARDING.md](docs/ONBOARDING.md) Part B for per-OS agent installation instructions.

---

## Repository Structure

```
zeroth-cloud/
├── Makefile                            # All operational commands
├── ansible/
│   ├── inventory/
│   │   ├── hosts.yml                   # Server inventory (fill public IPs)
│   │   └── orgs/                       # Enrolled org metadata
│   │       ├── org01.yml               # Org enrollment record
│   │       └── devices/                # Per-org device registries
│   │           └── org01-devices.yml   # Device IP assignments and keys
│   ├── group_vars/all/
│   │   ├── main.yml                    # Non-secret config (fill gateway IPs)
│   │   └── secrets.yml                 # Vault-encrypted secrets (never plaintext)
│   ├── output/                         # Generated device configs (gitignored)
│   ├── playbooks/                      # One playbook per component
│   │   ├── site.yml                    # Master playbook (runs all steps)
│   │   ├── jumpserver.yml              # Step 1
│   │   ├── tang.yml                    # Step 2
│   │   ├── wireguard.yml               # Step 3 — overlay + admin routing + UFW
│   │   ├── haproxy.yml                 # Step 4 — per-org Wazuh routing
│   │   ├── luks.yml                    # Step 5
│   │   ├── opensearch.yml              # Step 6
│   │   ├── postgresql.yml              # Step 7
│   │   ├── wazuh_managers.yml          # Step 8 — managers + alert forwarder
│   │   ├── analytics.yml               # Step 9 — Docker-WG forwarding
│   │   ├── llama.yml                   # Step 10
│   │   ├── monitoring.yml              # Step 11
│   │   ├── dr_test.yml                 # Step 12
│   │   └── enroll_org.yml              # Org enrollment (called by enroll_org.sh)
│   ├── requirements.yml                # Ansible Galaxy collections
│   └── templates/
│       ├── wireguard/
│       │   └── iptables-isolation.sh.j2  # Per-org isolation + HAProxy rules
│       └── haproxy/
│           └── haproxy.cfg.j2          # Per-org source IP routing
├── scripts/
│   ├── setup_controller.sh             # Run first on jumpserver-01
│   ├── bootstrap.sh                    # Run once per server (locks down SSH)
│   ├── bootstrap_all.sh                # Bootstraps every server from controller
│   ├── generate_wg_keys.sh             # Generates WireGuard keypairs for all hosts
│   ├── enroll_org.sh                   # Zero-downtime org enrollment (idempotent)
│   ├── add_device.sh                   # Per-device WireGuard onboarding
│   ├── list_devices.sh                 # List registered devices per org
│   ├── integration_test.sh             # 35-check platform validation
│   └── pxe/ubuntu-autoinstall.yml      # PXE preseed for scale-out
├── docker/
│   └── analytics-stack.yml             # TheHive + Shuffle + MISP + Cortex
├── rules/
│   └── zeroth_custom.xml               # Custom Wazuh detection rules
├── grafana/dashboards/
│   └── org-template.json.j2            # Per-org Grafana dashboard template
└── docs/
    ├── DEPLOYMENT.md                   # Full deployment guide
    ├── ONBOARDING.md                   # Org enrollment + device + admin runbook
    ├── DR_RUNBOOK.md                   # Disaster recovery procedures
    └── NETWORK.md                      # Network architecture
```

---

## Quick Reference — Common Operations

```bash
make deploy                            # Deploy all components
make enroll ORG=org01 ID=1 TIER=dedicated SUBNET=<REDACTED_IP_6>/24  # Enroll org
make add-device ORG=org01 DEVICE=laptop-alice                   # Onboard device
make list-devices ORG=org01                                     # List devices
bash scripts/integration_test.sh                                # Validate platform
make dr-test                                                    # DR validation
```

---

## Security Notes

- **Never commit secrets.** `secrets.yml` must be vault-encrypted before every commit.
- **Never commit WireGuard keys.** Generated key files and device configs are gitignored.
- **Never commit org client configs.** Deliver via Signal or PGP-encrypted email.
- **All SSH** goes through JumpServer after Step 1. Direct SSH is disabled by bootstrap.
- **All service ports** bind to WireGuard overlay IPs after Step 3. Public internet cannot reach OpenSearch, PostgreSQL, Llama, or Grafana directly.
- **LUKS** encrypts all data disks. Tang server provides network-bound key release — stolen hardware cannot decrypt.
- **Per-org isolation** enforced at two layers: WireGuard AllowedIPs and iptables FORWARD DROP on gateways.

---

*Zeroth Cloud v3 | Resilience Technologies Limited | CONFIDENTIAL*
