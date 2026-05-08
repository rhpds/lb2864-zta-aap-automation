# Section 3 — AAP Policy as Code: Platform-Gated Patching

**AsciiDoc lab:** [`lab/index.adoc`](lab/index.adoc)

> **2-Hour Workshop Delivery Guide**
>
> | Exercise | Status | Est. Time |
> |----------|--------|-----------|
> | 3.1 — Create the Job Template | **Core** | 2 min |
> | 3.2 — Attempt as Wrong User (BLOCKED BY AAP) | **Core** | 5 min |
> | 3.3 — Fix the Access | **Core** | 3 min |
> | 3.4 — Apply the Patch Successfully | **Core** | 3 min |
> | 3.5 — Verify the Patch Was Applied | **Core** | 3 min |
> | 3.6 — Test Other Scenarios | **Core** | 5 min |
> | Section 3B — Manual OPA Rego Policy Authoring | **Extended** | 30 min |
>
> For a **2-hour workshop**, complete exercises **3.1–3.6** (~20 min).
> Section 3B is a deep-dive hands-on lab for longer formats only.

## Prerequisite

The automation controller must have **Policy as Code** enabled and pointed at the workshop OPA gateway (`v1/data/aap/gateway/decision`). Use `setup/configure-aap-policy.yml`, or configure manually via the controller UI/API — see **`docs/deployment-guide.md`** (Layer 7 — Policy, *Manual Policy as Code*). Ensure `setup/configure-opa-base.yml` has loaded OPA policies (including `aap.gateway`) first.

## Objective

Demonstrate how AAP **Policy as Code** prevents unauthorised users from even
**launching** a job template. The OPA gateway policy (`aap.gateway`) evaluates
every launch request at the platform level — before the playbook runs. A user
not in `patch-admins` tries to apply a security patch and is blocked
immediately by AAP. After fixing the group membership, the patch succeeds.

## Zero Trust Principles

| Principle | How This Section Demonstrates It |
|-----------|----------------------------------|
| **Platform-level enforcement** | AAP checks OPA before the playbook starts — no bypass possible |
| **Deny by default** | No group membership = no launch permission |
| **Identity-driven access** | IdM group (`patch-admins`) controls who can patch |
| **Separation of duties** | Network admins cannot patch; patch admins cannot create VLANs |
| **Audit trail** | AAP logs every denied launch attempt |

## How AAP Policy as Code Works

```
  User clicks "Launch" in AAP
       │
       ▼
  ┌─────────────────────────────────────────────────────┐
  │  AAP Controller                                     │
  │                                                     │
  │  Before running ANY playbook, AAP sends a request   │
  │  to OPA with:                                       │
  │    • user (username, groups, is_superuser)           │
  │    • action ("launch")                              │
  │    • resource (template name, type)                  │
  │                                                     │
  │          POST → OPA (aap.gateway)                   │
  │                                                     │
  └─────────────────────────┬───────────────────────────┘
                            │
                ┌───────────┴───────────┐
                │                       │
           OPA: ALLOW              OPA: DENY
                │                       │
                ▼                       ▼
         Playbook runs          AAP blocks the job
         normally               User sees "DENIED"
                                Playbook never starts
```

The gateway policy matches template names to required groups:

| Template name contains | Required AAP team |
|------------------------|-------------------|
| "Patch" | Infrastructure or Security |
| "VLAN" or "Network" | Infrastructure |
| "Deploy", "Credential", "Application" | Applications or DevOps |
| Everything else | Any authenticated user |

---

## The Patch

The security patch (`apply-security-patch.yml`) deploys:

1. **Login banner** — Legal warning on `/etc/issue` and `/etc/motd`
2. **SSH hardening** — Disable root login, limit auth attempts to 3
3. **Password policy** — 12-character minimum with complexity requirements
4. **Audit logging** — Monitor authentication, identity files, and sudoers

---

## Exercise 3.1 — Create the Job Template

| Template Name | Playbook | Inventory | Credentials |
|---------------|----------|-----------|-------------|
| Apply Security Patch | `section3/playbooks/apply-security-patch.yml` | ZTA Lab Inventory | ZTA Machine Credential |

The template should prompt for:
- `target_host`: hostname to patch (e.g. `app`)

**Important:** The template name contains "Patch" — this is what triggers
the `aap.gateway` policy to require `patch-admins` membership.

---

## Exercise 3.2 — Attempt as Wrong User (BLOCKED BY AAP)

1. Log into AAP as `neteng` (network engineer — **not** in `patch-admins`)
2. Navigate to the **Apply Security Patch** template
3. Click **Launch**

**What happens:**

AAP sends the launch request to OPA. The `aap.gateway` policy evaluates:

```
Template: "Apply Security Patch"  → contains "patch"  → requires Infrastructure or Security team
User:     neteng                  → teams: []          → NOT in any team

Result: DENIED at platform level
```

**AAP blocks the job entirely.** The playbook never starts. No SSH connection
to the target. No changes. `neteng` sees a denial message in the AAP UI.

This is different from an in-playbook policy check (like Section 4) — here
the **platform itself** enforces the gate. Even if someone modified the
playbook to remove a policy check, AAP would still block the launch.

---

## Exercise 3.3 — Fix the Access

**Option A** — Log in as a user already in the Infrastructure team:

Use `ztauser` or `jsmith` (both are in `team-infrastructure` in IdM, which maps to the **Infrastructure** AAP team via LDAP).

**Option B** — Add the user to the team group in IdM:

```bash
ssh rhel@central.zta.lab
sudo ipa group-add-member team-infrastructure --users=neteng
```

---

## Exercise 3.4 — Apply the Patch Successfully

1. Log into AAP as `ztauser` (member of **Infrastructure** team)
2. Launch **Apply Security Patch** with `target_host: app`
3. AAP checks OPA — `ztauser` is in Infrastructure team — **ALLOWED**
4. The playbook runs and applies all four hardening measures:

```
Security Patch Applied

  Host:      app.zta.lab
  Patch:     ZTA-SEC-2026-001

  Applied:
    ✓ Security login banner (/etc/issue + /etc/motd)
    ✓ SSH hardening (no root, max 3 auth tries)
    ✓ Password policy (12 char min, complexity)
    ✓ Audit logging (auth, identity, sudoers)

  This patch was authorised by AAP Policy as Code.
  Only Infrastructure or Security teams can launch this template.
```

---

## Exercise 3.5 — Verify the Patch Was Applied

SSH into the patched server and confirm:

```bash
ssh -p 2023 rhel@central.zta.lab
```

You should see the new login banner immediately. Then check:

```bash
# Verify SSH hardening
sudo sshd -T | grep -E 'permitrootlogin|maxauthtries|permitemptypasswords'
# Expected: permitrootlogin no, maxauthtries 3, permitemptypasswords no

# Verify password policy
cat /etc/security/pwquality.conf.d/zta-policy.conf

# Verify audit rules
sudo auditctl -l | grep zta
```

---

## Exercise 3.6 — Test Other Scenarios

### Scenario A — `appdev` tries to patch

1. Log in as `appdev` (in **Applications** team, not Infrastructure or Security)
2. Try to launch **Apply Security Patch**
3. Result: **BLOCKED** — Applications team cannot launch patching templates

### Scenario B — Remove group membership

1. Remove `neteng` from `team-infrastructure` (if you added them in Exercise 3.3):
   ```bash
   ipa group-remove-member team-infrastructure --users=neteng
   ```
2. Try to launch as `neteng` again — **BLOCKED** (back to denied)

### Scenario C — Separation of duties

Notice that `appdev` (in **Applications** team) **cannot** launch patching
templates, and `ztauser` (in **Infrastructure** team) **can** launch patching but
different teams control different operations. This is separation of duties
enforced by policy.

---

## Discussion Points

- How is this different from AAP's built-in RBAC? (Answer: OPA policies are
  code, versioned in Git, and can encode arbitrary logic beyond simple roles)
- What if someone renames the template to avoid the policy? (Answer: the policy
  can also match on template ID, inventory, or other attributes)
- Could you add a time-of-day restriction? (Yes — OPA can check `time.now_ns()`)
- What's the difference between platform-level gating (this section) and
  in-playbook OPA checks (Section 4)?

---

## Validation Checklist

- [ ] `neteng` (not in any team) is **blocked by AAP** before the playbook runs
- [ ] AAP UI shows the denial — the job never starts
- [ ] `ztauser` (in Infrastructure team) launches successfully
- [ ] Login banner is visible when SSH-ing to the patched server
- [ ] SSH hardening is applied (root login disabled, max 3 auth tries)
- [ ] Password policy is deployed
- [ ] Audit rules are active
- [ ] `appdev` (Applications team) cannot launch patching templates (separation of duties)

---

# Extended Exercises (Longer Formats Only)

# Section 3B — Manual OPA Rego Policy Authoring (Hands-On)

## Objective

Move from **consuming** OPA policies to **writing and debugging** them. A
data classification policy has been deployed with deliberate logic bugs.
Participants must find the bugs by querying OPA, read the Rego source,
fix the policy, and verify their fix.

## Duration: ~30 minutes

## The Scenario

A new `data_classification` policy controls access to databases based on
sensitivity levels: `public`, `internal`, `confidential`, and `pii`.
Someone pushed a buggy version. Sensitive PII data is exposed to users
who should not have access.

### Classification Rules (intended)

| Level | Who should have access |
|-------|----------------------|
| `public` | Any authenticated user |
| `internal` | `app-deployers` or `db-admins` |
| `confidential` | `db-admins` only |
| `pii` | BOTH `security-ops` AND `db-admins` (dual-group requirement) |

---

## Exercise 3B.1 — Discover the Bugs

> **Instructor:** Run `ansible-playbook section3/playbooks/break-opa-policy.yml`
> before this exercise.

Query OPA from the terminal and test each classification level:

**Test 1 — PII access for security-ops user (should be DENIED):**

```bash
curl -s http://central.zta.lab:8181/v1/data/zta/data_classification/decision \
  -d '{
    "input": {
      "user": "spatel",
      "user_groups": ["security-ops"],
      "data_classification": "pii"
    }
  }' | python3 -m json.tool
```

**Expected:** `"allow": false` (spatel is only in security-ops, not db-admins)
**Actual:** `"allow": true` — **BUG! PII is exposed.**

**Test 2 — Confidential access for app developer (should be DENIED):**

```bash
curl -s http://central.zta.lab:8181/v1/data/zta/data_classification/decision \
  -d '{
    "input": {
      "user": "appdev",
      "user_groups": ["app-deployers"],
      "data_classification": "confidential"
    }
  }' | python3 -m json.tool
```

**Expected:** `"allow": false` (appdev is not in db-admins)
**Actual:** `"allow": true` — **BUG! Confidential data exposed to developers.**

**Test 3 — PII access for app deployer (should be DENIED):**

```bash
curl -s http://central.zta.lab:8181/v1/data/zta/data_classification/decision \
  -d '{
    "input": {
      "user": "appdev",
      "user_groups": ["app-deployers"],
      "data_classification": "pii"
    }
  }' | python3 -m json.tool
```

**Expected:** `"allow": false`
**Actual:** `"allow": true` — **BUG! App deployers can access PII.**

---

## Exercise 3B.2 — Read the Rego Source

Fetch the current policy from OPA:

```bash
curl -s http://central.zta.lab:8181/v1/policies | python3 -m json.tool
```

Find the `zta.data_classification` policy in the output. Or read it directly
from the host:

```bash
ssh rhel@central.zta.lab
sudo cat /opt/opa/policies/data_classification.rego
```

**Find the three bugs:**

1. **BUG 1 (PII):** The PII access rules use two separate `allow if` blocks
   (OR logic) instead of one block with both conditions (AND logic). Any user
   in security-ops OR db-admins gets PII access.

2. **BUG 2 (Confidential):** The confidential rule checks for `app-deployers`
   instead of `db-admins`.

3. **BUG 3 (Internal):** One of the internal rules is missing the
   `input.data_classification == "internal"` check, which means app-deployers
   match *any* classification level.

---

## Exercise 3B.3 — Fix the Policy

SSH to central and edit the policy file:

```bash
ssh rhel@central.zta.lab
sudo vi /opt/opa/policies/data_classification.rego
```

**Fix 1 — PII rule (combine into single `allow if` block):**

Replace the two separate PII rules:
```rego
# WRONG — OR logic (two separate rules)
allow if {
    input.data_classification == "pii"
    user_in_group("security-ops")
}
allow if {
    input.data_classification == "pii"
    user_in_group("db-admins")
}
```

With one combined rule:
```rego
# CORRECT — AND logic (single rule, both conditions required)
allow if {
    input.data_classification == "pii"
    user_in_group("security-ops")
    user_in_group("db-admins")
}
```

**Fix 2 — Confidential rule (correct the group name):**

```rego
# WRONG
allow if {
    input.data_classification == "confidential"
    user_in_group("app-deployers")
}

# CORRECT
allow if {
    input.data_classification == "confidential"
    user_in_group("db-admins")
}
```

**Fix 3 — Internal rule (add the missing classification check):**

```rego
# WRONG — matches any classification
allow if {
    user_in_group("app-deployers")
}

# CORRECT — only matches "internal"
allow if {
    input.data_classification == "internal"
    user_in_group("app-deployers")
}
```

**Reload OPA:**

```bash
sudo podman restart opa
```

---

## Exercise 3B.4 — Verify the Fix

Re-run all three tests:

```bash
# Test 1: PII + security-ops only → should be DENIED
curl -s http://central.zta.lab:8181/v1/data/zta/data_classification/decision \
  -d '{"input": {"user": "spatel", "user_groups": ["security-ops"], "data_classification": "pii"}}' \
  | python3 -m json.tool
# Expected: "allow": false ✓

# Test 2: Confidential + app-deployers → should be DENIED
curl -s http://central.zta.lab:8181/v1/data/zta/data_classification/decision \
  -d '{"input": {"user": "appdev", "user_groups": ["app-deployers"], "data_classification": "confidential"}}' \
  | python3 -m json.tool
# Expected: "allow": false ✓

# Test 3: PII + app-deployers → should be DENIED
curl -s http://central.zta.lab:8181/v1/data/zta/data_classification/decision \
  -d '{"input": {"user": "appdev", "user_groups": ["app-deployers"], "data_classification": "pii"}}' \
  | python3 -m json.tool
# Expected: "allow": false ✓

# Test 4: PII + BOTH groups → should be ALLOWED
curl -s http://central.zta.lab:8181/v1/data/zta/data_classification/decision \
  -d '{"input": {"user": "nobrien", "user_groups": ["db-admins", "security-ops"], "data_classification": "pii"}}' \
  | python3 -m json.tool
# Expected: "allow": true ✓ (nobrien would need both groups)
```

---

## Exercise 3B.5 — Bonus: Add a Time-of-Day Restriction

OPA can access the current time. Add a rule that only allows PII access
during business hours (08:00–18:00 UTC):

```rego
import data.time

allow if {
    input.data_classification == "pii"
    user_in_group("security-ops")
    user_in_group("db-admins")
    hour := time.clock(time.now_ns())[0]
    hour >= 8
    hour < 18
}
```

Reload OPA and test. If it's outside business hours, even a user with both
groups will be denied PII access.

---

## Section 3B Discussion Points

- What is the risk of deploying an overly permissive policy? (Data breach
  before anyone notices)
- How would you test OPA policies in CI/CD before deploying? (OPA has a
  built-in `opa test` framework)
- Why is deny-by-default safer than allow-by-default? (A missing rule blocks
  access instead of granting it)
- Could this policy be integrated into the AAP gateway? (Yes — add a
  classification check to `aap.gateway`)

## Section 3B Validation Checklist

- [ ] PII access denied for security-ops-only user (BUG 1 fixed)
- [ ] Confidential access denied for app-deployers (BUG 2 fixed)
- [ ] Internal rule only matches "internal" classification (BUG 3 fixed)
- [ ] PII access granted for user in BOTH security-ops AND db-admins
- [ ] Public access works for any authenticated user
- [ ] OPA restarts cleanly after policy edit
