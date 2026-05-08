# Section 6 — SSH Lockdown & Break-Glass Recovery

**AsciiDoc lab:** [`lab/index.adoc`](lab/index.adoc)

## Objective

Apply defence-in-depth SSH lockdown layers and then **recover from a
misconfiguration that locks AAP out of managed hosts**. This section moves
beyond clicking "Launch" — participants work directly with `firewalld`, IdM
HBAC rules, Vault policies, and the break-glass recovery path.

## Zero Trust Principles

| Principle | How This Section Demonstrates It |
|-----------|----------------------------------|
| **Defence in depth** | Four independent layers must ALL be bypassed to reach a host |
| **Assume breach** | Even if one layer fails, others still protect |
| **Break-glass recovery** | Every lockdown needs a tested escape hatch |
| **Least privilege** | Only AAP's AppRole can generate credentials after lockdown |
| **Audit trail** | Splunk detects and logs every bypass attempt |

## Prerequisites

- Sections 1–5 completed (all services healthy, app deployed)
- Console or out-of-band access available (in case of total lockout)
- SSH lockdown playbooks have NOT yet been run

---

## Exercise 6.1 — Apply Firewall Lockdown (Layer 1)

**Run the firewall lockdown playbook from the AAP controller (or CLI):**

```bash
ansible-playbook -i inventory/hosts.ini setup/ssh_lockdown/lockdown-firewall.yml
```

**Test from your workstation:**

```bash
ssh ztauser@app.zta.lab
# Expected: Connection refused
```

**Test from the AAP controller (control):**

```bash
ssh rhel@control.zta.lab
ssh rhel@app.zta.lab
# Expected: Connection succeeds (AAP controller IP is allowed)
```

> **ZTA Lesson:** The firewall is the first gate. Only known, trusted source
> IPs can even reach port 22. Every other connection is refused at the
> network level — before authentication is even attempted.

**Discuss:**
- Why is `central` also allowed? (Answer: it's the management/break-glass host)
- What happens if the AAP controller's IP changes?

---

## Exercise 6.2 — Apply IdM HBAC Lockdown (Layer 2)

**Run the HBAC lockdown playbook:**

```bash
ansible-playbook -i inventory/hosts.ini setup/ssh_lockdown/lockdown-idm-hbac.yml
```

**Test as an unauthorised IdM user (from central):**

```bash
ssh neteng@app.zta.lab
# Expected: Permission denied (HBAC denies login)
```

**Diagnose with `ipa hbactest`:**

```bash
kinit admin
ipa hbactest --user=neteng --host=app.zta.lab --service=sshd
# Expected: Access denied

ipa hbactest --user=aap-service --host=app.zta.lab --service=sshd
# Expected: Access granted (matched rule: allow_aap_automation)

ipa hbactest --user=ztauser --host=app.zta.lab --service=sshd
# Expected: Access granted (matched rule: allow_breakglass)
```

> **ZTA Lesson:** Even with network access (Layer 1 passed), IdM HBAC
> controls *which users* can log in *to which hosts*. This is identity-driven
> access at the host level.

**Discuss:**
- What is the difference between HBAC and sudo rules?
- Why does the local `rhel` user bypass HBAC? (Answer: HBAC is enforced by
  SSSD, which only handles IdM users. Local users use PAM directly.)

---

## Exercise 6.3 — Simulate a Lockout (THE BREAKAGE)

The instructor applies a misconfiguration that **accidentally removes the
AAP service account from the HBAC rule**.

> **Instructor:** Run `ansible-playbook section6/playbooks/break-hbac.yml`

**Observe the failure:**

1. Go to the **automation controller** (AAP 2.6) and launch **any** job template (e.g., "Verify ZTA Services")
2. The job **fails** with an SSH authentication error:
   ```
   UNREACHABLE! => {"msg": "Failed to connect to the host via ssh:
   Permission denied (publickey,gssapi-keyex,gssapi-with-mic,password)"}
   ```
3. Every job template you try will fail the same way

**The AAP service account can no longer SSH to any managed host.**

---

## Exercise 6.4 — Break-Glass Recovery

You must diagnose and fix the problem using the break-glass path.

**Step 1 — SSH to central as a breakglass-admins user:**

```bash
ssh ztauser@central.zta.lab
# This works because ztauser is in breakglass-admins and central is allowed
```

**Step 2 — Authenticate to IdM:**

```bash
kinit admin
```

**Step 3 — Diagnose the HBAC problem:**

```bash
# Test whether aap-service can access a managed host
ipa hbactest --user=aap-service --host=app.zta.lab --service=sshd
# Expected: Access denied — aap-service is NOT in any matching rule

# Check the HBAC rule that should grant access
ipa hbacrule-show allow_aap_automation --all
# Notice: aap-service is missing from the user list

# Compare with a working rule
ipa hbacrule-show allow_breakglass --all
# Notice: breakglass-admins group is present
```

**Step 4 — Fix the HBAC rule:**

```bash
ipa hbacrule-add-user allow_aap_automation --users=aap-service
```

**Step 5 — Verify the fix:**

```bash
ipa hbactest --user=aap-service --host=app.zta.lab --service=sshd
# Expected: Access granted (matched rule: allow_aap_automation)
```

**Step 6 — Go back to AAP and re-launch the job template:**

The job should now succeed.

---

## Exercise 6.5 — Vault Policy Lockdown (Layer 3)

**Run the Vault lockdown playbook:**

```bash
ansible-playbook -i inventory/hosts.ini setup/ssh_lockdown/lockdown-vault-policies.yml
```

**Note the AppRole Role ID and Secret ID from the output.**

**Test as a human operator:**

```bash
export VAULT_ADDR=http://vault.zta.lab:8200
vault login -method=userpass username=admin password=ansible123!

# Try to sign an SSH certificate (should FAIL)
ssh-keygen -t rsa -b 2048 -f /tmp/test-key -N '' -q
vault write ssh/sign/ssh-signer public_key=@/tmp/test-key.pub
# Expected: Error — permission denied

# Try to read a KV secret (should SUCCEED — read-only is allowed)
vault kv get secret/network/arista
# Expected: Success — human-readonly policy allows reads
```

> **ZTA Lesson:** Humans can inspect and troubleshoot but cannot sign SSH
> certificates or generate DB credentials. Only AAP's AppRole can request
> signed certificates. This is machine-to-machine least privilege.

**Discuss:**
- Why use AppRole instead of userpass for AAP?
- What if an attacker steals the AppRole Secret ID?
- How would you rotate the AppRole credentials?

---

## Exercise 6.6 — Apply Splunk Bypass Detection (Layer 4)

**Run the bypass detection playbook:**

```bash
ansible-playbook -i inventory/hosts.ini setup/ssh_lockdown/lockdown-splunk-bypass.yml
```

This creates two Splunk saved searches that monitor for SSH bypass attempts:
- `ZTA: SSH Bypass — Login from Non-AAP Source` (successful SSH from untrusted IP)
- `ZTA: SSH Bypass — Repeated HBAC Denials` (repeated HBAC-denied logins = recon)

Both are configured with webhook alert actions pointing to EDA.

**Test bypass detection:**

```bash
# From central, try SSH as an unauthorized user
ssh neteng@app.zta.lab
# HBAC denies the login

# Check Splunk for the alert
# Navigate to http://central.zta.lab:8000
# Activity → Triggered Alerts
# Look for "ZTA: SSH Bypass — Repeated HBAC Denials"
```

You can also search directly:

```
index=main sourcetype=linux_secure "Permission denied" OR "not allowed"
| stats count by src_ip, user
| where count >= 3
```

> **ZTA Lesson:** Even when a login is denied, the attempt is detected and
> logged. Repeated attempts trigger escalated alerts that forward to EDA
> for automated response.

---

## Exercise 6.7 — Full Lockdown Verification

With all four layers active, verify the complete defence chain:

| Test | From | As | Expected |
|------|------|----|----------|
| SSH from workstation | workstation | ztauser | **Layer 1:** Connection refused |
| SSH from central | central | neteng | **Layer 2:** HBAC denied |
| Vault SSH cert signing | central | admin (human) | **Layer 3:** Permission denied |
| Launch AAP job | AAP UI | ztauser | **Success** (AAP is the only path) |

---

## Discussion Points

- What would happen if all four layers failed simultaneously?
- How do you test lockdown changes safely before applying to production?
- What audit trail exists for break-glass usage?
- How would you add time-limited break-glass access (auto-expire after 1 hour)?
- In production, would you add MFA to the break-glass path?

---

## Validation Checklist

- [ ] Layer 1: SSH from workstation is refused (firewall)
- [ ] Layer 2: SSH as `neteng` from central is denied (HBAC)
- [ ] Layer 2: `ipa hbactest` correctly identifies allowed/denied users
- [ ] Breakage: AAP jobs fail after `break-hbac.yml` runs
- [ ] Recovery: Participants fix HBAC via break-glass path
- [ ] Recovery: AAP jobs succeed after `ipa hbacrule-add-user` fix
- [ ] Layer 3: Human Vault login cannot sign SSH certificates
- [ ] Layer 3: Human Vault login CAN read KV secrets
- [ ] Layer 4: Splunk alerts fire on HBAC-denied SSH attempts
- [ ] Full chain: AAP is the only working path to managed hosts
