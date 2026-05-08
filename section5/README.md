# Section 5 — Automated Incident Response: Brute Force → Splunk → EDA → Vault Revocation

**AsciiDoc lab:** [`lab/index.adoc`](lab/index.adoc)

> **2-Hour Workshop Delivery Guide**
>
> | Exercise | Status | Est. Time |
> |----------|--------|-----------|
> | 5.1 — Create the AAP Job Templates | **Core** | 3 min |
> | 5.2 — Configure Splunk Saved Search & Alert | **Core** | 5 min |
> | 5.3 — Configure EDA Rulebook | **Core** | 3 min |
> | 5.4 — Verify the Application Is Healthy | **Core** | 2 min |
> | 5.5 — Launch the Brute-Force Attack | **Core** | 3 min |
> | 5.6 — Watch the Automated Response | **Core** | 5 min |
> | 5.7 — Restore the Application | **Core** | 3 min |
> | 5.8 — Splunk Alert Tuning | **Extended** | 10 min |
>
> For a **2-hour workshop**, complete exercises **5.1–5.7** (~25 min).
> Exercise 5.8 (alert tuning) is a bonus exercise if time permits.

## Objective

Demonstrate automated incident response in a Zero Trust architecture. A
brute-force SSH attack is simulated against the app server. **Splunk**
detects the attack via a saved search alert and sends a webhook to
**Event-Driven Ansible** (EDA). EDA automatically triggers an AAP job
template that **revokes the application's database credentials in Vault**
— cutting off data access in seconds, with no human intervention.

## Zero Trust Principles

| Principle | How This Section Demonstrates It |
|-----------|----------------------------------|
| **Assume breach** | Automated response doesn't wait for a human to investigate |
| **Continuous monitoring** | Splunk watches every authentication event forwarded from hosts |
| **Automatic remediation** | EDA triggers credential revocation without manual approval |
| **Blast radius containment** | Revoking credentials limits what an attacker can access |
| **Just-in-time recovery** | Fresh credentials are only re-issued after investigation |

## Architecture

```
  ┌────────────┐     ┌──────────────┐     ┌────────────┐     ┌────────────┐
  │  Attacker  │     │  App Server  │     │   Splunk   │     │    EDA     │
  │            │     │  app.zta.lab │     │  central   │     │ Controller │
  │            │     │              │     │  :8000     │     │            │
  │  SSH brute │────▶│ /var/log/    │────▶│  Saved     │────▶│  Rulebook  │
  │  force     │     │   secure     │     │  search    │     │  matches   │
  │  attempt   │     │              │     │  alert     │     │  event     │
  └────────────┘     └──────────────┘     └─────┬──────┘     └─────┬──────┘
                                                │                   │
                                          Splunk UF             Webhook POST
                                          forwards logs         to EDA
                                          to indexer
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
| T+10s | Splunk Universal Forwarder sends auth logs to indexer |
| T+15s | Splunk saved search fires — detects 5+ failed logins in 60 seconds |
| T+16s | Splunk webhook alert action POSTs to EDA endpoint |
| T+17s | EDA rulebook matches the event, triggers AAP job |
| T+23s | AAP runs revocation playbook — Vault lease revoked |
| T+28s | Application stopped, database credentials gone |
| T+28s | **Attack surface eliminated in ~28 seconds** |

---

## Pre-requisites

Before running this section:

1. **Section 2 must be complete** — the application must be deployed with
   active Vault database credentials
2. **Splunk** must be running on central (`http://central.zta.lab:8000`)
3. **Splunk log shipping** must be configured — `/var/log/secure` from app/db
   containers is forwarded to Splunk (`setup/integrate-splunk.yml`)
4. **Event-Driven Ansible controller** (AAP 2.6) must be running, or standalone `ansible-rulebook` for CLI-only demos
5. **Section 5 EDA setup** must be deployed:
   ```bash
   ansible-playbook -i inventory/hosts.ini setup/configure-aap-project.yml --tags eda,section5,rbac
   ```
   This creates the EDA project, Decision Environment, AAP credential, and
   the **ZTA EDA Event Stream** credential (token from Vault).

---

## Exercise 5.1 — Create the AAP Job Templates

| Template Name | Playbook | Inventory | Credentials |
|---------------|----------|-----------|-------------|
| Emergency: Revoke App Credentials | `section5/playbooks/revoke-app-credentials.yml` | ZTA Lab Inventory | ZTA Machine Credential |
| Simulate Brute Force | `section5/playbooks/simulate-bruteforce.yml` | ZTA Lab Inventory | ZTA Machine Credential |
| Restore App Credentials | `section5/playbooks/restore-app-credentials.yml` | ZTA Lab Inventory | ZTA Machine Credential |

---

## Exercise 5.2 — Configure the Splunk Saved Search & Alert

### Step 1 — Verify logs are arriving in Splunk

Open `http://central.zta.lab:8000` and run this search:

```
index=zta_app sourcetype=syslog "Authentication failure"
```

You should see failed SSH login events from the app/db containers. To also
check VM-level auth logs:

```
index=zta_syslog sourcetype=syslog sshd "Authentication failure"
```

If neither returns results, verify `setup/integrate-splunk.yml` has been run.

### Step 2 — Create the Saved Search

1. Navigate to **Settings → Searches, reports, and alerts → New Alert**
2. Configure:

| Field | Value |
|-------|-------|
| Title | `ZTA: SSH Brute Force Detected` |
| Search | `index=zta_app OR index=zta_syslog sourcetype=syslog "Authentication failure" \| stats count by src_ip, host \| where count >= 5` |
| Time Range | Real-time, 60-second window |
| Alert type | Real-time |
| Trigger condition | Number of results > 0 |

3. Under **Trigger Actions**, click **Add Actions → Webhook**:

| Field | Value |
|-------|-------|
| URL | `http://control.zta.lab:5000/endpoint` |
| Auth Token | `zta-eda-webhook-a1b2c3d4-e5f6-7890` |

   The auth token must match the **ZTA EDA Event Stream** credential in EDA
   (sourced from Vault KV `secret/services/eda-webhook`).

4. Click **Save**

> **ZTA Concept**: Splunk acts as the detection layer. It watches authentication
> logs from all hosts and fires an alert when a brute-force pattern is detected.
> The webhook bridges SIEM to automation — no human in the loop.

### Alternative — Create via Splunk REST API

If you prefer automation over UI clicks:

```bash
curl -k -u admin:ansible123! \
  https://central.zta.lab:8089/servicesNS/admin/search/saved/searches \
  -d name="ZTA: SSH Brute Force Detected" \
  -d search='(index=zta_app OR index=zta_syslog) sourcetype=syslog "Authentication failure" | stats count by src_ip, host | where count >= 5' \
  -d alert_type=always \
  -d alert.severity=4 \
  -d alert.suppress=0 \
  -d dispatch.earliest_time=rt-60s \
  -d dispatch.latest_time=rt \
  -d is_scheduled=1 \
  -d cron_schedule="*/1 * * * *" \
  -d actions=webhook \
  -d 'action.webhook.param.url=http://control.zta.lab:5000/endpoint'
```

---

## Exercise 5.3 — Configure EDA Rulebook

### Option A — Event-Driven Ansible controller (Red Hat Ansible Automation Platform 2.6)

If you ran the prerequisite setup (`configure-aap-project.yml --tags eda,section5`), the EDA project, Decision Environment, and credentials already exist. You only need to create the activation.

1. In the **Event-Driven Ansible controller**, verify the **ZTA Workshop EDA** project is synced and `extensions/eda/rulebooks/splunk-credential-revoke.yml` is available.
2. Create a **Rulebook Activation**:
   - Name: `Splunk Brute Force Response`
   - Rulebook: `splunk-credential-revoke`
   - Decision Environment: `ZTA Decision Environment`
   - Credential: **ZTA EDA Event Stream** (token-based webhook authentication — token sourced from Vault)
   - Restart policy: `On failure`
3. Enable the activation — it starts listening on port 5000

The webhook token for Splunk is `zta-eda-webhook-a1b2c3d4-e5f6-7890` (stored in Vault at `secret/services/eda-webhook`). Use this when configuring the Splunk webhook alert action in Exercise 5.2.

> **Zero Trust note**: The webhook token is managed in Vault, not hardcoded in Splunk or EDA configuration files. To rotate it, run `setup/rotate-eda-webhook-token.yml` — this updates both Vault and the Splunk webhook, then re-run the EDA credential setup to pick up the new token.

### Option B — Standalone ansible-rulebook

```bash
ssh rhel@control.zta.lab
ansible-rulebook --rulebook /tmp/zta-workshop-aap/extensions/eda/rulebooks/splunk-credential-revoke.yml \
  -i /tmp/zta-workshop-aap/inventory/hosts.ini \
  --verbose
```

---

## Exercise 5.4 — Verify the Application Is Healthy

Before the attack, confirm everything is working:

```bash
# Check the app is serving the dashboard
curl -s http://app.zta.lab:8081/health

# Check the database credentials are active
ssh -p 2022 rhel@central.zta.lab
sudo -u postgres psql -d ztaapp -c "\du" | grep v-root
```

You should see a healthy application and an active Vault-generated DB user.

---

## Exercise 5.5 — Launch the Brute-Force Attack

Launch **Simulate Brute Force** from AAP (or run the playbook directly):

```bash
ansible-playbook section5/playbooks/simulate-bruteforce.yml
```

**What happens:**

1. The playbook sends 10 rapid failed SSH login attempts to `app.zta.lab`
2. Each attempt uses the `rhel` user with an incorrect password
3. The failed logins are recorded in `/var/log/secure` on the app server
4. Splunk Universal Forwarder ships the logs to the Splunk indexer
5. Splunk saved search detects 5+ failures and fires the webhook alert

---

## Exercise 5.6 — Watch the Automated Response

After the brute-force simulation completes, observe the chain reaction:

### Check Splunk Dashboard

Open `http://central.zta.lab:8000` and run:

```
(index=zta_app OR index=zta_syslog) sourcetype=syslog "Authentication failure" | stats count by src_ip, host | where count >= 5
```

You should see the brute-force source IP with a high failure count.

Check **Activity → Triggered Alerts** — the `ZTA: SSH Brute Force Detected`
alert should show as recently fired.

### Check Event-Driven Ansible controller

In the Event-Driven Ansible controller UI (AAP 2.6), or `ansible-rulebook` terminal output:
- Event received from Splunk webhook
- Rule matched: `Revoke credentials on SSH brute-force detection`
- Action: `run_job_template` triggered

### Check automation controller

Navigate to **Jobs** — you should see:
- **Emergency: Revoke App Credentials** — triggered by EDA
- Status: Successful
- The job ran without any human clicking "Launch"

### Check the Application

```bash
curl -s http://app.zta.lab:8081/health
# Expected: connection refused or unhealthy — the app is stopped

ssh -p 2022 rhel@central.zta.lab
sudo -u postgres psql -d ztaapp -c "\du" | grep v-root
# Expected: no Vault-generated users — credentials are revoked
```

**The application has been automatically isolated from the database.**

---

## Exercise 5.7 — Restore the Application

After investigating the incident (in a real scenario), restore the
application with fresh credentials:

Launch **Restore App Credentials** from AAP:

```
Application Restored

  New DB User:  v-root-ztaapp-s-xyz789abc
  Health:       HEALTHY
  URL:          http://app.zta.lab:8081

  Fresh credentials issued. The application is back online.
```

Verify:
```bash
curl -s http://app.zta.lab:8081/health
# Expected: healthy again
```

---

---

# Extended Exercises (Longer Formats Only)

## Exercise 5.8 — Splunk Alert Tuning (Hands-On)

### The Problem

After the incident response demo, check the Splunk triggered alerts. You'll
notice the saved search may also fire on **legitimate AAP SSH connections**.
Every time AAP runs a job template, it generates SSH authentication events
that could trigger the brute-force alert.

### Step 1 — Identify the AAP controller's IP

```bash
dig +short control.zta.lab
# 192.168.1.10
```

### Step 2 — Update the Saved Search to Exclude AAP

Edit the saved search in **Settings → Searches, reports, and alerts**:

Change the search to:

```
(index=zta_app OR index=zta_syslog) sourcetype=syslog "Authentication failure" NOT src_ip=192.168.1.10
| stats count by src_ip, host
| where count >= 5
```

The `NOT src_ip=192.168.1.10` excludes the AAP controller from brute-force
detection. Failed logins from AAP are expected (e.g., credential rotation,
connectivity tests).

### Step 3 — Test the Tuning

**Test 1 — Brute force from AAP (should NOT alert):**

Run the brute-force simulation from AAP. Check Splunk triggered alerts —
the alert should NOT fire for source IP 192.168.1.10.

**Test 2 — Brute force from another source (should alert):**

From central, manually trigger failed SSH attempts:

```bash
ssh rhel@central.zta.lab
for i in $(seq 1 10); do
  sshpass -p 'wrongpassword' ssh -o StrictHostKeyChecking=no rhel@app.zta.lab 2>/dev/null
done
```

Check Splunk — the alert SHOULD fire for central's IP (192.168.1.11).

---

## Discussion Points

- How fast was the response from attack detection to credential revocation?
- What if the attacker already had valid credentials — does revoking help?
- Why stop the application instead of just revoking credentials?
- Could EDA trigger additional responses (block IP, isolate network segment)?
- What if Splunk itself is compromised — how do you protect the SIEM?
- How would you add a human approval step for less severe alerts?
- Compare the Splunk webhook approach to alternative SIEM integration — trade-offs?

---

## Splunk Index & Data Reference

The workshop lab ships six Splunk indexes, each fed by a dedicated pipeline
configured in `setup/integrate-splunk.yml`. Understanding what lives where
helps you write effective searches and troubleshoot missing data.

### Index map

| Index | Sourcetype | What it contains | Source pipeline |
|-------|-----------|------------------|----------------|
| `zta_syslog` | `syslog` | Linux VM auth/system logs (sshd, sudo, systemd-logind) | rsyslog → HEC shipper on each VM |
| `zta_app` | `syslog` | App & DB **container** auth/system logs (sshd, postgres, flask) | rsyslog → HEC shipper inside app/db containers |
| `zta_vault` | `hashicorp:vault:audit` | Every Vault API call (login, read, lease create/revoke) | File audit → systemd tail shipper on vault host |
| `zta_opa` | `opa:decision` | OPA policy decisions (allow/deny with full input context) | Podman log tail → HEC shipper on central |
| `zta_network` | `syslog` | Arista cEOS switch syslog (interface changes, config events) | Arista → UDP 514 → HEC |
| `zta_wazuh` | `wazuh:alerts` | Wazuh SIEM alerts (level ≥ 3) — only if Wazuh integration is enabled | Wazuh custom-splunk integration → HEC |

### Splunk connection details

| | Value |
|-|-------|
| Web UI | `http://central.zta.lab:8000` |
| Management API | `https://central.zta.lab:8089` |
| HEC endpoint | `https://central.zta.lab:8088` |
| Login | `admin` / `ansible123!` |

---

### Brute-force detection searches (Section 5 workflow)

```
# All failed SSH logins across app/db containers
index=zta_app sourcetype=syslog "Authentication failure"

# Failed SSH logins across all VMs
index=zta_syslog sourcetype=syslog sshd "Authentication failure"

# Combined — both containers and VMs
(index=zta_app OR index=zta_syslog) sourcetype=syslog "Authentication failure"

# Brute-force detection threshold (the saved search)
(index=zta_app OR index=zta_syslog) sourcetype=syslog "Authentication failure"
| stats count by src_ip, host
| where count >= 5

# Successful SSH logins (compare before/after attack)
(index=zta_app OR index=zta_syslog) sourcetype=syslog "Accepted"

# Key-based logins (AAP automation uses SSH keys)
(index=zta_app OR index=zta_syslog) sourcetype=syslog "Accepted publickey"

# Exclude AAP controller from brute-force search (Exercise 5.8)
(index=zta_app OR index=zta_syslog) sourcetype=syslog "Authentication failure" NOT src_ip=192.168.1.10
| stats count by src_ip, host
| where count >= 5
```

### Vault audit searches (correlate with incident response)

```
# All Vault activity in the last 15 minutes
index=zta_vault sourcetype="hashicorp:vault:audit" earliest=-15m

# Vault database credential generation (Section 2 flow)
index=zta_vault sourcetype="hashicorp:vault:audit" "database/creds"

# Vault lease revocations (fired by the revoke playbook)
index=zta_vault sourcetype="hashicorp:vault:audit" "sys/leases/revoke"

# Vault login events (track who authenticates)
index=zta_vault sourcetype="hashicorp:vault:audit" "auth/userpass/login"
```

### OPA policy decision searches

```
# All OPA decisions
index=zta_opa sourcetype="opa:decision"

# OPA deny decisions only
index=zta_opa sourcetype="opa:decision" "allowed.*false"

# DB access policy decisions (Section 2)
index=zta_opa sourcetype="opa:decision" "db_access"

# AAP gateway policy decisions (Section 3)
index=zta_opa sourcetype="opa:decision" "aap/gateway"
```

### Application and infrastructure searches

```
# Application container logs (health checks, errors)
index=zta_app sourcetype=syslog host="app*"

# Database container logs
index=zta_app sourcetype=syslog host="db*"

# Arista switch events (interface up/down, config changes)
index=zta_network sourcetype=syslog

# All sudo commands across the lab
(index=zta_syslog OR index=zta_app) sourcetype=syslog sudo
```

### Incident response correlation (run after Exercise 5.6)

Use these searches in sequence to reconstruct the full attack → response chain:

```
# 1. The attack — failed SSH logins
index=zta_app sourcetype=syslog "Authentication failure" earliest=-10m
| stats count by src_ip, host
| sort - count

# 2. The detection — this fires the saved search alert
# (check Activity → Triggered Alerts in the Splunk UI)

# 3. Vault revocation — credential lifecycle
index=zta_vault sourcetype="hashicorp:vault:audit" earliest=-10m
| search "sys/leases/revoke" OR "database/creds"
| table _time, request.path, request.operation, auth.display_name

# 4. Full timeline — combine all telemetry
(index=zta_app OR index=zta_vault OR index=zta_opa) earliest=-10m
| eval source_index=index
| table _time, source_index, sourcetype, _raw
| sort _time
```

---

## Validation Checklist

- [ ] Application is healthy before the attack (Section 2 deployed)
- [ ] Splunk is receiving `/var/log/secure` logs from app/db hosts
- [ ] Splunk saved search `ZTA: SSH Brute Force Detected` is created
- [ ] Webhook action points to `http://control.zta.lab:5000/endpoint` with auth token
- [ ] EDA rulebook activation is running with **ZTA EDA Event Stream** credential (port 5000 listening)
- [ ] Brute-force simulation generates 10 failed SSH attempts
- [ ] Splunk alert fires (visible in Activity → Triggered Alerts)
- [ ] Splunk webhook POSTs to EDA
- [ ] EDA triggers "Emergency: Revoke App Credentials" in AAP
- [ ] Vault DB lease is revoked (no `v-root-*` user in PostgreSQL)
- [ ] Application service is stopped
- [ ] `http://app.zta.lab:8081/health` returns unhealthy or connection refused
- [ ] Restore playbook brings the application back with fresh credentials
- [ ] Total time from attack to revocation is under 30 seconds
- [ ] (Bonus) Saved search tuned to exclude AAP controller IP
