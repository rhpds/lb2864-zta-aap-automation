# Zero Trust Architecture Workshop — Ansible Automation Platform

## Introduction

Zero Trust Architecture (ZTA) replaces the traditional perimeter security model — where everything inside the firewall is trusted — with **identity-centric, policy-driven, continuously verified access**, enforced as close to the resource as possible.

The premise is simple: **no actor, system, network, or service is trusted by default**. Every request for access must be verified, authorised, and continuously validated before it is granted. NIST Special Publication 800-207 formalises this as three logical components:

- **Policy Decision Point (PDP)** — evaluates access requests against policy and returns allow or deny. In this lab: **Open Policy Agent (OPA)**, evaluating Rego policies against identity, infrastructure state, and request context.
- **Policy Enforcement Point (PEP)** — intercepts requests and enforces the PDP's decision. In this lab: **Ansible Automation Platform (AAP)**, which queries OPA before launching jobs and within playbook execution.
- **Policy Information Point (PIP)** — supplies the contextual data the PDP needs. In this lab: **IdM** (identity and group membership), **NetBox** (infrastructure state and maintenance windows), **Vault** (credential status), and **Splunk/Wazuh** (threat signals).

```
                 ┌────────────────────────┐
                 │   Policy Decision      │
                 │   Point (PDP)          │
                 │                        │
                 │   Open Policy Agent    │
                 │   opa-policies/*.rego  │
                 └──────────┬─────────────┘
                            │
                   allow / deny + violations
                            │
┌──────────────┐   ┌────────▼─────────────┐   ┌──────────────────────┐
│ Identity     │   │  Policy Enforcement  │   │ Secrets              │
│ (PIP)        │◄──┤  Point (PEP)         ├──►│                      │
│              │   │                      │   │ HashiCorp Vault      │
│ IdM/FreeIPA  │   │  AAP Controller      │   │ Dynamic creds, SSH   │
│ SPIFFE/SPIRE │   │  + EDA Controller    │   │ CA, secret storage   │
└──────────────┘   └────────┬─────────────┘   └──────────────────────┘
                            │
                   execute / configure
                            │
                   ┌────────▼─────────────┐   ┌──────────────────────┐
                   │ Infrastructure       │   │ Monitoring           │
                   │                      │   │ (PIP)                │
                   │ App, DB, Arista cEOS │   │                      │
                   │ RHEL containers      │   │ Splunk / Wazuh       │
                   └──────────────────────┘   │ → EDA → remediation  │
                                              └──────────────────────┘
```

### Why Ansible Automation Platform for Zero Trust

Zero Trust demands that every operational change — patching a server, rotating a credential, reconfiguring a network ACL — passes through the same identity, policy, and audit gates. Without a central orchestration layer, each action requires its own integration with the identity provider, policy engine, secrets manager, and SIEM.

AAP fills the role of **Policy Enforcement Point** for operational automation:

- **Single control plane** — manages RHEL hosts, Arista network switches, PostgreSQL databases, and containerised applications from one platform. A ZTA that covers servers but ignores the network or application layer leaves gaps.
- **Policy as Code** — AAP 2.6 integrates with OPA through pre-launch authorisation. Before a job template starts, the controller sends the full job context to OPA. Unauthorised launches are blocked before any playbook task executes. This creates two enforcement rings: an **outer ring** (platform-level, at launch) and an **inner ring** (playbook-level, mid-execution).
- **No credentials at rest** — AAP resolves machine and network passwords from Vault at job time through credential lookups. The platform database never stores actual passwords. For SSH, Vault acts as a certificate authority, issuing short-lived signed certificates instead of distributing static keys.
- **Identity-aware automation** — AAP authenticates operators through IdM LDAP. Group memberships mapped to AAP teams determine which templates a user can see and launch, enforced by both AAP RBAC and OPA policy.
- **Event-driven response** — EDA receives webhooks from Splunk or Wazuh, matches events against rulebooks, and triggers remediation jobs — revoking credentials or isolating hosts in seconds rather than the minutes or hours of a manual process.
- **Auditability** — every job run is logged with the user, the policy decision, the credentials issued, and the changes made. Playbooks are version-controlled in Gitea, giving a complete chain of evidence from intent through authorisation to execution.

### Workshop journey

The seven sections progressively layer ZTA controls, from verifying integrations through automated incident response:

```
Section 1              Section 2              Section 3             Section 4
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
│ VERIFY           │   │ DEPLOY           │   │ ENFORCE          │   │ PROVE IDENTITY   │
│                  │   │                  │   │                  │   │                  │
│ Wire AAP to:    │──►│ OPA + Vault +   │──►│ OPA blocks at   │──►│ SPIFFE SVID +   │
│ IdM, Vault, OPA,│   │ Arista in a     │   │ AAP launch      │   │ dual OPA rings  │
│ NetBox, Gitea   │   │ deploy workflow  │   │ (platform gate) │   │ + VLAN + NetBox  │
└─────────────────┘   └─────────────────┘   └─────────────────┘   └─────────────────┘
        │                                                                   │
        │               Section 5              Section 6                    │
        │              ┌─────────────────┐   ┌─────────────────┐           │
        │              │ RESPOND          │   │ HARDEN           │           │
        │              │                  │   │                  │           │
        └─────────────►│ SIEM detects    │──►│ Layered SSH     │◄──────────┘
                       │ attack → EDA    │   │ lockdown +      │
                       │ revokes creds   │   │ break-glass     │
                       └─────────────────┘   └─────────────────┘
```

Each section builds on the previous one. Section 1 wires the integrations that sections 2-7 depend on. Complete them in order unless directed otherwise.

---

## Lab Architecture

```
                            ┌──────────────────┐
                            │   AAP Controller  │
                            │  control.zta.lab  │
                            │   EDA Controller  │
                            └────────┬─────────┘
                                     │
          ┌──────────┬──────────┬────┼──────────┐
          │          │          │    │           │
     ┌────▼───┐ ┌───▼───┐ ┌───▼──┐ │      ┌───▼──────────────────────────────────┐
     │ Vault  │ │Netbox │ │Gitea │ │      │  Central VM  (192.168.1.11)          │
     │  .zta  │ │ .zta  │ │.zta  │ │      │                                     │
     │  .lab  │ │ .lab  │ │.lab  │ │      │  Host services: IdM, OPA, Keycloak, │
     │        │ │       │ │      │ │      │                 SPIRE Server         │
     │Secrets │ │ CMDB  │ │ Git  │ │      │                                     │
     │SSH CA  │ │       │ │Server│ │      │  Containers:                        │
     └────────┘ └───────┘ └──────┘ │      │  ┌────────┐ ┌────────┐ ┌────────┐  │
          │          │         │   │      │  │Splunk  │ │ Wazuh  │ │Keycloak│  │
          └──────────┴─────────┴───┘      │  │ :8000  │ │:5601   │ │ :8543  │  │
                     │                    │  │ :8088  │ │:9200   │ │        │  │
         192.168.1.0/24 mgmt network     │  │        │ │:55000  │ │        │  │
         ────────────────────────────     │  └────────┘ └────────┘ └────────┘  │
                     │                    │                                     │
                     └────────────────────┤  ┌──────────────────────────────┐   │
                                          │  │  Arista cEOS Switch Fabric   │   │
                                          │  │  ceos1 (spine)               │   │
                                          │  │    ├── ceos2 (leaf/data)     │   │
                                          │  │    └── ceos3 (leaf/app)      │   │
                                          │  └──┬───────────────────┬──────┘   │
                                          │     │                   │          │
                                          │  ┌──▼──────┐  ┌────────▼──┐       │
                                          │  │  DB      │  │   App     │       │
                                          │  │10.30.0.10│  │10.20.0.10 │       │
                                          │  │ :2022 SSH│  │ :2023 SSH │       │
                                          │  │ :5432 PG │  │ :8081 HTTP│       │
                                          │  └─────────┘  └───────────┘       │
                                          └────────────────────────────────────┘
```

## Components


| Component                  | Role                                                | Host                                    |
| -------------------------- | --------------------------------------------------- | --------------------------------------- |
| **IdM (FreeIPA)**          | Identity, LDAP, Kerberos, CA, DNS                   | central.zta.lab                         |
| **Open Policy Agent**      | Policy-based authorisation (deny-by-default)        | central.zta.lab                         |
| **Keycloak**               | SSO / OIDC (future use)                             | central.zta.lab                         |
| **SPIRE Server**           | Trust root for SPIFFE workload identity             | central.zta.lab                         |
| **SPIRE Agents**           | Workload attestation, SVID issuance                 | control, db, vault                      |
| **HashiCorp Vault**        | Secrets management, dynamic DB creds, SSH CA        | vault.zta.lab                           |
| **NetBox**                 | CMDB / source of truth for infrastructure           | netbox.zta.lab                          |
| **Gitea**                  | Git server for GitOps workflows                     | gitea.zta.lab                           |
| **Splunk**                 | Log aggregation, security analytics                 | central.zta.lab (container)             |
| **Wazuh**                  | SIEM, vulnerability scanning, brute-force detection | central.zta.lab (container)             |
| **AAP 2.6 Controller**     | Automation orchestration (Policy Enforcement Point) | control.zta.lab                         |
| **AAP 2.6 EDA Controller** | Event-Driven Ansible (automated incident response)  | control.zta.lab                         |
| **Arista cEOS**            | 3-switch fabric (spine + 2 leaf), VLANs, ACLs       | central.zta.lab (containers)            |
| **PostgreSQL**             | Application database                                | central.zta.lab (container, 10.30.0.10) |
| **App Server**             | Global Telemetry Platform (Flask)                   | central.zta.lab (container, 10.20.0.10) |


## Network Architecture

**Management plane** (`192.168.1.0/24`):
All VMs (central, AAP, Vault, NetBox) on this network. External VMs reach
containers via published ports on central's management IP.

**Data plane** (internal Podman networks, routed via Arista cEOS):

- `net2` = `10.30.0.0/24` (data-tier) — DB container, ceos2 gateway
- `net3` = `10.20.0.0/24` (app-tier) — App container, ceos3 gateway
- ACLs on switches control cross-tier traffic

## Repository Structure

```
├── setup/                       # Lab provisioning and configuration playbooks
│   ├── configure-*.yml          #   Service configuration (Vault, OPA, AAP, etc.)
│   ├── deploy-*.yml             #   Service deployment (containers, switches, etc.)
│   ├── integrate-splunk.yml     #   Splunk integration
│   ├── site.yml                 #   Master orchestrator (phased full deploy)
│   ├── verify-lab.yml           #   Full lab health check
│   ├── validation/              #   Per-section check and solve playbooks
│   ├── ssh_lockdown/            #   Layered SSH lockdown playbooks
│   ├── switch-configs/          #   Arista cEOS startup configs
│   ├── vars/                    #   Job template definitions
│   └── tasks/                   #   Shared task files
│
├── section1/playbooks/          # Verify ZTA services and AAP integration
├── section2/playbooks/          # Deploy app with short-lived Vault DB credentials
├── section3/playbooks/          # AAP Policy as Code — platform-gated patching
├── section4/playbooks/          # SPIFFE-verified VLAN management
├── section5/playbooks/          # Automated incident response (Splunk → EDA → Vault)
├── section6/playbooks/          # SSH lockdown and break-glass
├── section7/playbooks/          # Wazuh EDA path (optional)
│
├── opa-policies/                # Rego policies deployed to OPA
│   ├── aap_gateway.rego         #   AAP gateway outer ring (team-based launch control)
│   ├── db_access.rego           #   Database access policy (Section 2)
│   ├── network.rego             #   SPIFFE + VLAN inner ring (Section 4)
│   ├── patching.rego            #   Maintenance window gating (Section 3)
│   ├── data_classification.rego #   Data classification (Section 3B)
│   └── zta_base.rego            #   Shared base policy
│
├── inventory/                   # Ansible inventory
│   ├── hosts.ini                #   INI inventory (primary)
│   ├── hosts.yml                #   YAML inventory
│   ├── group_vars/all.yml       #   Lab defaults and credentials
│   └── netbox_inventory.yml     #   NetBox dynamic inventory plugin config
│
├── app/                         # Global Telemetry Platform (Flask application)
├── dashboard/                   # Lab dashboard (Flask)
└── extensions/eda/rulebooks/    # EDA rulebooks (Splunk + Wazuh credential revoke)
```

## Workshop Sections

### Section 1 — Verify ZTA Components & AAP Integration

Connect AAP to IdM, Vault, OPA, NetBox, and Gitea. Verify Vault lookups,
dynamic inventory, and job templates. Configure LDAP authentication.

### Section 2 — Deploy Application with Short-Lived Credentials

Deploy the Global Telemetry Platform using short-lived Vault database
credentials. OPA denies the wrong user, Arista ACLs gate data-plane traffic,
and credentials expire after 5 minutes.

### Section 3 — AAP Policy as Code: Platform-Gated Patching

AAP Policy as Code blocks a security patch when the user lacks the right team
membership. Fix group membership and apply a security hardening patch (login
banner, SSH hardening, password policy, audit logging). Section 3B covers
Rego data classification break/fix.

### Section 4 — SPIFFE-Verified Network VLAN Management

Create VLANs through two OPA policy rings: the outer ring (AAP gateway) checks
team-based launch permissions, and the inner ring validates SPIFFE workload
identity, user group, VLAN range, and action. Update NetBox CMDB on success.

### Section 5 — Automated Incident Response (Splunk → EDA → Vault)

Simulate a brute-force SSH attack. Splunk detects it and sends a webhook to
Event-Driven Ansible, which triggers an AAP job to revoke the application's
database credentials in Vault — isolating the app from sensitive data in under
30 seconds.

### Section 6 — SSH Lockdown & Break-Glass

Four-layer SSH lockdown: firewall rules, IdM HBAC policies, Vault SSH CA
policies, and Splunk/Wazuh bypass rules. Break-glass procedures for emergency
access.

### Section 7 — Wazuh EDA Path (Optional)

Mirror of Section 5 using Wazuh detection instead of Splunk. Same
revoke/restore playbooks, different SIEM source. Gated by `wazuh_enabled`.

## Platform Version

Targets **Red Hat Ansible Automation Platform 2.6** (automation controller and
Event-Driven Ansible controller).

## Zero Trust Principles Demonstrated


| Principle                      | Where                                                       |
| ------------------------------ | ----------------------------------------------------------- |
| **Never trust, always verify** | Every AAP job checks OPA policy before execution            |
| **Least privilege**            | Vault issues DB credentials with minimum grants             |
| **Short-lived credentials**    | Dynamic DB users expire; SSH certificates are time-bound    |
| **No standing access**         | SSH requires a Vault-signed certificate — no static keys    |
| **Deny by default**            | OPA blocks all actions unless explicitly allowed            |
| **Identity-driven access**     | IdM groups control who can run which operations             |
| **Workload identity**          | SPIFFE/SPIRE proves the automation platform is legitimate   |
| **Platform enforcement**       | AAP Policy as Code blocks unauthorised launches             |
| **Micro-segmentation**         | Arista ACLs isolate app and data tiers on the switch fabric |
| **Continuous monitoring**      | Splunk/Wazuh watch every authentication attempt             |
| **Assume breach**              | EDA automatically revokes credentials on attack detection   |
| **Blast radius containment**   | Credential revocation limits attacker data access           |
| **CMDB as source of truth**    | NetBox validates infrastructure state for policy            |
| **GitOps**                     | Code push triggers automated, policy-governed pipelines     |


