# Zeroth Cloud v3 — Makefile
# PUBLIC IP TOPOLOGY | Colocation | Ubuntu 24.04 LTS
# Run all targets from the repo root on jumpserver-01 (Ansible controller).

INVENTORY  = ansible/inventory/hosts.yml
VAULT_ARGS = --vault-password-file ~/.zeroth_vault_pass
ANSIBLE    = ansible-playbook -i $(INVENTORY) $(VAULT_ARGS)
DEPLOY_KEY = ~/.ssh/zeroth_deploy

.PHONY: help preflight ping keygen deps bootstrap deploy \
        jumpserver tang wireguard haproxy luks opensearch postgresql \
        wazuh analytics llama monitoring dr-test enroll lint clean

help:
	@echo ""
	@echo "  Zeroth Cloud v3 — Make Targets"
	@echo "  PUBLIC IP TOPOLOGY | Ubuntu 24.04 LTS"
	@echo "  ═══════════════════════════════════════════════════════"
	@echo ""
	@echo "  FIRST-TIME SETUP (run in this order):"
	@echo "    make deps          Install Ansible + Galaxy requirements"
	@echo "    make keygen        Generate WireGuard keypairs for all servers"
	@echo "    make preflight     Validate inventory + secrets before first run"
	@echo "    make ping          Test SSH connectivity to all hosts"
	@echo ""
	@echo "  DEPLOYMENT (run in this order after bootstrap_all.sh):"
	@echo "    make jumpserver    Step 1  — JumpServer IAM"
	@echo "    make tang          Step 2  — Tang LUKS key server"
	@echo "    make wireguard     Step 3  — WireGuard overlay + org isolation"
	@echo "    make haproxy       Step 4  — HAProxy + Keepalived"
	@echo "    make luks          Step 5  — LUKS encryption (data nodes)"
	@echo "    make opensearch    Step 6  — OpenSearch 3-node HA"
	@echo "    make postgresql    Step 7  — PostgreSQL + pgvector"
	@echo "    make wazuh         Step 8  — Wazuh managers (10 total)"
	@echo "    make analytics     Step 9  — TheHive + Shuffle + MISP + Cortex"
	@echo "    make llama         Step 10 — Llama 3.1 8B vLLM"
	@echo "    make monitoring    Step 11 — Prometheus + Grafana + Alertmanager"
	@echo "    make dr-test       Step 12 — DR validation"
	@echo "    make deploy        Run ALL steps above in order"
	@echo ""
	@echo "  OPERATIONS:"
	@echo "    make enroll ORG=org31 ID=31 TIER=shared SUBNET=<REDACTED_IP_1>/24"
	@echo "    make dr-test       Monthly DR validation"
	@echo "    make lint          Lint all playbooks"
	@echo "  ═══════════════════════════════════════════════════════"
	@echo ""

# ─── SETUP ───────────────────────────────────────────────────────────────────
deps:
	pip3 install --break-system-packages ansible ansible-lint
	ansible-galaxy install -r ansible/requirements.yml

keygen:
	@bash scripts/generate_wg_keys.sh

preflight:
	@echo "[*] Checking for FILL_ME placeholders in inventory..."
	@if grep -r "FILL_ME" ansible/inventory/hosts.yml ansible/group_vars/all/main.yml 2>/dev/null; then \
		echo "[✗] FILL_ME placeholders found. Fill in all values before proceeding."; \
		exit 1; \
	else \
		echo "[✓] No FILL_ME placeholders in inventory or main.yml"; \
	fi
	@echo "[*] Checking secrets are encrypted..."
	@if head -1 ansible/group_vars/all/secrets.yml | grep -q "ANSIBLE_VAULT"; then \
		echo "[✓] secrets.yml is vault-encrypted"; \
	else \
		echo "[✗] secrets.yml is NOT encrypted."; \
		echo "    Run: ansible-vault encrypt ansible/group_vars/all/secrets.yml"; \
		exit 1; \
	fi
	@echo "[*] Checking deploy key..."
	@test -f $(DEPLOY_KEY) && echo "[✓] Deploy key found" || \
		(echo "[✗] Deploy key not found at $(DEPLOY_KEY)"; exit 1)
	@echo ""
	@echo "[✓] Preflight checks passed — run 'make ping' next"

ping:
	ansible all -i $(INVENTORY) $(VAULT_ARGS) \
		--private-key $(DEPLOY_KEY) \
		-m ping

# ─── DEPLOYMENT STEPS ────────────────────────────────────────────────────────
jumpserver:
	$(ANSIBLE) ansible/playbooks/jumpserver.yml

tang:
	$(ANSIBLE) ansible/playbooks/tang.yml

wireguard:
	$(ANSIBLE) ansible/playbooks/wireguard.yml

haproxy:
	$(ANSIBLE) ansible/playbooks/haproxy.yml

luks:
	$(ANSIBLE) ansible/playbooks/luks.yml

opensearch:
	$(ANSIBLE) ansible/playbooks/opensearch.yml

postgresql:
	$(ANSIBLE) ansible/playbooks/postgresql.yml

wazuh:
	$(ANSIBLE) ansible/playbooks/wazuh_managers.yml

analytics:
	$(ANSIBLE) ansible/playbooks/analytics.yml

llama:
	$(ANSIBLE) ansible/playbooks/llama.yml

monitoring:
	$(ANSIBLE) ansible/playbooks/monitoring.yml

dr-test:
	$(ANSIBLE) ansible/playbooks/dr_test.yml

deploy:
	@echo "[*] Full deployment starting — Steps 1-12"
	$(MAKE) jumpserver
	$(MAKE) tang
	$(MAKE) wireguard
	$(MAKE) haproxy
	$(MAKE) luks
	$(MAKE) opensearch
	$(MAKE) postgresql
	$(MAKE) wazuh
	$(MAKE) analytics
	$(MAKE) llama
	$(MAKE) monitoring
	$(MAKE) dr-test
	@echo "[✓] Full deployment complete"

# ─── OPERATIONS ──────────────────────────────────────────────────────────────
enroll:
	@if [ -z "$(ORG)" ] || [ -z "$(ID)" ] || [ -z "$(TIER)" ] || [ -z "$(SUBNET)" ]; then \
		echo "Usage: make enroll ORG=org31 ID=31 TIER=shared SUBNET=<REDACTED_IP_1>/24"; \
		exit 1; \
	fi
	bash scripts/enroll_org.sh \
		--org-name "$(ORG)" \
		--org-id "$(ID)" \
		--risk-tier "$(TIER)" \
		--wireguard-subnet "$(SUBNET)"

lint:
	ansible-lint ansible/playbooks/*.yml

encrypt-secrets:
	ansible-vault encrypt ansible/group_vars/all/secrets.yml

decrypt-secrets:
	ansible-vault decrypt ansible/group_vars/all/secrets.yml

view-secrets:
	ansible-vault view ansible/group_vars/all/secrets.yml

clean:
	find . -name "*.retry" -delete
	find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	rm -f wg_keys_GENERATED.txt

# ── Device Management ────────────────────────────────────────────────────────
add-device:
	bash scripts/add_device.sh --org $(ORG) --device $(DEVICE)

list-devices:
	@bash scripts/list_devices.sh --org $(ORG) 2>/dev/null || echo "Usage: make list-devices ORG=org01"
