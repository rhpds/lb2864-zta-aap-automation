# Section 4 — SPIFFE-Verified, RBAC-Controlled Network VLAN Management

**AsciiDoc lab:** [`lab/index.adoc`](lab/index.adoc)

## Objective

Demonstrate **defence in depth** for network automation: a VLAN change must be
authorised by **both** a verified workload identity (SPIFFE) and an authorised
user identity (IdM). Two OPA policy rings evaluate both layers before the
Arista switches are touched and the CMDB updated.

## Zero Trust Principles

| Principle | How This Section Demonstrates It |
|-----------|----------------------------------|
| **Defence in depth** | Two OPA policy rings — platform gate + runtime check |
| **Workload identity** | SPIFFE/SPIRE cryptographically proves the automation platform is legitimate |
| **User identity** | IdM group membership determines who can request network changes |
| **Deny by default** | No VLAN change without explicit allow from both rings |
| **Audit trail** | Netbox CMDB records both the user and the workload SPIFFE ID |
| **Micro-segmentation** | VLAN isolation enforced on Arista cEOS switch fabric |

## Zero Trust Layers

| Layer | Technology | What It Proves |
|-------|------------|----------------|
| **Platform gate** | AAP Policy as Code + OPA | The user is allowed to **launch** this job template at all (outer ring) |
| **Workload identity** | SPIFFE / SPIRE | The automation platform itself is cryptographically attested — not a rogue script |
| **User identity** | IdM (FreeIPA) | The human requesting the change is in the `network-admins` group |
| **Runtime policy** | OPA (in-playbook) | SPIFFE ID + user + VLAN + action are validated with runtime context (inner ring) |
| **Enforcement** | AAP + Arista | The job only proceeds if both rings return `allow: true` |
| **Audit trail** | Netbox CMDB | The VLAN record includes both the user and the workload SPIFFE ID |

## Defence in Depth — Two OPA Policy Rings

```
  User clicks "Launch" in AAP
       │
       ▼
  ┌─────────────────────────────────────────────────┐
  │  OUTER RING — AAP Policy as Code (aap.gateway)  │
  │                                                  │
  │  AAP Controller asks OPA:                        │
  │    "Can this user launch this template?"         │
  │                                                  │
  │  Checks: user groups vs template name            │
  │  neteng → Configure VLAN = DENIED (never runs)   │
  │  netadmin → Configure VLAN = ALLOWED             │
  └──────────────────────┬──────────────────────────┘
                         │ (only if outer ring allows)
                         ▼
  ┌─────────────────────────────────────────────────┐
  │  INNER RING — In-playbook policy (zta.network)   │
  │                                                  │
  │  Playbook asks OPA with runtime context:         │
  │    SPIFFE ID + user + VLAN ID + action           │
  │                                                  │
  │  Checks: workload identity, VLAN range,          │
  │          action allowlist, user group             │
  └──────────────────────┬──────────────────────────┘
                         │ (only if inner ring allows)
                         ▼
                  Arista + Netbox
```

The **outer ring** cannot be bypassed — AAP enforces it before the playbook
even starts. The **inner ring** validates parameters that only exist at
runtime (the specific VLAN ID, the SPIFFE workload identity).

## OPA Policies

### Outer Ring — `aap.gateway` (platform level)

Matches job template names to required AAP teams (populated from IdM groups via LDAP):

| Template pattern | Required AAP team |
|-----------------|-------------------|
| Contains "VLAN" or "Network" | Infrastructure |
| Contains "Patch" | Infrastructure or Security |
| Contains "Deploy", "Credential", "Application" | Applications or DevOps |
| Everything else | Any authenticated user |

### Inner Ring — `zta.network` (runtime level)

The `zta.network` policy checks **four conditions** — all must pass:

| # | Condition | What It Checks |
|---|-----------|----------------|
| 1 | **Workload verified** | Caller's SPIFFE ID is in the trusted set (`spiffe://zta.lab/workload/network-automation`) |
| 2 | **User authorized** | User is in the `network-admins` group in IdM |
| 3 | **Valid VLAN** | VLAN ID is in the permitted range (100–999) |
| 4 | **Action permitted** | Action is one of: `create_vlan`, `modify_vlan`, `delete_vlan`, `assign_port` |

---

## Exercise 4.1 — Create the Job Template

| Template Name | Playbook | Inventory | Credentials |
|---------------|----------|-----------|-------------|
| Configure VLAN | `section4/playbooks/configure-vlan.yml` | ZTA Lab Inventory | ZTA Machine Credential, ZTA Arista Credential |

### Survey Variables

The template should prompt for:
- `new_vlan_id`: VLAN ID to create (e.g. `200`)
- `new_vlan_name`: VLAN name (e.g. `DMZ`)

---

## Exercise 4.2 — Denied (Network Engineer)

1. Log into AAP as `neteng` (not a member of any group)
2. Launch the **Configure VLAN** template
3. Fill in: `new_vlan_id: 200`, `new_vlan_name: DMZ`
4. Observe the output:

```
SPIFFE Workload Identity Verification

  SPIFFE ID: spiffe://zta.lab/workload/network-automation
  Host:      control
  Status:    VERIFIED ✓

OPA Network Policy Decision

  User:      neteng
  Action:    create_vlan
  VLAN ID:   200
  SPIFFE ID: spiffe://zta.lab/workload/network-automation
  Result:    DENIED

  Conditions:
    Workload verified:      PASS
    User in network-admins: FAIL
    Valid VLAN ID:          PASS
    Action permitted:       PASS

  DENIED: user 'neteng' is not a member of network-admins group
```

The SPIFFE check passes (the platform is legitimate) but the **user** is not
authorised. The Arista switches are never touched.

---

## Exercise 4.3 — Allowed (Network Admin)

1. Log into AAP as `netadmin` (member of `network-admins`)
2. Launch the same **Configure VLAN** template
3. Fill in: `new_vlan_id: 200`, `new_vlan_name: DMZ`
4. Observe the success:

```
SPIFFE Workload Identity Verification

  SPIFFE ID: spiffe://zta.lab/workload/network-automation
  Status:    VERIFIED ✓

OPA Network Policy Decision

  Result:    ALLOWED
  All conditions: PASS

VLAN 200 (DMZ) created on ceos1, ceos2, ceos3

VLAN Configuration Complete

  VLAN 200 (DMZ)
  Switches:   ceos1, ceos2, ceos3 (Arista cEOS fabric)
  Netbox:     Created
  User:       netadmin
  Workload:   spiffe://zta.lab/workload/network-automation
```

5. Verify on the Arista switches: `show vlan brief` — VLAN 200 should appear
6. Verify in Netbox: the VLAN record includes the SPIFFE workload ID in the description

---

## Exercise 4.4 — Test Additional Scenarios

### Scenario A — Invalid VLAN range

1. Log in as `netadmin`
2. Launch with `new_vlan_id: 5000` (outside 100–999 range)
3. Observe: OPA denies — "VLAN ID 5000 is outside the permitted range"

### Scenario B — Missing SPIFFE identity

1. Stop the SPIRE Agent on the `control` host:
   ```bash
   ssh rhel@control.zta.lab
   sudo systemctl stop spire-agent
   ```
2. Launch **Configure VLAN** as `netadmin` with valid parameters
3. Observe: the job fails at the SPIFFE verification step — cannot fetch SVID
4. **Restart the agent** when done:
   ```bash
   sudo systemctl start spire-agent
   ```

### Scenario C — Fix access by adding group membership

1. In IdM, add `neteng` to the `network-admins` group:
   ```bash
   ipa group-add-member network-admins --users=neteng
   ```
2. Launch **Configure VLAN** as `neteng` — it should now succeed
3. Remove the membership when done:
   ```bash
   ipa group-remove-member network-admins --users=neteng
   ```

---

## Playbook Flow

```
  AAP launches "Configure VLAN" job template
       │
       ▼
  Play 1 — SPIFFE Workload Identity Verification
  ──────────────────────────────────────────────
  Runs on: automation (AAP control node)
       │
       ├─ Fetch X.509 SVID from local SPIRE Agent
       │    → spiffe://zta.lab/workload/network-automation
       │
       └─ SVID proves the automation platform is legitimate
       │
       ▼
  Play 2 — OPA Policy Decision
  ────────────────────────────
  Runs on: zta_services (central)
       │
       ├─ POST to OPA with:
       │    • user + user_groups (from IdM/AAP)
       │    • spiffe_id (from SPIRE SVID)
       │    • action + vlan_id
       │
       ├─ OPA evaluates all 4 conditions
       │
       └─ ALLOW or DENY
       │
       ▼ (only if ALLOWED)
  Play 3 — Arista VLAN Configuration
  ──────────────────────────────────
  Runs on: network (ceos1, ceos2, ceos3)
       │
       └─ arista.eos.eos_vlans creates the VLAN
       │
       ▼
  Play 4 — Netbox CMDB Update
  ───────────────────────────
  Runs on: zta_services (central)
       │
       └─ Records VLAN with user + workload SPIFFE ID
```

---

## SPIFFE / SPIRE Background

[SPIFFE](https://spiffe.io/) (Secure Production Identity Framework For Everyone) provides
cryptographic identities to workloads. In this workshop:

- **SPIRE Server** runs on `central` alongside IdM and OPA
- **SPIRE Agents** run on `control` (AAP), `db`, and `vault`
- Each workload receives an **X.509 SVID** (SPIFFE Verifiable Identity Document)
- The SVID is short-lived and automatically rotated — no static secrets

The trust domain is `zta.lab`, matching the IdM domain. The registered
network automation workload identity is:

```
spiffe://zta.lab/workload/network-automation
```

---

## Discussion Points

- **Why verify the workload, not just the user?** A compromised script running outside
  AAP could impersonate a network admin. SPIFFE proves the *platform* is legitimate.
- What if `neteng` is added to `network-admins` in IdM? Does the next attempt succeed?
- What happens with a VLAN ID outside the permitted range (e.g. 5000)?
- How would you add an approval workflow before the VLAN is created?
- How does the Netbox CMDB record (with both user and SPIFFE ID) provide an audit trail?
- What if the SPIRE Agent on the AAP node is stopped? Can VLANs still be created?
- What is the difference between the outer ring (platform gate) and inner ring (runtime check)?
- Could someone bypass the outer ring by using `ansible-playbook` directly instead of AAP?

---

## Validation Checklist

- [ ] SPIRE Agent on `control` can fetch an SVID with the correct SPIFFE ID
- [ ] `neteng` is denied when attempting VLAN creation (workload passes, user fails)
- [ ] `netadmin` is allowed and the VLAN is created on the Arista cEOS switches
- [ ] Netbox is updated with the new VLAN, including the SPIFFE workload ID
- [ ] VLAN IDs outside range 100–999 are rejected by OPA
- [ ] The Arista switches show the new VLAN in `show vlan brief`
- [ ] If SPIRE Agent is stopped, the job fails at the SPIFFE verification step
- [ ] Adding `neteng` to `network-admins` in IdM allows the next attempt to succeed

---

# Exercise 4.5 — Network ACL Hands-On with Arista (Hands-On)

## The Scenario

The micro-segmentation ACL on the Arista cEOS switch has been changed to an
**overly permissive rule** — any host can now reach the database on any port.
This defeats the Zero Trust principle of least-privilege network access.

You must SSH directly into the switch, identify the misconfiguration, and
fix it manually from the switch CLI.

> **Instructor:** Run `ansible-playbook section4/playbooks/break-acl.yml`

## Duration: ~20 minutes

---

## Step 1 — Explore the Switch

SSH into the Arista cEOS leaf switch that handles the data tier:

```bash
ssh -p 2002 admin@central.zta.lab
# Password: admin
```

Get oriented:

```bash
# What VLANs exist?
show vlan brief

# What interfaces are configured?
show ip interface brief

# What ACLs are applied?
show access-lists summary
```

---

## Step 2 — Examine the Broken ACL

```bash
show access-lists ZTA-APP-TO-DB
```

You'll see:
```
IP Access List ZTA-APP-TO-DB
    10 permit ip any host 10.30.0.10
```

**Problem:** This allows **any** host to reach the database (10.30.0.10) on
**any** protocol and port. Only the app server (10.20.0.10) should be able
to reach the database, and only on port 5432 (PostgreSQL).

Check hit counters to see traffic patterns:

```bash
show access-lists ZTA-APP-TO-DB | include counters
```

---

## Step 3 — Fix the ACL

Enter configuration mode and replace the overly permissive rule:

```bash
configure terminal

ip access-list ZTA-APP-TO-DB
  no 10
  10 permit tcp host 10.20.0.10 host 10.30.0.10 eq 5432
  20 deny ip any host 10.30.0.10
  exit

exit
```

Verify the fix:

```bash
show access-lists ZTA-APP-TO-DB
```

Expected:
```
IP Access List ZTA-APP-TO-DB
    10 permit tcp host 10.20.0.10 host 10.30.0.10 eq 5432
    20 deny ip any host 10.30.0.10
```

---

## Step 4 — Verify Micro-segmentation

Check that the application can still reach the database:

```bash
# From outside the switch (back on your terminal):
curl http://app.zta.lab:8081/health
# Expected: healthy (app → DB on port 5432 is permitted)
```

The deny rule ensures no other host can reach the database.

---

## Step 5 — Discuss Configuration Drift

You just fixed the ACL manually on the switch. But what happens next time
AAP runs the VLAN or ACL playbook? It will overwrite your manual fix with
whatever is in the playbook (which may be different).

**This is configuration drift.** Manual changes to network devices create a
gap between the desired state (in Git/AAP) and the actual state (on the
switch). In Zero Trust:

- **Desired state should live in code** (Ansible playbooks in Git)
- **Enforcement should be automated** (AAP applies the state)
- **Drift detection** (compare running config vs. intended config) is needed

> Save the running config on the switch to see what Arista has:
> ```bash
> show running-config section access-list
> ```

---

## Network ACL Discussion Points

- What is the risk of an overly permissive ACL in a ZTA environment?
- How would you detect configuration drift between AAP's intended state and
  the actual switch config?
- Should manual switch access be allowed in a Zero Trust environment?
- How does the Arista ACL complement the firewalld rules on the DB host?
- What if someone adds a rogue switch to the fabric?

## Network ACL Validation Checklist

- [ ] Connected to ceos2 via SSH on port 2002
- [ ] `show access-lists` reveals the overly permissive rule
- [ ] ACL manually fixed to permit only app → DB on port 5432
- [ ] Deny rule blocks all other traffic to the DB
- [ ] App health check passes after ACL fix
- [ ] `show running-config section access-list` confirms the fix
