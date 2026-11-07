# Zeroth Cloud v3 — Onboarding Runbook
## Organization Enrollment | Device Onboarding | Admin Access

> Resilience Technologies Limited | CONFIDENTIAL

Organizations are enrolled as they apply. No fixed limit — architecture
supports up to 255 orgs without redesign. Zero downtime to existing orgs.

---

## Part A — Organization Enrollment (End-to-End)

This section covers every step required to enroll a new organization into
the Zeroth Cloud platform, from initial approval through to credential delivery.

### A.1 Pre-Enrollment Checklist

Complete every item before running enrollment.

- [ ] Org approved by Resilience Technologies Limited
- [ ] Risk tier determined — see Risk Tier Guide (Section A.7)
- [ ] Next available org ID assigned — check `ansible/inventory/orgs/` for existing IDs
- [ ] WireGuard /24 subnet confirmed free — `10.<org_id>.0.0/24`
- [ ] If `dedicated` tier: dedicated Wazuh manager server bootstrapped and added to inventory
- [ ] If `shared` tier: least-loaded shared manager has capacity (fewer than 6 orgs)
- [ ] Ansible vault password available
- [ ] You are logged in as root on jumpserver-01 (the Ansible controller)

### A.2 Determine Risk Tier

| Indicator | Tier |
|---|---|
| State-level targeting confirmed or suspected | Dedicated |
| High-repression operating context | Dedicated |
| Active incident in past 12 months | Dedicated |
| More than 20 endpoints | Dedicated |
| Medium-risk civil society, fewer than 20 endpoints | Shared |
| Helpdesk with fewer than 10 staff | Shared |

**Dedicated tier** assigns the org its own Wazuh manager server. The mapping is
one-to-one: org01 uses wazuh-mgr-01, org02 uses wazuh-mgr-02, and so on up to
wazuh-mgr-06. Each dedicated Wazuh manager handles only that org's endpoints.

**Shared tier** places the org on a shared Wazuh manager pool. Up to 6 orgs share
each manager. Shared managers are wazuh-shared-01 through wazuh-shared-04.

### A.3 Run Enrollment

From `/root/zeroth-cloud` on jumpserver-01:

```bash
make enroll ORG=<org-name> ID=<org-id> TIER=<dedicated|shared> SUBNET=10.<org-id>.0.0/24
```

**Example — enroll org01 as a dedicated-tier organization:**

```bash
make enroll ORG=org01 ID=1 TIER=dedicated SUBNET=<REDACTED_IP_6>/24
```

**Example — enroll org12 as a shared-tier organization:**

```bash
make enroll ORG=org12 ID=12 TIER=shared SUBNET=<REDACTED_IP_28>/24
```

You will be prompted for the Ansible vault password. Total time: 3–8 minutes.
Zero downtime to existing enrolled orgs.

### A.4 What Gets Provisioned

The enrollment playbook executes six steps automatically:

| Step | Component | What happens | Downtime to existing orgs |
|---|---|---|---|
| 1 | WireGuard gateways | Org peer appended to both gateways via `wg syncconf` — no restart | None |
| 2 | JumpServer | RBAC-scoped asset group `Default/<org-name>` created via API | None |
| 3 | Wazuh | Agent group directory and config deployed to the assigned manager | None |
| 4 | OpenSearch | Per-org index template `wazuh-alerts-<org-name>-*` created | None |
| 5 | TheHive | Organisation created via API (requires paid license for multi-org) | None |
| 6 | Grafana | Per-org dashboard JSON provisioned, Grafana restarted | None |

After enrollment completes, the playbook prints a summary confirming each step
and generates the org's WireGuard client config at `ansible/output/<org-name>-wg.conf`.

### A.5 Post-Enrollment Verification

Run these checks immediately after enrollment completes:

```bash
# 1. Verify org metadata was recorded
cat ansible/inventory/orgs/<org-name>.yml

# 2. Verify WireGuard peer is active on both gateways
ssh -i ~/.ssh/zeroth_deploy root@<REDACTED_IP_29> \
  "wg show wg0 | grep -A2 '10.<org-id>.0.0'"

# 3. Verify Wazuh agent group exists on the assigned manager
#    For dedicated (e.g. org01 → wazuh-mgr-01):
ssh -i ~/.ssh/zeroth_deploy root@<wazuh-mgr-overlay-ip> \
  "ls -la /var/ossec/etc/shared/<org-name>/"

# 4. Verify OpenSearch index template exists
curl -s http://<REDACTED_IP_8>:9200/_index_template/wazuh-<org-name> | python3 -m json.tool | head -5

# 5. Verify Grafana dashboard was provisioned
curl -s http://<REDACTED_IP_12>:3000/api/search?query=<org-name> \
  -u admin:<grafana-password> | python3 -m json.tool

# 6. Verify the client config was generated
cat ansible/output/<org-name>-wg.conf
```

### A.6 Deliver Credentials to the Org

Deliver all of the following via **Signal** or **PGP-encrypted email**.
Never send via unencrypted email, SMS, or WhatsApp.

**Credential 1 — WireGuard client config**

The generated file is at `ansible/output/<org-name>-wg.conf`. It contains
the org's private key, both gateway endpoints, and the org's /24 subnet.
Delete the local copy immediately after delivery.

**Credential 2 — Wazuh agent enrollment details**

Provide the org with:
- Wazuh manager address: `<haproxy-public-ip>` (HAProxy load balances to their assigned manager)
- Wazuh registration password: from `vault_wazuh_registration_password` in secrets.yml
- Agent group name: `<org-name>` (e.g. `org01`)
- Agent installation instructions: see Part B of this document

**Credential 3 — JumpServer access (for org analysts who need case visibility)**

- URL: `http://<jumpserver-public-ip>`
- Username: created by the platform admin (see Part C, Section C.4)
- MFA: required on first login — use Aegis, Google Authenticator, or similar TOTP app

**Delete all local credential files after delivery.** The org's WireGuard
private key must not remain on the controller.

### A.7 Wazuh Manager Assignment Reference

**Dedicated tier** — one manager per org:

| Org ID | Org Name | Wazuh Manager | Manager Overlay IP |
|---|---|---|---|
| 1 | org01 | wazuh-mgr-01 | <REDACTED_IP_13> |
| 2 | org02 | wazuh-mgr-02 | <REDACTED_IP_30> |
| 3 | org03 | wazuh-mgr-03 | <REDACTED_IP_31> |
| 4 | org04 | wazuh-mgr-04 | <REDACTED_IP_32> |
| 5 | org05 | wazuh-mgr-05 | <REDACTED_IP_33> |
| 6 | org06 | wazuh-mgr-06 | <REDACTED_IP_34> |

**Shared tier** — up to 6 orgs per manager:

| Org IDs | Wazuh Manager | Manager Overlay IP |
|---|---|---|
| 7–12 | wazuh-shared-01 | <REDACTED_IP_18> |
| 13–18 | wazuh-shared-02 | <REDACTED_IP_35> |
| 19–24 | wazuh-shared-03 | <REDACTED_IP_36> |
| 25–30 | wazuh-shared-04 | <REDACTED_IP_37> |

### A.8 Subnet Allocation Register

Update this table as orgs are enrolled.
Each row maps to a file in `ansible/inventory/orgs/`.

| Org ID | Name | Subnet | Tier | Manager | Status |
|---|---|---|---|---|---|
| 1 | org01 | <REDACTED_IP_6>/24 | dedicated | wazuh-mgr-01 | enrolled |
| 2 | org02 | <REDACTED_IP_7>/24 | dedicated | wazuh-mgr-02 | pending |
| 3 | org03 | <REDACTED_IP_23>/24 | dedicated | wazuh-mgr-03 | pending |
| 4 | org04 | <REDACTED_IP_25>/24 | dedicated | wazuh-mgr-04 | pending |
| 5 | org05 | <REDACTED_IP_26>/24 | dedicated | wazuh-mgr-05 | pending |
| 6 | org06 | <REDACTED_IP_27>/24 | dedicated | wazuh-mgr-06 | pending |
| 7–12 | org07–org12 | 10.7–12.0.0/24 | shared | wazuh-shared-01 | pending |
| 13–18 | org13–org18 | 10.13–18.0.0/24 | shared | wazuh-shared-02 | pending |
| 19–24 | org19–org24 | 10.19–24.0.0/24 | shared | wazuh-shared-03 | pending |
| 25–30 | org25–org30 | 10.25–30.0.0/24 | shared | wazuh-shared-04 | pending |
| 31+ | org31+ | 10.31+.0.0/24 | TBD at enrollment | TBD | — |

### A.9 Upgrading Shared → Dedicated

If an org's threat profile changes and they need dedicated monitoring:

```bash
# 1. Bootstrap a new dedicated Wazuh manager server
bash scripts/bootstrap.sh wazuh-mgr-07 wazuh_dedicated <controller-ip>

# 2. Add the new server to ansible/inventory/hosts.yml with:
#    wazuh_org_id: <org-id>
#    wazuh_org_name: <org-name>
#    wg_overlay_ip: <REDACTED_IP_38> (next available)

# 3. Deploy WireGuard and Wazuh on the new server
make wireguard
ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/wazuh_managers.yml --limit wazuh-mgr-07

# 4. Re-enroll the org at dedicated tier
make enroll ORG=org07 ID=7 TIER=dedicated SUBNET=<REDACTED_IP_24>/24

# 5. Migrate existing agents from the shared manager to the new dedicated manager
#    On each endpoint, update the Wazuh agent config to point to the new manager
#    Then restart the agent. Alternatively, use the Wazuh API to re-register.

# 6. Remove the org from the shared manager's config and re-run:
make wazuh
```

---

## Part B — Device Onboarding (Wazuh Agent Enrollment)

This section provides end-to-end instructions for installing Wazuh agents
on org endpoints so they send logs to their assigned Wazuh manager via HAProxy.

### B.1 Before You Start

Gather the following from the platform admin or from the credentials delivered
during org enrollment:

- **Wazuh manager address:** `<haproxy-public-ip>` — all agents connect through HAProxy, which routes to the correct manager
- **Wazuh registration password:** provided by the platform admin
- **Agent group name:** the org name (e.g. `org01`) — this ensures agents join the correct group and send logs to the correct index
- **Wazuh agent version:** use the latest 4.x release from https://documentation.wazuh.com

### B.2 Linux (Ubuntu / Debian)

Run as root or with sudo on the endpoint:

```bash
# 1. Import the Wazuh GPG key
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring \
  --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && \
  chmod 644 /usr/share/keyrings/wazuh.gpg

# 2. Add the Wazuh repository
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ \
  stable main" | tee /etc/apt/sources.list.d/wazuh.list

# 3. Install the Wazuh agent
apt-get update
WAZUH_MANAGER='<haproxy-public-ip>' \
WAZUH_REGISTRATION_PASSWORD='<registration-password>' \
WAZUH_AGENT_GROUP='<org-name>' \
apt-get install -y wazuh-agent=4.14.7-1

# 3b. VERIFY AES on the agent<->manager stream (security-assessor #12).
#     Agents >= 4.x ship with <crypto_method>aes</crypto_method> already set.
#     Older agents default to Blowfish. This is a <client> option and CANNOT
#     be pushed from the manager via shared agent.conf, so confirm it locally.
#     Expect exactly one line: <crypto_method>aes</crypto_method>
grep -c 'crypto_method>aes' /var/ossec/etc/ossec.conf
# If the count is 0, add it inside <client> (do NOT add a second copy):
#   sed -i 's|</client>|  <crypto_method>aes</crypto_method>\n  </client>|' /var/ossec/etc/ossec.conf

# 4. Start the agent
systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent

# 5. Verify the agent is connected
grep "Connected to" /var/ossec/logs/ossec.log | tail -1
# Expected: "Connected to the server (<haproxy-public-ip>:1514/tcp)"
```

### B.3 Linux (RHEL / CentOS / Fedora)

Run as root on the endpoint:

```bash
# 1. Import the Wazuh GPG key
rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH

# 2. Add the Wazuh repository
cat > /etc/yum.repos.d/wazuh.repo << 'EOF'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=Wazuh repository
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF

# 3. Install the Wazuh agent
WAZUH_MANAGER='<haproxy-public-ip>' \
WAZUH_REGISTRATION_PASSWORD='<registration-password>' \
WAZUH_AGENT_GROUP='<org-name>' \
yum install -y wazuh-agent-4.14.7-1

# 3b. VERIFY AES on the agent<->manager stream (security-assessor #12).
#     Expect 1. If 0, add it inside <client> — see the Debian section.
grep -c 'crypto_method>aes' /var/ossec/etc/ossec.conf

# 4. Start the agent
systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent

# 5. Verify
grep "Connected to" /var/ossec/logs/ossec.log | tail -1
```

### B.4 Windows

Run PowerShell as Administrator on the endpoint:

```powershell
# 1. Download the Wazuh agent MSI (use the latest 4.x version)
Invoke-WebRequest -Uri "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.14.7-1.msi" `
  -OutFile "$env:TEMP\wazuh-agent.msi"

# 2. Install with manager address and agent group
msiexec.exe /i "$env:TEMP\wazuh-agent.msi" /q `
  WAZUH_MANAGER="<haproxy-public-ip>" `
  WAZUH_REGISTRATION_PASSWORD="<registration-password>" `
  WAZUH_AGENT_GROUP="<org-name>"

# 2b. VERIFY AES on the agent<->manager stream (security-assessor #12).
#     Expect a match. 4.14.7 ships with this already set.
Select-String -Path "C:\Program Files (x86)\ossec-agent\ossec.conf" -Pattern 'crypto_method>aes'

# 3. Start the agent service
net start WazuhSvc

# 4. Verify — check the agent log
Get-Content "C:\Program Files (x86)\ossec-agent\ossec.log" -Tail 5 |
  Select-String "Connected"
# Expected: "Connected to the server"
```

### B.5 macOS

Run in Terminal with sudo:

```bash
# 1. Download the Wazuh agent PKG (use the latest 4.x version)
curl -so /tmp/wazuh-agent.pkg \
  "https://packages.wazuh.com/4.x/macos/wazuh-agent-4.14.7-1.pkg"

# 2. Set environment variables for registration
export WAZUH_MANAGER='<haproxy-public-ip>'
export WAZUH_REGISTRATION_PASSWORD='<registration-password>'
export WAZUH_AGENT_GROUP='<org-name>'

# 3. Install the agent
sudo installer -pkg /tmp/wazuh-agent.pkg -target /

# 3b. VERIFY AES on the agent<->manager stream (security-assessor #12). Expect 1.
grep -c 'crypto_method>aes' /Library/Ossec/etc/ossec.conf

# 4. Start the agent
sudo /Library/Ossec/bin/wazuh-control start

# 5. Verify
sudo grep "Connected to" /Library/Ossec/logs/ossec.log | tail -1
```

### B.6 Android (via PiRogue)

For mobile monitoring, Wazuh agents are not installed directly on Android
devices. Instead, network traffic is routed through a PiRogue device which
captures and forwards telemetry.

```
[Android device] → WiFi → [PiRogue] → WireGuard tunnel → [Wazuh manager]
```

**PiRogue setup:**

1. Flash PiRogue OS onto a Raspberry Pi
2. Configure the PiRogue's WireGuard client with the org's tunnel config
3. Configure the PiRogue to forward Suricata alerts to the org's Wazuh manager
4. Connect Android devices to the PiRogue's WiFi access point

Refer to the PiRogue documentation for detailed setup instructions.

### B.7 Verifying Agent Registration on the Platform

After installing agents, verify from the Ansible controller that they
are registered and reporting:

```bash
# Check agent list on the org's Wazuh manager
# For dedicated org01 (wazuh-mgr-01 at <REDACTED_IP_13>):
ssh -i ~/.ssh/zeroth_deploy root@<wazuh-mgr-public-ip> \
  "/var/ossec/bin/agent_control -l"
# Each agent should show "Active"

# Verify logs are arriving in OpenSearch
curl -s "http://<REDACTED_IP_8>:9200/wazuh-alerts-<org-name>-*/_count" | python3 -m json.tool
# count should be greater than 0 after a few minutes
```

### B.8 Troubleshooting Agent Connectivity

| Symptom | Likely Cause | Fix |
|---|---|---|
| Agent cannot connect to manager | Firewall blocking ports 1514/1515 | Ensure endpoint firewall allows outbound TCP to HAProxy public IP on ports 1514 and 1515 |
| Registration fails with "Invalid password" | Wrong registration password | Verify `WAZUH_REGISTRATION_PASSWORD` matches `vault_wazuh_registration_password` in secrets.yml |
| Agent connected but no alerts in OpenSearch | Wrong agent group | Verify agent is in the correct group: `/var/ossec/bin/agent_control -i <agent-id>` — group should be `<org-name>` |
| Agent shows "Disconnected" after initial connection | HAProxy backend unhealthy | Check HAProxy stats: `curl -s http://<REDACTED_IP_5>:8404/stats` and verify the org's Wazuh manager backend is UP |
| Windows agent fails to install | Insufficient privileges | Run PowerShell as Administrator |
| macOS agent blocked by Gatekeeper | Package not signed | Open System Settings → Privacy & Security → Allow the Wazuh installer |

---

## Part C — Platform Admin Onboarding

This section covers how to grant a new administrator or SOC analyst
access to the Zeroth Cloud management plane.

### C.1 Admin Access Architecture

Platform admins access the infrastructure through two channels:

1. **JumpServer** (http://<jumpserver-public-ip>) — web-based bastion host for SSH/RDP sessions to any managed server. All sessions are recorded. MFA is enforced.

2. **WireGuard admin tunnel** (<REDACTED_IP_4>/24 subnet) — direct overlay network access to all service UIs (Grafana, TheHive, OpenSearch, Cortex, Shuffle, Prometheus). Admins connecting via WireGuard can reach any overlay IP directly in their browser.

### C.2 Create Admin WireGuard Tunnel

Each admin gets a WireGuard tunnel config for their workstation. This
gives them direct browser access to all overlay services.

**Step 1 — Generate a WireGuard keypair for the admin**

```bash
# On the controller (jumpserver-01)
wg genkey | tee /tmp/admin-privkey | wg pubkey > /tmp/admin-pubkey
echo "Private key: $(cat /tmp/admin-privkey)"
echo "Public key:  $(cat /tmp/admin-pubkey)"
```

**Step 2 — Add the admin as a peer on both gateways**

```bash
ADMIN_PUBKEY=$(cat /tmp/admin-pubkey)
ADMIN_OVERLAY_IP="10.0.1.X"   # Assign next available IP in <REDACTED_IP_4>/24

# Add to gateway A
ssh -i ~/.ssh/zeroth_deploy root@<REDACTED_IP_29> \
  "wg set wg0 peer $ADMIN_PUBKEY allowed-ips ${ADMIN_OVERLAY_IP}/32"

# Add to gateway B
ssh -i ~/.ssh/zeroth_deploy root@<REDACTED_IP_39> \
  "wg set wg0 peer $ADMIN_PUBKEY allowed-ips ${ADMIN_OVERLAY_IP}/32"
```

**Step 3 — Add the admin to the Ansible inventory for persistence**

Edit `ansible/group_vars/all/vars.yml` and add the admin to `admin_wg_clients`:

```yaml
admin_wg_clients:
  - name: "analyst-alice"
    public_key: "<admin-public-key>"
    overlay_ip: "<REDACTED_IP_40>"
  - name: "analyst-bob"
    public_key: "<admin-public-key>"
    overlay_ip: "<REDACTED_IP_41>"
```

Run `make wireguard` to persist the changes. This ensures the admin peer
survives gateway restarts and WireGuard reconfigurations.

**Step 4 — Create the admin's WireGuard client config**

```ini
[Interface]
Address    = <admin-overlay-ip>/32
PrivateKey = <admin-private-key>
DNS        = 1.1.1.1, 8.8.8.8

[Peer]
# Site A — Primary gateway
PublicKey           = <gateway-a-public-key>
Endpoint            = <site-a-public-ip>:51820
AllowedIPs          = <REDACTED_IP_2>/8
PersistentKeepalive = 25

[Peer]
# Site B — Failover gateway
PublicKey           = <gateway-b-public-key>
Endpoint            = <site-b-public-ip>:51820
AllowedIPs          = <REDACTED_IP_15>/32
PersistentKeepalive = 25
```

Deliver this config to the admin via Signal or PGP-encrypted email.
Delete `/tmp/admin-privkey` and `/tmp/admin-pubkey` immediately after.

**Step 5 — Verify admin connectivity**

After the admin installs WireGuard and activates the tunnel on their workstation:

```bash
# Admin runs on their own machine:
ping <REDACTED_IP_42>       # gateway — should respond
ping <REDACTED_IP_12>      # monitoring-01 (Grafana) — should respond
```

### C.3 Services Available via Admin WireGuard Tunnel

Once connected, admins can access these services directly in their browser:

| Service | URL | Purpose |
|---|---|---|
| Grafana | http://<REDACTED_IP_12>:3000 | Dashboards, per-org views, infrastructure monitoring |
| Prometheus | http://<REDACTED_IP_12>:9090 | Metrics, target health, alerting rules |
| TheHive | http://<REDACTED_IP_10>:9000 | Case management, incident response |
| Cortex | http://<REDACTED_IP_10>:9001 | Automated analysis (VirusTotal, AbuseIPDB, etc.) |
| Shuffle SOAR | http://<REDACTED_IP_10>:3001 | Workflow automation, playbook execution |
| MISP | http://<REDACTED_IP_10>:8443 | Threat intelligence sharing, IOC management |
| OpenSearch Dashboards | http://<REDACTED_IP_8>:5601 | Log search, per-org index exploration |
| JumpServer | http://<REDACTED_IP_14>:80 | Bastion host (also accessible via public IP) |

### C.4 Create Admin Account in JumpServer

Every admin needs a JumpServer account for audited SSH/RDP access to servers.

**Step 1 — Log into JumpServer**

Open `http://<jumpserver-public-ip>` in your browser and log in with the
platform admin credentials (admin / vault_jumpserver_admin_password).

**Step 2 — Create the user**

1. Navigate to **User Management → User List → Create**
2. Fill in the user details:
   - **Name:** Full name of the admin
   - **Username:** Lowercase, no spaces (e.g. `alice`)
   - **Email:** Admin's email address
   - **Role:** `OrgAdmin` for full access, `User` for analyst-level access
   - **MFA:** Set to **Force Enable** — this is mandatory for all accounts
3. Click **Submit**

**Step 3 — Assign asset permissions**

1. Navigate to **Permissions → Asset Permissions → Create**
2. Create a permission entry:
   - **Name:** e.g. `alice-infrastructure-access`
   - **User:** Select the user created above
   - **Assets:** Select the asset group(s) the admin should access
   - **System User:** Select the appropriate system accounts
   - **Actions:** Connect, Upload, Download as appropriate
3. Click **Submit**

**Step 4 — Send first-login instructions to the admin**

Deliver the following via Signal or PGP-encrypted email:

```
JumpServer Access
─────────────────
URL:      http://<jumpserver-public-ip>
Username: <username>
Password: <temporary-password>

On first login:
1. You will be prompted to change your password.
2. You will be required to set up MFA (TOTP).
   Use Aegis, Google Authenticator, or similar.
3. Scan the QR code with your TOTP app.
4. Enter the 6-digit code to complete setup.

After MFA setup, you can:
- SSH to servers via the web terminal
- RDP to Windows hosts via the web interface
- All sessions are recorded for audit
```

### C.5 Set Up Admin Access to TheHive

Admins who need case management access require a TheHive account.

**Step 1 — Create the user in TheHive**

```bash
# From the controller, using the TheHive API
curl -s http://<REDACTED_IP_10>:9000/api/v1/user \
  -H "Authorization: Bearer <thehive-admin-api-key>" \
  -H "Content-Type: application/json" \
  -X POST \
  -d '{
    "login": "<REDACTED_EMAIL_1>",
    "name": "Alice",
    "profile": "analyst",
    "password": "<temporary-password>"
  }' | python3 -m json.tool
```

**Step 2 — Send the admin their TheHive credentials**

```
TheHive Access
──────────────
URL:      http://<REDACTED_IP_10>:9000 (requires WireGuard tunnel)
Username: <REDACTED_EMAIL_1>
Password: <temporary-password>

Change your password on first login via:
  User Menu → Settings → Change Password
```

### C.6 Set Up Admin Access to Grafana

Admins who need dashboard access require a Grafana account.

```bash
# Create a Grafana user via the API
curl -s http://<REDACTED_IP_12>:3000/api/admin/users \
  -u admin:<grafana-admin-password> \
  -H "Content-Type: application/json" \
  -X POST \
  -d '{
    "name": "Alice",
    "login": "alice",
    "password": "<temporary-password>",
    "OrgId": 1
  }' | python3 -m json.tool
```

### C.7 Revoking Admin Access

When an admin leaves the team or no longer needs access:

```bash
# 1. Remove their WireGuard peer from both gateways
ssh -i ~/.ssh/zeroth_deploy root@<REDACTED_IP_29> \
  "wg set wg0 peer <admin-public-key> remove"
ssh -i ~/.ssh/zeroth_deploy root@<REDACTED_IP_39> \
  "wg set wg0 peer <admin-public-key> remove"

# 2. Remove from admin_wg_clients in vars.yml and re-run
#    Edit ansible/group_vars/all/vars.yml — remove the entry
make wireguard

# 3. Disable their JumpServer account
#    JumpServer UI → User Management → User List → find user → Disable

# 4. Disable their TheHive account
curl -s http://<REDACTED_IP_10>:9000/api/v1/user/<user-login>/force \
  -H "Authorization: Bearer <thehive-admin-api-key>" \
  -H "Content-Type: application/json" \
  -X PATCH \
  -d '{"status": "Locked"}'

# 5. Disable their Grafana account
curl -s http://<REDACTED_IP_12>:3000/api/admin/users/<user-id> \
  -u admin:<grafana-admin-password> \
  -H "Content-Type: application/json" \
  -X PUT \
  -d '{"isDisabled": true}'
```

### C.8 Admin Onboarding Checklist

Use this checklist for each new admin:

- [ ] WireGuard keypair generated
- [ ] Peer added to both gateways and persisted in `admin_wg_clients`
- [ ] `make wireguard` run to persist the peer config
- [ ] WireGuard client config delivered via Signal or PGP email
- [ ] Admin can ping overlay gateway (<REDACTED_IP_42>) from their workstation
- [ ] JumpServer account created with MFA enforced
- [ ] JumpServer credentials delivered via Signal or PGP email
- [ ] Admin has completed MFA setup on first login
- [ ] TheHive account created (if needed for incident response)
- [ ] Grafana account created (if needed for dashboard access)
- [ ] Admin added to Signal group for operational notifications
- [ ] Key files deleted from controller (`/tmp/admin-privkey`, `/tmp/admin-pubkey`)

---

## Quick Reference — Common Operations

**Enroll a new org:**
```bash
make enroll ORG=org05 ID=5 TIER=dedicated SUBNET=<REDACTED_IP_26>/24
```

**Check enrolled orgs:**
```bash
ls ansible/inventory/orgs/
```

**Check active WireGuard peers on gateway:**
```bash
ssh -i ~/.ssh/zeroth_deploy root@<REDACTED_IP_29> "wg show wg0"
```

**Check Wazuh agent status on a manager:**
```bash
ssh -i ~/.ssh/zeroth_deploy root@<manager-ip> "/var/ossec/bin/agent_control -l"
```

**Check OpenSearch cluster health:**
```bash
curl -s http://<REDACTED_IP_8>:9200/_cluster/health?pretty
```

**Check if an org's logs are arriving:**
```bash
curl -s "http://<REDACTED_IP_8>:9200/wazuh-alerts-<org-name>-*/_count"
```
**Check if an org's logs are arriving:**
```bash
scripts/integration_test.sh
```

---

*Zeroth Cloud v3 | Resilience Technologies Limited | CONFIDENTIAL*
