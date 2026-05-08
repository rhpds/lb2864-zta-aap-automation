---
marp: true
theme: default
paginate: true
size: 16:9
header: "Zero Trust Architecture Workshop"
footer: "Red Hat Ansible Automation Platform 2.6"
style: |
  section {
    font-family: 'Red Hat Display', 'Overpass', sans-serif;
  }
  section.title {
    text-align: center;
    display: flex;
    flex-direction: column;
    justify-content: center;
  }
  section.title h1 {
    font-size: 2.4em;
  }
  section.section-divider {
    background: #1a1a2e;
    color: #eee;
    text-align: center;
    display: flex;
    flex-direction: column;
    justify-content: center;
  }
  section.section-divider h1 {
    font-size: 2em;
  }
  section.extended {
    border-top: 4px solid #999;
  }
  table { font-size: 0.75em; }
  blockquote { font-size: 0.85em; border-left: 4px solid #cc0000; }
---

<!-- _class: title -->
<!-- _paginate: false -->
<!-- _header: "" -->
<!-- _footer: "" -->

# Zero Trust Architecture
## with Ansible Automation Platform

**Hands-on workshop — AAP 2.6**

---

# Agenda

| # | Section | Theme |
|---|---------|-------|
| 1 | Verify ZTA Components & AAP Integration | **Wire** |
| 2 | Deploy Application with Short-Lived Credentials | **Deploy** |
| 3 | AAP Policy as Code: Platform-Gated Patching | **Enforce** |
| 4 | SPIFFE-Verified Network VLAN Management | **Prove Identity** |
| 5 | Automated Incident Response (Splunk → EDA → Vault) | **Respond** |
| 6 | SSH Lockdown & Break-Glass | **Harden** _(Extended)_ |
| 7 | Wazuh EDA Path | **Alternate SIEM** _(Extended)_ |

Sections 1–5 are the **core track**. Sections 6–7 are the **Extended Security Workshop**.

<!--
Speaker notes:
Walk through the agenda. Emphasise that sections build on each other — complete them in order.
Sections 6 and 7 are optional and time-permitting. Check with your audience whether those are in scope.
-->

---

# What is Zero Trust?

**The old model:** a firewall at the edge. Inside = trusted. Outside = not.

**The problem:** that fails when attackers breach the perimeter, insiders go rogue, or workloads span clouds and containers where "inside" has no meaning.

**Zero Trust flips it:** every request — from a person, an app, or an automation job — must prove it should be allowed. Every time. No exceptions.

> *"Zero trust assumes there is no implicit trust granted to assets or user accounts based solely on their physical or network location or based on asset ownership."*
> — **NIST SP 800-207**

Replace the perimeter with: **strong identity** + **explicit policy** + **continuous verification**

<!--
Speaker notes:
Start with the relatable scenario — most people's networks still look like the old model.
The NIST quote grounds this in a standards body, not vendor marketing.
The three replacement pillars (identity, policy, verification) will map directly to lab tools.
-->

---

# Core Principles

| Principle | In plain terms |
|-----------|----------------|
| **Never trust, always verify** | Check every request, every time — no free passes |
| **Least privilege** | Only what you need, only for as long as you need it |
| **Assume breach** | Design for when (not if) someone gets in — contain and respond fast |
| **Deny by default** | Start from "no" — explicit policy match required for "yes" |
| **Identity-driven access** | Decide based on *who*, not *where* |
| **Micro-segmentation** | Carve the network into small zones — no lateral free-roaming |
| **Continuous monitoring** | Keep watching, detect anomalies, respond automatically |
| **Workload identity** | Services and automation jobs prove their identity too, not just people |

<!--
Speaker notes:
Don't read every row — highlight 3-4 that will surprise the audience.
"Assume breach" and "workload identity" are often the ones that change how people think.
Every principle maps to a specific exercise they'll do today.
-->

---

# The NIST Model — Mapped to This Lab

| Component | What it does | In this lab |
|-----------|-------------|-------------|
| **Policy Decision Point (PDP)** | Evaluates requests against policy — allow or deny | **OPA** — Rego policies using identity, state, and context |
| **Policy Enforcement Point (PEP)** | Sits in the path and enforces the decision | **AAP** — queries OPA before launching jobs (Policy as Code) |
| **Policy Information Point (PIP)** | Feeds context to the PDP | **IdM** (identity), **NetBox** (state), **Vault** (creds), **Splunk/Wazuh** (threats) |

Every section in this workshop touches all three components.

<!--
Speaker notes:
This is the NIST 800-207 framework. Three boxes — decision, enforcement, information.
OPA is the brain (PDP), AAP is the muscle (PEP), and everything else feeds context (PIP).
Students will see this pattern repeat in every exercise.
-->

---

# Architecture Overview

```
                            ┌──────────────────┐
                            │   AAP Controller  │
                            │  control.zta.lab  │
                            │   EDA Controller  │
                            └────────┬─────────┘
                                     │
          ┌──────────┬──────────┬────┼──────────┐
          │          │          │    │           │
     ┌────▼───┐ ┌───▼───┐ ┌───▼──┐ │      ┌───▼────────────────────────┐
     │ Vault  │ │NetBox │ │Gitea │ │      │  Central VM               │
     │  .zta  │ │ .zta  │ │.zta  │ │      │  IdM, OPA, SPIRE Server  │
     │  .lab  │ │ .lab  │ │.lab  │ │      │  Splunk, Wazuh, Keycloak │
     └────────┘ └───────┘ └──────┘ │      │  cEOS switches (x3)      │
                                    │      │  App + DB containers      │
         192.168.1.0/24 mgmt       │      └────────────────────────────┘
```

**Management plane:** `192.168.1.0/24` — all VMs and external access
**Data plane:** `10.20.0.0/24` (app tier) and `10.30.0.0/24` (data tier) — routed via Arista cEOS

<!--
Speaker notes:
Point out the two networks. Management is how everything talks to each other.
Data plane is internal — app and DB containers behind a three-switch cEOS fabric.
Students will configure ACLs on the switches to control cross-tier traffic.
-->

---

# Components at a Glance

| Component | ZTA Role | Lab Function |
|-----------|----------|-------------|
| **IdM (FreeIPA)** | Identity provider | Users, groups, LDAP, CA trust chain |
| **HashiCorp Vault** | Secrets + SSH CA | Short-lived DB creds, SSH certificates |
| **OPA** | Policy decision point | Rego policies for launch auth, DB access, network changes |
| **SPIFFE / SPIRE** | Workload identity | SVIDs proving AAP is legitimate |
| **NetBox** | Source of truth | Dynamic inventory, maintenance-window state |
| **Arista cEOS** | Network segmentation | 3-switch fabric, ACLs between app and data tiers |
| **Splunk** | Security monitoring | Log aggregation, brute-force detection, EDA webhooks |
| **Wazuh** | Security monitoring (opt.) | Alternative SIEM for Section 7 |
| **Gitea** | Git server | Version-controlled playbooks, GitOps |
| **AAP Controller** | Policy enforcement point | Job templates, credentials, RBAC, Policy as Code |
| **EDA Controller** | Event-driven response | SIEM webhooks → rulebooks → remediation jobs |
| **PostgreSQL + Flask** | Target workloads | The app you'll deploy and defend |

<!--
Speaker notes:
Don't read every row. Highlight that this is a real, integrated stack — not isolated demos.
Every tool has a specific ZTA role. By the end, students will have touched all of them.
-->

---

# Why Ansible Automation Platform?

Every ZTA operational change needs the **same identity checks, policy gates, and audit trail**.

AAP is the **Policy Enforcement Point** that ties it all together:

- **One platform** for RHEL, Arista switches, PostgreSQL, and containers
- **Policy as Code** — OPA decides before the job even starts
- **No passwords on disk** — credentials resolved from Vault at job time
- **Identity-aware** — IdM LDAP → AAP teams → OPA policy
- **Event-driven** — EDA responds to SIEM alerts in seconds
- **Full audit trail** — who launched it, what policy allowed it, what changed

<!--
Speaker notes:
This is the "why are we using AAP for this" slide. The short answer: it's the only platform
that manages RHEL, network, databases, and containers from one place — all under policy control.
Without AAP, you'd need separate integrations for every tool in the ZTA stack.
-->

---

# Two Enforcement Rings

**Outer ring — Platform level (AAP Policy as Code)**
- AAP sends the full job context to OPA at launch time
- Wrong user, wrong team, wrong template → job **never starts**

**Inner ring — Playbook level (in-task OPA queries)**
- Individual tasks query OPA mid-run for fine-grained checks
- SPIFFE SVID validation, VLAN range checks, data classification

```
  User clicks "Launch"
        │
        ▼
  ┌─── OPA (outer ring) ───┐     ┌─── OPA (inner ring) ───┐
  │  Team? Template? User? │ ──▶ │  SVID? Group? Range?    │ ──▶ Execute
  │  allowed: true/false   │     │  allowed: true/false    │
  └────────────────────────┘     └─────────────────────────┘
```

<!--
Speaker notes:
This is the key architectural concept. Two policy checkpoints, not one.
The outer ring catches the obvious violations (wrong person for this job).
The inner ring catches the subtle ones (right person, but invalid VLAN ID or missing workload identity).
Sections 3 and 4 will exercise both rings explicitly.
-->

---

# Secrets — No Credentials at Rest

**Machine credentials:** AAP resolves passwords from Vault **at job time** via credential lookups. The AAP database stores Vault paths — not usable passwords.

**SSH access:** Vault acts as a **certificate authority**. Short-lived signed certificates instead of static keys. Hosts trust the Vault CA — no authorised_keys files to manage.

**Database credentials:** Vault issues **dynamic PostgreSQL users** scoped to one database with a 5-minute TTL. They expire automatically.

If the controller is compromised → attacker finds Vault paths, not passwords.

<!--
Speaker notes:
This is one of the biggest mindset shifts for ops teams.
No more password vaults exported as CSVs. No more SSH keys that sit on disk for years.
Everything is dynamic, short-lived, and automatically revoked.
Section 2 will make this very concrete when DB creds expire mid-exercise.
-->

---

<!-- _class: section-divider -->

# Section 1
## Verify ZTA Components & AAP Integration

*Wire AAP into the Zero Trust fabric*

---

# Section 1 — What You'll Do

**Goal:** Confirm that every integration in the ZTA stack works before building on it.

- Connect AAP to **IdM** (LDAP authentication), **Vault** (secret lookups), **OPA** (policy queries), **NetBox** (dynamic inventory), and **Gitea** (project sync)
- Create and verify **four job templates** with the right credentials attached
- Configure **LDAP authentication** so IdM users can log into AAP

**ZTA principles:** Secrets management, identity integration, policy connectivity, source-of-truth inventory

<!--
Speaker notes:
This is the foundation. Nothing in sections 2-7 works if these integrations aren't solid.
The four verification templates are: Verify ZTA Services, Test Vault Integration,
Test Vault SSH Certificates, Test OPA Policy.
LDAP config is done manually in the AAP UI — it's an Exercise 1.2 hands-on step.
-->

---

# Section 1 — Exercise Flow

```
  ┌──────────┐   ┌───────────┐   ┌─────────┐   ┌──────────┐   ┌───────────┐
  │ Configure│   │ Configure │   │ Create  │   │ Run      │   │ Configure │
  │ AAP      │──▶│ Vault     │──▶│ job     │──▶│ verify   │──▶│ LDAP      │
  │ creds    │   │ lookups   │   │ templates│  │ templates│   │ auth      │
  └──────────┘   └───────────┘   └─────────┘   └──────────┘   └───────────┘
                                                    │
                                              All green? ──▶ Section 2
```

**Key credentials:**
- **ZTA Machine Credential** — on all four templates
- **ZTA Arista Credential** — only on "Verify ZTA Services"
- **ZTA Vault Credential** — backs lookups only, **never on job templates**

<!--
Speaker notes:
Walk through the flow left to right. Credential setup comes first because everything else depends on it.
Emphasise the Vault credential rule: it's a lookup source, never attached directly to a job.
If Verify ZTA Services runs green, the stack is healthy.
-->

---

<!-- _class: section-divider -->

# Section 2
## Deploy Application with Short-Lived Credentials

*Experience deny-then-allow in a real pipeline*

---

# Section 2 — What You'll Do

**Goal:** Deploy the Global Telemetry Platform through a full ZTA pipeline — and get denied first.

- Attempt to deploy as **the wrong user** — OPA blocks before Vault is contacted
- Switch to the correct user and deploy with **5-minute database credentials**
- Watch Arista switches **open an ACL** for the app's traffic
- Observe credential **expiry** — the DB user disappears after 5 minutes

**ZTA principles:** Deny by default, least privilege, short-lived credentials, micro-segmentation

<!--
Speaker notes:
This is where it gets real. The "wrong user" step is intentional — students experience the deny path first.
The 5-minute TTL is aggressive on purpose. If the workflow takes too long, creds expire mid-deploy.
That forces the habit of running the full workflow every time, not reusing stale creds.
-->

---

# Section 2 — Exercise Flow

```
  Wrong user                      Right user
  ──────────                      ──────────
  Launch template                 Launch template
       │                               │
       ▼                               ▼
  OPA: check db_access            OPA: check db_access
       │                               │
       ▼                               ▼
  ✗ DENIED (not in                ✓ ALLOWED
    app-deployers)                     │
                                       ▼
                                  Vault: generate DB creds
                                  (user: v-appdev-ztaapp-xxxx, TTL: 5m)
                                       │
                                       ▼
                                  Arista: open ACL (10.20.0.10 → 10.30.0.10:5432)
                                       │
                                       ▼
                                  Deploy app ──▶ Health check ✓
                                       │
                                  ⏱ 5 minutes later: DB user auto-revoked
```

<!--
Speaker notes:
Draw attention to the left path — the denial happens BEFORE Vault is even contacted.
OPA is the gatekeeper; Vault never wastes a credential on an unauthorised user.
The ACL step shows micro-segmentation — even with creds, you need a network path.
The 5-minute expiry at the bottom is the "least privilege" principle in action.
-->

---

<!-- _class: section-divider -->

# Section 3
## AAP Policy as Code: Platform-Gated Patching

*See OPA block a job before it starts*

---

# Section 3 — What You'll Do

**Goal:** Experience the **outer ring** — AAP Policy as Code blocking a launch at the platform level.

- Attempt to run a **security patch** — OPA denies it (wrong team)
- Inspect the Rego policy in `aap_gateway.rego` to understand why
- **Fix team membership** in IdM
- Re-launch and successfully apply the hardening patch (login banner, SSH config, password policy, audit logging)
- **Section 3B:** Break/fix exercise with `data_classification.rego`

**ZTA principles:** Platform enforcement, policy as code, role-based launch control

<!--
Speaker notes:
This is where Policy as Code clicks for students.
The key insight: the job didn't fail partway through — it never started at all.
AAP sent the context to OPA, OPA said no, and that was it.
Section 3B is a bonus Rego exercise — students edit policy and see the impact immediately.
-->

---

# Section 3 — Exercise Flow

```
  ztauser launches "Patch Server"
       │
       ▼
  AAP ──▶ OPA (outer ring): aap/gateway/decision
       │
       ├─ input.created_by.teams = ["Infrastructure"]
       ├─ template pattern: "Patch"
       ├─ required teams: Infrastructure OR Security
       │
       ▼
  ✓ ALLOWED ──▶ Run patch playbook
       │
       ├── Set login banner
       ├── Harden SSH config
       ├── Enforce password policy
       └── Enable audit logging
```

**The Rego policy decides — AAP enforces.** OPA never touches the infrastructure; AAP never questions the decision.

<!--
Speaker notes:
Show the clean separation: OPA is the brain, AAP is the muscle.
The template pattern matching in the Rego policy maps template names to required teams.
If you're not in Infrastructure or Security, you can't patch. Period.
The actual patch tasks are standard Ansible — the ZTA magic is in the launch gate.
-->

---

<!-- _class: section-divider -->

# Section 4
## SPIFFE-Verified Network VLAN Management

*Prove your workload's identity — not just yours*

---

# Section 4 — What You'll Do

**Goal:** Pass through **two OPA policy rings** to create a VLAN — proving both user and workload identity.

- **Outer ring:** AAP gateway checks your team membership
- **Inner ring:** Playbook queries OPA with SPIFFE SVID, IdM group, VLAN ID, and action
- Both gates must pass before the switch config changes and **NetBox gets updated**
- Test edge cases: invalid VLAN IDs, missing SVIDs, wrong group membership

**ZTA principles:** Workload identity, dual policy rings, defence in depth, CMDB as source of truth

<!--
Speaker notes:
This is the most layered exercise. Two OPA checks, not one.
The SPIFFE SVID proves that the *automation platform itself* is legitimate — not just the user.
An attacker who somehow fakes a user login would still fail the workload identity check.
The NetBox update at the end means the CMDB is always in sync with reality.
-->

---

# Section 4 — Exercise Flow

```
  netadmin launches "Configure VLAN"
       │
       ▼
  ┌─── Outer ring (AAP gateway) ───┐
  │  Team: Infrastructure? ✓       │
  └────────────────────────────────┘
       │
       ▼
  Playbook fetches SPIFFE SVID from SPIRE agent
       │
       ▼
  ┌─── Inner ring (playbook → OPA) ────────────┐
  │  SVID valid?          ✓                     │
  │  IdM group: network-admins?  ✓              │
  │  VLAN ID in 100–999?  ✓                     │
  │  Action: create?       ✓                    │
  └─────────────────────────────────────────────┘
       │
       ▼
  Arista: configure VLAN ──▶ NetBox: register VLAN
```

<!--
Speaker notes:
Walk through both rings. Outer ring is the same OPA gateway as Section 3.
Inner ring is different — it's a playbook task that calls OPA with a richer input (SVID, group, VLAN ID).
The VLAN range check (100-999) is enforced by OPA, not by Ansible. Students will test invalid values.
NetBox update at the end ensures the CMDB stays in sync with the actual switch config.
-->

---

<!-- _class: section-divider -->

# Section 5
## Automated Incident Response

*Splunk → EDA → Vault credential revocation*

---

# Section 5 — What You'll Do

**Goal:** Close the detection-to-containment loop — automatically, in under 30 seconds.

- Simulate a **brute-force SSH attack** against the app server
- **Splunk** detects the pattern via a saved search alert
- Splunk sends a **webhook** to Event-Driven Ansible (EDA)
- EDA matches the rulebook and triggers an AAP job to **revoke the app's database credentials** in Vault
- The application is **isolated from sensitive data** without human intervention

**ZTA principles:** Assume breach, continuous monitoring, automated response, blast-radius containment

<!--
Speaker notes:
This is the "assume breach" exercise. The attack succeeds (SSH brute force) but the response is automated.
Credential revocation happens in Vault — the app loses its DB connection immediately.
The key metric: time from detection to containment. Target is under 30 seconds.
Requires Section 2 to be complete (app must be deployed with active DB credentials to revoke).
-->

---

# Section 5 — Exercise Flow

```
  ① Simulate brute-force SSH attack on app server
       │
       ▼
  ② Splunk saved search fires ──▶ Alert triggers webhook
       │
       ▼
  ③ EDA receives webhook ──▶ Matches rulebook condition
       │
       ▼
  ④ EDA triggers AAP job: "Revoke App Credentials"
       │
       ▼
  ⑤ Playbook revokes Vault DB credentials
       │
       ▼
  ⑥ App loses DB connection ──▶ /health returns 503
       │
  ─────────────────────────────────────────────────
  ⑦ After investigation: "Restore App Credentials"
       │
       ▼
  ⑧ Vault issues new DB creds ──▶ App reconnects ──▶ /health returns 200
```

**Total time from detection to containment: < 30 seconds**

<!--
Speaker notes:
Walk through the numbered steps. Steps 1-6 happen automatically.
The restore step (7-8) is manual and deliberate — you investigate first, then restore.
The EDA rulebook is in extensions/eda/rulebooks/splunk-credential-revoke.yml.
The webhook token is stored in Vault and attached to the EDA event stream credential.
-->

---

<!-- _class: section-divider -->
<!-- _class: extended -->

# Extended Security Workshop
## Sections 6 & 7

*Advanced hardening and alternative SIEM integration*
*Your instructor will confirm whether these are included*

---

# Section 6 — SSH Lockdown & Break-Glass _(Extended)_

**Goal:** Apply four progressive layers of SSH hardening, then practise emergency bypass.

**Lockdown layers (applied one at a time):**
1. **Firewall rules** — restrict SSH source IPs
2. **IdM HBAC policies** — control who can SSH where
3. **Vault SSH certificates** — no static keys, short-lived certs only
4. **SIEM monitoring** — Splunk/Wazuh bypass rules for audit

**Break-glass:** simulate an emergency requiring access outside normal controls — under full audit.

**ZTA principles:** Defence in depth, eliminating standing access, certificate-based auth, auditable emergency procedures

<!--
Speaker notes:
Each layer is a separate playbook in setup/ssh_lockdown/.
The point is defence in depth — if one layer fails, the others still hold.
The break-glass scenario is important: Zero Trust doesn't mean "no access ever" — it means
"access under strict conditions with full audit trail."
-->

---

# Section 7 — Wazuh EDA Path _(Extended)_

**Goal:** Mirror the Section 5 incident-response flow using **Wazuh** instead of Splunk.

- Same brute-force simulation
- **Wazuh** detects the attack instead of Splunk
- Same EDA pattern, same revocation playbooks
- Different SIEM source — proves the architecture is **tool-agnostic**

**ZTA principles:** Tooling independence, continuous monitoring, automated containment

Gated by `wazuh_enabled` in configuration — Wazuh infrastructure must be deployed.

<!--
Speaker notes:
This demonstrates that the ZTA architecture isn't locked to a specific SIEM.
Swap Splunk for Wazuh — the EDA pattern and revocation playbooks are the same.
The only difference is the detection source and the webhook format.
This is important for organisations evaluating different SIEM platforms.
-->

---

# Workshop Progression

```
Section 1              Section 2              Section 3             Section 4
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
│ VERIFY           │   │ DEPLOY           │   │ ENFORCE          │   │ PROVE IDENTITY   │
│                  │   │                  │   │                  │   │                  │
│ Wire AAP to     │──▶│ OPA + Vault +   │──▶│ OPA blocks at   │──▶│ SPIFFE SVID +   │
│ IdM, Vault, OPA │   │ Arista in a     │   │ AAP launch      │   │ dual OPA rings  │
│ NetBox, Gitea   │   │ deploy workflow  │   │ (platform gate) │   │ + VLAN + NetBox  │
└─────────────────┘   └─────────────────┘   └─────────────────┘   └─────────────────┘
        │                                                                   │
        │               Section 5              Section 6                    │
        │              ┌─────────────────┐   ┌─────────────────┐           │
        │              │ RESPOND          │   │ HARDEN           │           │
        └─────────────▶│ SIEM → EDA     │──▶│ SSH lockdown    │◄──────────┘
                       │ → revoke creds  │   │ + break-glass   │
                       └─────────────────┘   └─────────────────┘
```

Each section adds a layer of Zero Trust control. Complete them in order.

<!--
Speaker notes:
Use this as a map. Two tracks from Section 1: the main track (1→2→3→4→6)
and the incident response track (1→5→6).
Both converge at Section 6 (hardening).
Emphasise the progressive layering — by Section 5 you have the full detection-to-response loop.
-->

---

# Principles × Sections

| Principle | S1 | S2 | S3 | S4 | S5 | S6 | S7 |
|-----------|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Never trust, always verify | **x** | **x** | **x** | **x** | **x** | **x** | **x** |
| Least privilege | **x** | **x** | | | | **x** | |
| Assume breach | | | | | **x** | | **x** |
| Deny by default | | **x** | **x** | **x** | | | |
| Identity-driven access | **x** | **x** | **x** | **x** | | | |
| Micro-segmentation | | **x** | | **x** | | | |
| Continuous monitoring | | | | | **x** | **x** | **x** |
| Workload identity | | | | **x** | | | |

Every principle is exercised at least twice across the workshop.

<!--
Speaker notes:
Use this as a recap. Walk across the columns, not down the rows.
Highlight that "never trust, always verify" appears in every section — it's the foundation.
"Workload identity" is concentrated in Section 4 because SPIFFE is introduced there.
This matrix can help justify which sections to include in a time-limited session.
-->

---

# Lab Environment

| System | URL | Credentials |
|--------|-----|-------------|
| AAP Controller | `https://control.zta.lab` | Instructor-provided |
| EDA Controller | Same platform | Instructor-provided |
| IdM (FreeIPA) | `https://central.zta.lab` | `admin` / `ansible123!` |
| OPA | `http://central.zta.lab:8181` | No auth |
| Vault | `http://vault.zta.lab:8200` | `admin` / `ansible123!` |
| NetBox | `http://netbox.zta.lab:8880` | API token from instructor |
| Gitea | `http://gitea.zta.lab:3000` | Instructor-provided |
| Splunk | `http://splunk.zta.lab:8000` | As configured |
| App | `http://app.zta.lab:8081` | No auth |

<!--
Speaker notes:
Review the access info. Students should confirm they can reach the AAP controller first.
All IdM user passwords are ansible123! — this is a disposable lab, not production.
Vault is HTTP (not HTTPS) in the lab for simplicity.
-->

---

# Workshop Accounts

| Username | Groups | Role in exercises |
|----------|--------|-------------------|
| `ztauser` | `zta-admins`, `patch-admins`, `app-deployers` | General admin — can patch and deploy |
| `netadmin` | `zta-admins`, `network-admins` | Network admin — VLAN exercises |
| `appdev` | `app-deployers` | App developer — deployment pipeline |
| `neteng` | _(none)_ | Often denied — wrong user scenarios |

All passwords: `ansible123!`

The **deny scenarios** are intentional — you'll log in as the wrong user on purpose to see OPA block the request.

<!--
Speaker notes:
ztauser is the "happy path" account — can do most things.
neteng is the "unhappy path" — used to show what happens when policy denies access.
appdev is scoped to deployments only — can't patch or manage VLANs.
netadmin is for Section 4 VLAN exercises.
Students will switch between accounts to experience both allowed and denied paths.
-->

---

# Resources

**Standards:**
- NIST SP 800-207 — Zero Trust Architecture
  https://csrc.nist.gov/publications/detail/sp/800-207/final

**Platform:**
- Red Hat AAP 2.6 Documentation
  https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/
- Using Automation Decisions (EDA)
  https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/using_automation_decisions/

**Tools:**
- Open Policy Agent — https://www.openpolicyagent.org
- SPIFFE / SPIRE — https://spiffe.io
- HashiCorp Vault — https://www.vaultproject.io

<!--
Speaker notes:
These are reference links for after the workshop.
The AAP 2.6 docs are particularly important — Policy as Code is Chapter 7.4 of "Configuring automation execution".
NIST 800-207 is a readable 50-page PDF — recommend it for anyone building a ZTA business case.
-->

---

<!-- _class: title -->
<!-- _paginate: false -->
<!-- _header: "" -->
<!-- _footer: "" -->

# Let's Get Started

**Open the automation controller at `https://control.zta.lab`**

Section 1 begins now.
