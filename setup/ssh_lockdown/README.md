# SSH Lockdown — Closing the Direct Access Bypass

> **Zero Trust Principle:** *If it's possible to bypass the PEP, the PEP isn't real.*

Without SSH lockdown, anyone with network access and valid credentials can SSH
directly to a managed host — bypassing AAP, OPA, and every policy check the
workshop demonstrates. These playbooks close that gap with four defence layers.

---

## Architecture

```
  User at workstation
       │
       ├──── ssh node01.zta.lab ────►  Layer 1: FIREWALL
       │                                   │
       │                                   └── CONNECTION REFUSED
       │                                       (only AAP + central allowed)
       │
       ├──── ssh from control ──────►  Layer 2: IdM HBAC
       │     (as neteng)                   │
       │                                   └── LOGIN DENIED
       │                                       (neteng not in HBAC rule)
       │
       ├──── vault write ssh/sign ──►  Layer 3: VAULT POLICY
       │     (as human/userpass)           │
       │                                   └── PERMISSION DENIED
       │                                       (human-readonly policy)
       │
       └──── (any bypass succeeds) ─►  Layer 4: WAZUH + EDA
                                           │
                                           └── ALERT → EDA → AAP
                                               (automated incident response)
```

## Layers

| Layer | Control | What it does | Playbook |
|-------|---------|-------------|----------|
| **1** | Firewall (`firewalld`) | Only allows SSH from AAP controller (192.168.1.10) and central (192.168.1.11) | `lockdown-firewall.yml` |
| **2** | IdM HBAC | Only `aap-service` and `breakglass-admins` IdM users can log in via SSH | `lockdown-idm-hbac.yml` |
| **3** | Vault Policy | Only AAP's AppRole can sign SSH certificates and generate DB credentials; humans get read-only access | `lockdown-vault-policies.yml` |
| **4** | Wazuh Rules | Detects SSH from non-AAP sources, HBAC denials, repeated recon — forwards to EDA | `lockdown-wazuh-bypass.yml` |

## Prerequisites

Run these **before** applying lockdown:

1. All hosts enrolled as IdM clients (`setup/enroll-idm-clients.yml`)
2. IdM users and groups created (`setup/configure-idm-users.yml`)
3. Vault configured with secrets engines (`setup/configure-vault.yml`)
4. Vault SSH CA trust configured (`setup/configure-vault-ssh.yml`)
5. Wazuh → EDA integration active (`setup/configure-wazuh-eda.yml`)
6. Console / out-of-band access available (in case of lockout)

## Usage

### Apply all layers at once

```bash
cd /path/to/zta-workshop-aap
ansible-playbook -i inventory/hosts.ini setup/ssh_lockdown/lockdown-all.yml
```

### Apply individual layers

```bash
# Layer 1 only
ansible-playbook -i inventory/hosts.ini setup/ssh_lockdown/lockdown-firewall.yml

# Layer 2 only
ansible-playbook -i inventory/hosts.ini setup/ssh_lockdown/lockdown-idm-hbac.yml

# Layer 3 only (requires VAULT_TOKEN env var)
ansible-playbook -i inventory/hosts.ini setup/ssh_lockdown/lockdown-vault-policies.yml

# Layer 4 only
ansible-playbook -i inventory/hosts.ini setup/ssh_lockdown/lockdown-wazuh-bypass.yml
```

## After Lockdown

### Configure AAP Machine Credential

Replace the current `rhel` machine credential with:

| Field | Value |
|-------|-------|
| **Username** | `aap-service` |
| **Password** | `ansible123!` |
| **Privilege Escalation** | `sudo` |
| **Privilege Escalation Password** | `ansible123!` |

### Configure AAP credentials after Vault lockdown (AppRole)

`lockdown-vault-policies.yml` creates the Vault AppRole named **`vault_lockdown_approle_name`** (default **`aap-automation`**) in [inventory/group_vars/all.yml](../../inventory/group_vars/all.yml) and prints **Role ID** and **Secret ID**. After lockdown, **userpass** `admin` is limited to **human-readonly** and cannot sign SSH certificates or read dynamic database credentials.

Apply the lockdown output to every AAP credential that must perform those operations:

1. **ZTA Vault Credential** (`HashiCorp Vault Secret Lookup`) — switch **Auth Method** to **AppRole** and use the Role ID and Secret ID from the lockdown summary (same automation identity as below). This restores KV and dynamic secret access for jobs that depended on the old admin userpass token.
2. **ZTA Vault SSH Credential** (`HashiCorp Vault Signed SSH`) — set **Role ID** and **Secret ID** to the **same** `aap-automation` values (or keep the pre-lockdown **`ssh-client`** AppRole if you still use it and its policies remain valid). Both AppRoles are independent Vault roles; using **`aap-automation`** everywhere avoids maintaining two automation identities.

| Field | Value |
|-------|-------|
| **Vault Server URL** | `http://vault.zta.lab:8200` (match your lab; TLS if configured) |
| **Auth Method** | AppRole |
| **Role ID** | *(from `lockdown-vault-policies.yml` output)* |
| **Secret ID** | *(from `lockdown-vault-policies.yml` output)* |

Pre-lockdown, **ZTA Vault SSH Credential** is created by `setup/configure-aap-credentials.yml` using **`ssh_approle_name`** / **`ssh_approle_policies`** (default **`ssh-client`** + `ssh-access`). Changing those variables requires re-running that playbook (`--tags vault-ssh`) and refreshing the controller credential. See **Vault AppRole naming and impact** in [docs/deployment-guide.md](../../docs/deployment-guide.md).

### Test the lockdown

```bash
# From your workstation (should FAIL — Layer 1)
ssh ztauser@app.zta.lab
# → Connection refused

# From central as neteng (should FAIL — Layer 2)
ssh neteng@app.zta.lab
# → Permission denied (HBAC)

# From Vault CLI as admin (should FAIL — Layer 3)
vault login -method=userpass username=admin password=ansible123!
ssh-keygen -t rsa -b 2048 -f /tmp/test-key -N '' -q
vault write ssh/sign/ssh-signer public_key=@/tmp/test-key.pub
# → Permission denied

# From AAP (should SUCCEED — all layers pass)
# Launch any job template → works normally
```

## Rollback

### Layer 1 — Restore default SSH access

```bash
# On each managed host:
sudo firewall-cmd --add-service=ssh --permanent
sudo firewall-cmd --reload
```

### Layer 2 — Re-enable allow_all HBAC

```bash
# On central:
kinit admin
ipa hbacrule-enable allow_all
```

### Layer 3 — Restore admin Vault access

```bash
export VAULT_TOKEN=<root-token>
vault write auth/userpass/users/admin \
  password=ansible123! \
  policies=ssh-access,app-deployer,network-admin,patch-admin
```

### Layer 4 — Remove bypass rules

```bash
# On wazuh:
sudo rm /var/ossec/etc/rules/ssh_bypass_rules.xml
sudo systemctl restart wazuh-manager
```

## Key Design Decisions

**Why the local `rhel` user bypasses HBAC:**
HBAC is enforced by SSSD, which only handles IdM-authenticated users.
Local users authenticate via PAM directly. This is intentional — the `rhel`
local user serves as the break-glass account, controlled by the firewall
layer (only reachable from central).

**Why we keep central allowed in the firewall:**
Central runs the Ansible setup playbooks and serves as the management /
break-glass entry point. In production, this would be a hardened jump host
with MFA and session recording.

**Why AppRole instead of userpass for AAP:**
AppRole is designed for machine-to-machine authentication. It supports
automatic secret rotation, IP binding, and usage limits — none of which
are possible with userpass. This is the Vault-recommended pattern for CI/CD
and automation platforms.
