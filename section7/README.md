# Section 7 (Optional) — Wazuh SIEM: Automated Incident Response with Host-Based Detection

**AsciiDoc lab:** [`lab/index.adoc`](lab/index.adoc)

> **This section is optional.** Section 5 covers the same incident response
> workflow using Splunk. This section demonstrates an alternative approach
> using Wazuh as the SIEM/HIDS, with agent-based detection instead of
> centralised log analysis.

## Objective

Demonstrate automated incident response using **Wazuh** — an open-source
host-based intrusion detection system (HIDS). A brute-force SSH attack is
simulated against the app server. The Wazuh agent on the host detects the
attack using built-in rule 5712, forwards the alert to the Wazuh manager,
which fires a webhook to **Event-Driven Ansible** (EDA). EDA automatically
triggers an AAP job template that **revokes the application's database
credentials in Vault**.

## When to Use This Section

- You want to compare **agent-based detection** (Wazuh) vs **centralised log
  analysis** (Splunk from Section 5)
- You are evaluating Wazuh as a SIEM/HIDS for your environment
- You want to explore Wazuh custom rule writing (Exercise 7.7)

## Key Difference from Section 5

| Aspect | Section 5 (Splunk) | Section 7 (Wazuh) |
|--------|-------------------|-------------------|
| Detection method | Centralised saved search on indexed logs | Agent-based rule engine on the host |
| Detection speed | Depends on log shipping interval + search schedule | Near real-time (agent processes events locally) |
| Alert mechanism | Webhook from saved search alert action | Native integration with webhook support |
| Rule language | Splunk SPL (search queries) | Wazuh XML rule definitions |
| False positive tuning | Modify SPL search with `NOT src_ip=...` | Write custom XML rule with `level="0"` |
| Deployment | Splunk UF on each host | Wazuh agent on each host |

## Zero Trust Principles

| Principle | How This Section Demonstrates It |
|-----------|----------------------------------|
| **Assume breach** | Automated response doesn't wait for a human to investigate |
| **Continuous monitoring** | Wazuh SIEM watches every authentication attempt |
| **Automatic remediation** | EDA triggers credential revocation without manual approval |
| **Blast radius containment** | Revoking credentials limits what an attacker can access |
| **Just-in-time recovery** | Fresh credentials are only re-issued after investigation |

## Architecture

```
  ┌────────────┐     ┌──────────────┐     ┌────────────┐     ┌────────────┐
  │  Attacker  │     │  App Server  │     │   Wazuh    │     │    EDA     │
  │            │     │  app.zta.lab │     │  Manager   │     │ Controller │
  │            │     │              │     │            │     │            │
  │  SSH brute │────▶│ /var/log/    │────▶│ Rule 5712  │────▶│  Rulebook  │
  │  force     │     │   secure     │     │ (brute     │     │  matches   │
  │  attempt   │     │              │     │  force)    │     │  event     │
  └────────────┘     └──────────────┘     └─────┬──────┘     └─────┬──────┘
                                                │                   │
                                          Wazuh agent          Webhook POST
                                          detects failed       to EDA
                                          SSH logins
                                                                    │
                                                                    ▼
  ┌────────────┐     ┌──────────────┐     ┌────────────────────────────────┐
  │    App     │     │   Vault      │     │         AAP Controller         │
  │  Service   │     │              │     │                                │
  │            │     │  Revoke DB   │◀────│  Job: "Emergency: Revoke App   │
  │  STOPPED   │◀────│   lease      │     │        Credentials"            │
  │  No DB     │     │              │     │                                │
  │  access    │     │  DROP ROLE   │     │  Triggered by EDA              │
  └────────────┘     └──────────────┘     └────────────────────────────────┘
```

### Timeline

| Time | Event |
|------|-------|
| T+0s | Attacker starts brute-force SSH attempts on app.zta.lab |
| T+10s | Wazuh agent detects 5+ failed logins, sends to manager |
| T+12s | Wazuh manager fires rule 5712 (SSH brute force) |
| T+13s | Wazuh integration POSTs alert JSON to EDA webhook |
| T+14s | EDA rulebook matches the event, triggers AAP job |
| T+20s | AAP runs revocation playbook — Vault lease revoked |
| T+25s | Application stopped, database credentials gone |
| T+25s | **Attack surface eliminated in ~25 seconds** |

---

## Pre-requisites

Before running this section:

1. **Section 2 must be complete** — the application must be deployed with
   active Vault database credentials
2. **Wazuh server** must be running (`deploy-wazuh.yml`)
3. **Wazuh agent** must be installed and active on `app.zta.lab`
   (`deploy-wazuh-agents.yml`)
4. **Event-Driven Ansible controller** (AAP 2.6) must be running, or standalone `ansible-rulebook` for CLI-only demos
5. **Wazuh→EDA integration** must be configured (`setup/configure-wazuh-eda.yml`)

---

## Exercise 7.1 — Create the AAP Job Templates

| Template Name | Playbook | Inventory | Credentials |
|---------------|----------|-----------|-------------|
| Emergency: Revoke App Credentials | `section5/playbooks/revoke-app-credentials.yml` | ZTA Lab Inventory | ZTA Machine Credential |
| Simulate Brute Force (Wazuh) | `section7/playbooks/simulate-bruteforce-wazuh.yml` | ZTA Lab Inventory | ZTA Machine Credential |
| Restore App Credentials | `section5/playbooks/restore-app-credentials.yml` | ZTA Lab Inventory | ZTA Machine Credential |

> **Note:** The revoke and restore playbooks are shared with Section 5.
> Only the simulation and EDA rulebook differ.

---

## Exercise 7.2 — Configure EDA Rulebook

### Option A — Event-Driven Ansible controller (Red Hat Ansible Automation Platform 2.6)

1. In the **Event-Driven Ansible controller**, ensure a **Project** provides this repository (or the rulebook file), and create a **Decision Environment** if needed. See [Using automation decisions](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/using_automation_decisions/) in the AAP 2.6 documentation.
2. Add or sync content so `extensions/eda/rulebooks/wazuh-credential-revoke.yml` is available to activations.
3. Create a **Rulebook Activation**:
   - Name: `Wazuh Brute Force Response`
   - Rulebook: `wazuh-credential-revoke`
   - Decision Environment: your EDA decision environment
   - Restart policy: `On failure`
4. Enable the activation — it starts listening on port 5000

### Option B — Standalone ansible-rulebook

```bash
ssh rhel@control.zta.lab
ansible-rulebook --rulebook /tmp/zta-workshop-aap/extensions/eda/rulebooks/wazuh-credential-revoke.yml \
  -i /tmp/zta-workshop-aap/inventory/hosts.ini \
  --verbose
```

---

## Exercise 7.3 — Verify the Application Is Healthy

```bash
curl -s http://app.zta.lab:8081/health
ssh -p 2022 rhel@central.zta.lab
sudo -u postgres psql -d ztaapp -c "\du" | grep v-root
```

---

## Exercise 7.4 — Launch the Brute-Force Attack

```bash
ansible-playbook section7/playbooks/simulate-bruteforce-wazuh.yml
```

**What happens:**

1. The playbook sends 10 rapid failed SSH login attempts to `app.zta.lab`
2. The Wazuh agent detects the pattern and sends it to the Wazuh manager
3. Wazuh fires **rule 5712** (SSH brute force detected)
4. Wazuh integration POSTs the alert to EDA

---

## Exercise 7.5 — Watch the Automated Response

### Check Wazuh Dashboard

Open `http://wazuh.zta.lab:5601` and look for:
- Alert rule 5712: "SSHD brute force trying to get access to the system"
- Agent: `app.zta.lab`
- Level: 10 (high severity)

### Check Event-Driven Ansible controller

- Event received from Wazuh webhook
- Rule matched: `Revoke credentials on SSH brute-force detection`
- Action: `run_job_template` triggered

### Check the Application

```bash
curl -s http://app.zta.lab:8081/health
# Expected: connection refused or unhealthy

ssh -p 2022 rhel@central.zta.lab
sudo -u postgres psql -d ztaapp -c "\du" | grep v-root
# Expected: no Vault-generated users
```

---

## Exercise 7.6 — Restore the Application

Launch **Restore App Credentials** from AAP.

---

## Exercise 7.7 — Wazuh Alert Tuning & Custom Rule Writing (Hands-On)

### The Scenario

Wazuh is alerting on **legitimate AAP SSH connections**. Write a custom
rule to suppress false positives from the AAP controller.

### Step 1 — Identify the False Positives

Open the Wazuh Dashboard at `http://wazuh.zta.lab:5601`. Filter for
SSH-related alerts — you'll see a mix of legitimate AAP traffic and
the brute-force simulation.

### Step 2 — Examine the Existing Rules

```bash
ssh rhel@central.zta.lab
sudo podman exec -it wazuh-manager bash
grep -A 10 'id="5712"' /var/ossec/ruleset/rules/0095-sshd_rules.xml
```

### Step 3 — Write a Custom Exclusion Rule

```bash
cat >> /var/ossec/etc/rules/local_rules.xml << 'RULES'

<!-- ZTA Workshop: Suppress false positives from AAP controller -->
<group name="local,sshd,zta_tuning">

  <rule id="100030" level="0">
    <if_sid>5712</if_sid>
    <srcip>192.168.1.10</srcip>
    <description>Suppressed: SSH brute-force alert from AAP controller (expected automation traffic)</description>
  </rule>

  <rule id="100031" level="0">
    <if_sid>5763</if_sid>
    <srcip>192.168.1.10</srcip>
    <description>Suppressed: SSH auth failures from AAP controller (expected)</description>
  </rule>

  <rule id="100032" level="0">
    <if_sid>5764</if_sid>
    <srcip>192.168.1.10</srcip>
    <description>Suppressed: SSH multiple auth failures from AAP controller (expected)</description>
  </rule>

</group>
RULES
```

### Step 4 — Validate and Reload

```bash
/var/ossec/bin/wazuh-analysisd -t
exit
sudo podman restart wazuh-manager
```

### Step 5 — Verify the Tuning

- Brute force from AAP IP → alert suppressed
- Brute force from other IPs → alert fires normally

---

## Wazuh Rules Reference

| Rule ID | Description | Level |
|---------|-------------|-------|
| 5712 | SSHD brute force trying to get access to the system | 10 |
| 5763 | SSHD brute force (multiple failed logins from same source) | 10 |
| 5764 | SSHD multiple authentication failures | 10 |

---

## Discussion Points

- Compare detection speed: Wazuh agent-based vs Splunk centralised search
- What are the trade-offs of agent-based HIDS vs centralised log analysis?
- Wazuh rules are XML-based — Splunk searches are SPL. Which is more maintainable?
- Could you run both Wazuh and Splunk for defence in depth?
- What if Wazuh itself is compromised — how do you protect the SIEM?

---

## Validation Checklist

- [ ] Wazuh server and agents are running
- [ ] Wazuh→EDA integration is configured
- [ ] EDA rulebook activation is running (port 5000 listening)
- [ ] Brute-force simulation generates 10 failed SSH attempts
- [ ] Wazuh fires rule 5712 (visible in dashboard)
- [ ] Wazuh integration sends webhook to EDA
- [ ] EDA triggers "Emergency: Revoke App Credentials" in AAP
- [ ] Vault DB lease is revoked
- [ ] Application service is stopped
- [ ] Restore playbook brings the application back with fresh credentials
- [ ] (Bonus) Custom Wazuh rule written to suppress AAP false positives
