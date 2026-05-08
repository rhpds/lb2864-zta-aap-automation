# Section 2 — Deploy Application with Short-Lived Database Credentials

**AsciiDoc lab:** [`lab/index.adoc`](lab/index.adoc)

> **2-Hour Workshop Delivery Guide**
>
> | Exercise | Status | Est. Time |
> |----------|--------|-----------|
> | 2.1 — Create the Job Templates | **Core** | 3 min |
> | 2.2 — Build the Deployment Workflow | **Core** | 5 min |
> | 2.3 — Attempt Deployment as Wrong User (DENIED) | **Core** | 5 min |
> | 2.4 — Examine the Policy | **Core** | 5 min |
> | 2.5 — Deploy as the Correct User (ALLOWED) | **Core** | 5 min |
> | 2.6 — Observe Credential Expiry | **Core** | 5 min |
> | 2.7 — Set Up Credential Rotation | **Extended** | 5 min |
> | 2.8 — Wire Up Gitea Webhook | **Extended** | 10 min |
> | 2.9 — Firewall Micro-segmentation Debugging | **Extended** | 20 min |
> | 2.10 — Vault Policy Path Debugging | **Extended** | 20 min |
> | 2.11 — SELinux Container Context Debugging | **Extended** | 20 min |
>
> For a **2-hour workshop**, complete exercises **2.1–2.6** (~30 min).
> Exercises 2.7–2.8 are optional enrichment. Exercises 2.9–2.11 are
> hands-on break/fix labs for longer formats only.

## Objective

Deploy the **Global Telemetry Platform** application using short-lived database
credentials from Vault. First, attempt the deployment as the **wrong user** —
OPA denies the request. Then examine the policy, use the correct user (or fix
the group membership), and successfully deploy.

## Zero Trust Principles

| Principle | How This Section Demonstrates It |
|-----------|----------------------------------|
| **Deny by default** | OPA blocks the deployment until the user is explicitly authorised |
| **Least privilege** | Vault DB credentials grant only SELECT/INSERT/UPDATE |
| **Short-lived credentials** | Dynamic DB user expires after 5-minute TTL |
| **Just-in-time access** | Credentials only created when the deployment runs |
| **Micro-segmentation** | Arista ACL restricts database access to the app server only |

## Architecture

```
  ┌─ AAP Workflow ─────────────────────────────────────┐
  │                                                    │
  │  Step 1: Check OPA Policy                          │
  │    └─ Is this user in 'app-deployers'?             │
  │    └─ DENIED → job stops                           │
  │    └─ ALLOWED → continue                           │
  │                                                    │
  │  Step 2: Get Dynamic DB Credential from Vault      │
  │    └─ vault read database/creds/ztaapp-short-lived │
  │    └─ TTL: 5 minutes, auto-revoked                 │
  │                                                    │
  │  Step 3: Configure ACL (app → db only)             │
  │    └─ Arista ACL: PERMIT app → db:5432             │
  │    └─            DENY   * → db:5432                │
  │                                                    │
  │  Step 4: Deploy Application with Credentials       │
  │    └─ Push creds to app, restart GTP service       │
  │                                                    │
  └────────────────────────────────────────────────────┘
```

---

## Exercise 2.1 — Create the Job Templates

All templates use **Inventory:** `ZTA Lab Inventory` and **Credentials:** `ZTA Machine Credential`.

| Template Name | Playbook | Extra Credentials |
|---------------|----------|-------------------|
| Check DB Access Policy | `section2/playbooks/check-db-policy.yml` | — |
| Create DB Credential | `section2/playbooks/create-db-credential.yml` | — |
| Configure DB Access List | `section2/playbooks/configure-db-access.yml` | `ZTA Arista Credential` |
| Deploy Application | `section2/playbooks/deploy-application.yml` | — |
| Rotate DB Credentials | `section2/playbooks/rotate-credentials.yml` | — |

---

## Exercise 2.2 — Build the Deployment Workflow

Create a **Workflow Template** named `Deploy Application Pipeline`:

```
Check DB Access Policy ──(success)──► Create DB Credential ──(success)──► Configure DB Access List ──(success)──► Deploy Application
        │
     (failure)
        │
        ▼
   [Access Denied]
```

---

## Exercise 2.3 — Attempt Deployment as the Wrong User (DENIED)

1. Log into AAP as `neteng` (a network engineer — **not** in `app-deployers`)
2. Launch the **Deploy Application Pipeline** workflow
3. The first step (**Check DB Access Policy**) queries OPA:

```
OPA Database Access Decision:
  User:       neteng
  Groups:     (none)
  Database:   ztaapp
  Decision:   DENIED
  Reason:     user 'neteng' is not authorised to request database credentials

ACCESS DENIED by OPA policy.
```

4. The workflow stops — Vault is never contacted, no credentials are issued,
   the application is not touched

**Key takeaway:** OPA denied the request before any secret was generated.
The wrong user never gets anywhere near the database.

---

## Exercise 2.4 — Examine the Policy

Look at the OPA policy that blocked the request. Open
`opa-policies/db_access.rego` (or query OPA directly):

The `zta.db_access` policy checks:
- Is the user in the `app-deployers` group?
- Is the target database `ztaapp`?
- Are the requested permissions within bounds (SELECT, INSERT, UPDATE)?

**Fix option A** — Use the correct user:
Log in as `appdev` (who is in `app-deployers`)

**Fix option B** — Add the user to the group in IdM:
```bash
ipa group-add-member app-deployers --users=neteng
```

---

## Exercise 2.5 — Deploy as the Correct User (ALLOWED)

1. Log into AAP as `appdev` (member of `app-deployers`)
2. Launch the **Deploy Application Pipeline** workflow
3. Watch all four steps complete:

**Step 1 — OPA Policy Check:**
```
Decision:   ALLOWED
OPA policy check passed — proceeding with credential issuance
```

**Step 2 — Vault Dynamic Credentials:**
```
Dynamic database credentials created:
  Username: v-root-ztaapp-s-abc123def
  TTL:      300s
  Lease:    database/creds/ztaapp-short-lived/...
```

**Step 3 — Network ACL:**
```
Network micro-segmentation applied on ceos2:
  ACL: ZTA-APP-TO-DB
  PERMIT: 10.20.0.10 → 10.30.0.10:5432
  DENY:   any → 10.30.0.10:5432
```

**Step 4 — Application Deployed:**
```
Application deployed successfully:
  URL:     http://app.zta.lab:8081
  Health:  ok
  DB User: v-root-ztaapp-s-abc123def (dynamic, short-lived)
```

4. Open `http://app.zta.lab:8081` in your browser — the **Global Telemetry
   Platform** dashboard should be live

---

## Exercise 2.6 — Observe Credential Expiry

1. SSH into the database container and list PostgreSQL users:
   ```bash
   ssh -p 2022 rhel@central.zta.lab
   sudo -u postgres psql -c "\du"
   ```
   You should see the Vault-generated user (e.g. `v-root-ztaapp-s-...`)

2. Wait 5 minutes (the TTL) and check again:
   ```bash
   sudo -u postgres psql -c "\du"
   ```
   The user is **gone** — Vault automatically revoked it

3. Check the application health:
   ```
   curl http://app.zta.lab:8081/health
   ```
   The app should now report unhealthy — it lost its database connection

This demonstrates Zero Trust: credentials are ephemeral. If not rotated,
access is automatically removed.

---

---

# Extended Exercises (Longer Formats Only)

## Exercise 2.7 — Set Up Credential Rotation (Optional)

1. Navigate to the **Rotate DB Credentials** template
2. Click **Schedules → Add**
3. Name: `Rotate every 5 minutes`
4. Set frequency to every 5 minutes

The rotation job revokes old credentials, issues new ones from Vault, and
restarts the application — keeping it healthy continuously.

---

## Exercise 2.8 — Wire Up Gitea Webhook (Optional)

1. Edit the `Deploy Application Pipeline` workflow template
2. Enable **Webhook** → select **Gitea**
3. Copy the webhook URL and key
4. In Gitea (`http://gitea.zta.lab:3000`): add a webhook pointing to AAP
5. Push a commit — the pipeline triggers automatically

---

## Discussion Points

- What happened when `neteng` tried to deploy? Did they ever see credentials?
- Why does OPA check happen **before** Vault, not after?
- What happens to the application when credentials expire?
- Why is the Arista ACL important if credentials are already short-lived?
- If you added `neteng` to `app-deployers` in IdM, what changes?

---

## Validation Checklist

- [ ] Wrong user (`neteng`) is denied by OPA — workflow stops at step 1
- [ ] Correct user (`appdev`) passes OPA — full workflow completes
- [ ] Vault generates dynamic PostgreSQL credentials with unique username
- [ ] Arista ACL on ceos2 permits only `10.20.0.10` → `10.30.0.10:5432`
- [ ] Application dashboard loads at `http://app.zta.lab:8081`
- [ ] Credentials disappear from PostgreSQL after TTL expires
- [ ] Application loses DB access when credentials expire

---

# Exercise 2.9 — Firewall Micro-segmentation Debugging (Hands-On)

## The Scenario

The application was working after the deployment, but now the health check
fails. Someone (or a configuration drift) removed the PostgreSQL port from
the firewall on the database host.

> **Instructor:** Run `ansible-playbook section2/playbooks/break-firewall.yml`

## Step 1 — Observe the Failure

```bash
curl http://app.zta.lab:8081/health
# Expected: unhealthy or connection error to database
```

The app is running, but it cannot reach PostgreSQL. Is it a credential
problem? A network problem? A firewall problem?

## Step 2 — Narrow Down the Problem

Check whether the application itself is running:

```bash
curl http://app.zta.lab:8081
# If you get a response (even an error page), the app container is up
```

Try to reach PostgreSQL directly from the app container:

```bash
ssh -p 2023 rhel@central.zta.lab    # SSH to app container
nc -zv 10.30.0.10 5432              # Test TCP to DB
# Expected: Connection refused or timeout
```

The database process is running, but the connection is blocked. This points
to a firewall issue.

## Step 3 — Diagnose the Firewall

SSH into the database container:

```bash
ssh -p 2022 rhel@central.zta.lab    # SSH to DB container
```

Check firewall rules:

```bash
sudo firewall-cmd --list-all
```

Look at the open ports — **5432/tcp is missing**.

```bash
sudo firewall-cmd --list-ports
# Notice: 5432/tcp is not listed
```

## Step 4 — Fix the Firewall

```bash
sudo firewall-cmd --add-port=5432/tcp --permanent
sudo firewall-cmd --reload

# Verify
sudo firewall-cmd --list-ports
# Should now include: 5432/tcp
```

## Step 5 — Verify the Fix

```bash
# From the app container (or from your terminal):
curl http://app.zta.lab:8081/health
# Expected: healthy
```

## ZTA Lesson

Micro-segmentation works by explicitly opening only the ports needed for
each data flow. If a rule is missing, legitimate traffic is blocked. When
troubleshooting a broken application in a ZTA environment, always check
**firewalls at every hop** — not just the application and its credentials.

Understanding the data path (`app 10.20.0.10` → `db 10.30.0.10:5432`) is
essential for diagnosing connectivity issues.

## Firewall Debugging Validation

- [ ] App health check fails after break playbook runs
- [ ] `firewall-cmd --list-ports` shows 5432/tcp is missing
- [ ] Adding the port restores connectivity
- [ ] App health check passes after fix

---

# Exercise 2.10 — Vault Policy Path Debugging (Hands-On)

## The Scenario

The `app-deployer` Vault policy has been misconfigured — someone changed the
database credential path to a role that doesn't exist. The deployment workflow
passes OPA but **fails at Vault with 403 permission denied**.

> **Instructor:** Run `ansible-playbook section2/playbooks/break-vault-policy.yml`

## Step 1 — Observe the Failure

1. Log into AAP as `appdev`
2. Launch the **Deploy Application Pipeline** workflow
3. **Check DB Access Policy** passes (OPA says ALLOWED)
4. **Create DB Credential** fails with a Vault error:
   ```
   FAILED! => {"msg": "permission denied"}
   ```

The OPA policy check passed — the user IS authorised. But Vault refuses to
issue credentials. Why?

## Step 2 — Investigate the Vault Policy

SSH to the Vault server and read the current policy:

```bash
export VAULT_ADDR=http://vault.zta.lab:8200
vault login -method=userpass username=admin password=ansible123!

# Read the app-deployer policy
vault policy read app-deployer
```

You'll see:
```hcl
path "database/creds/ztaapp-readonly" {
  capabilities = ["read"]
}
```

Now check what database roles actually exist:

```bash
vault list database/roles
```

Output:
```
Keys
----
ztaapp-short-lived
```

**The policy path `ztaapp-readonly` doesn't match the actual role
`ztaapp-short-lived`.** One wrong word in the path = complete access denial.

## Step 3 — Fix the Policy

```bash
vault policy write app-deployer - <<'EOF'
path "database/creds/ztaapp-short-lived" {
  capabilities = ["read"]
}
path "secret/data/network/*" {
  capabilities = ["read"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
EOF
```

Verify:
```bash
vault policy read app-deployer
# Should now show: database/creds/ztaapp-short-lived
```

## Step 4 — Retry the Deployment

Go back to AAP and re-launch the **Deploy Application Pipeline**. All four
steps should complete successfully.

## ZTA Lesson

Least privilege in Vault means **exact path scoping**. The policy must match
the precise secrets engine path. This is a common operational issue — a typo
in a Vault policy can block an entire deployment pipeline while the OPA
policy layer thinks everything is fine. Each layer has its own access model.

## Vault Policy Debugging Validation

- [ ] Deployment fails at "Create DB Credential" with 403
- [ ] `vault policy read app-deployer` shows the wrong path
- [ ] `vault list database/roles` shows the correct role name
- [ ] Policy fix resolves the path mismatch
- [ ] Deployment succeeds after policy fix

---

# Exercise 2.11 — SELinux Container Context Debugging (Hands-On)

## The Scenario

The application container suddenly fails after a routine operation reset the
SELinux file context on its data directory. The container process cannot read
or write files, and the health check fails. But the error messages are
cryptic — you need to use SELinux audit tools to find the root cause.

> **Instructor:** Run `ansible-playbook section2/playbooks/break-selinux.yml`

## Duration: ~20 minutes

---

## Step 1 — Observe the Failure

```bash
curl http://app.zta.lab:8081/health
# Expected: connection refused or error
```

Check the application service status:

```bash
ssh -p 2023 rhel@central.zta.lab
sudo systemctl status ztaapp
# May show: failed, inactive, or active with errors in the logs
```

Check the application logs:

```bash
sudo journalctl -u ztaapp --no-pager -n 20
```

You may see "Permission denied" errors when the app tries to access files
in its data directory. But why? The file exists, the user is correct...

---

## Step 2 — Check SELinux Status

```bash
# Is SELinux enforcing?
getenforce
# Expected: Enforcing

# Check the file context on the app directory
ls -laZ /opt/ztaapp/
```

You'll see something like:
```
drwxr-xr-x. root root unconfined_u:object_r:default_t:s0 .
```

The context is `default_t` — this is **wrong** for a directory accessed by
a container. Container processes run in a confined domain and can only
access files labelled `container_file_t`.

---

## Step 3 — Find the SELinux Denial

Use the audit tools to see the exact denial:

```bash
# Search for recent AVC (Access Vector Cache) denials
sudo ausearch -m avc -ts recent
```

You'll see entries like:
```
type=AVC msg=audit(...): avc:  denied  { read } for  pid=... 
  comm="python3" name="env" dev="..." ino=... 
  scontext=system_u:system_r:container_t:s0:... 
  tcontext=unconfined_u:object_r:default_t:s0 
  tclass=file permissive=0
```

Key fields:
- `denied { read }` — the operation that was blocked
- `scontext=...container_t...` — the process context (container)
- `tcontext=...default_t...` — the file context (**wrong**)
- `tclass=file` — what type of object was accessed

Use `audit2why` for a human-readable explanation:

```bash
sudo ausearch -m avc -ts recent | audit2why
```

This tells you exactly what SELinux expects: the file should have
`container_file_t` context.

---

## Step 4 — Fix the SELinux Context

```bash
# Apply the correct context
sudo chcon -R -t container_file_t /opt/ztaapp

# Verify the context changed
ls -laZ /opt/ztaapp/
# Expected: container_file_t on all files
```

---

## Step 5 — Restart and Verify

```bash
sudo systemctl restart ztaapp

# Wait a moment, then check health
curl http://app.zta.lab:8081/health
# Expected: healthy
```

---

## Step 6 — Understand Why This Matters

In Zero Trust on RHEL, **SELinux is never disabled**. It provides Mandatory
Access Control — a kernel-level security boundary that limits what processes
can access, even if they are running as root.

For containers:
- Container processes run in the `container_t` SELinux domain
- They can ONLY access files labelled `container_file_t`
- Volumes mounted into containers must have this label
- `podman` typically handles this with the `:Z` mount flag
- Manual file operations (cp, mv, restore from backup) can reset the context

Common tools:
- `ls -Z` — show SELinux file contexts
- `ausearch -m avc` — find SELinux denials in the audit log
- `audit2why` — explain why a denial occurred
- `chcon -t container_file_t` — change the file context
- `semanage fcontext` + `restorecon` — make the change permanent
- `getenforce` / `setenforce` — check/set SELinux mode (never use `setenforce 0` in ZTA!)

---

## SELinux Discussion Points

- Why is "just disable SELinux" not acceptable in a Zero Trust environment?
- What is the difference between `chcon` (temporary) and `semanage fcontext`
  + `restorecon` (permanent)?
- How would you ensure container volumes always get the correct context?
- What other SELinux contexts might you encounter in this lab? (Hint:
  `deploy-wazuh.yml` uses `chcon -t container_file_t` on Wazuh data dirs)

## SELinux Debugging Validation Checklist

- [ ] Application fails with permission errors after context reset
- [ ] `ls -Z` shows `default_t` on the app data directory
- [ ] `ausearch -m avc` reveals the exact SELinux denial
- [ ] `audit2why` explains the required context
- [ ] `chcon -R -t container_file_t` fixes the file context
- [ ] Application restarts successfully after context fix
- [ ] `getenforce` confirms SELinux is still in Enforcing mode
