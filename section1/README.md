# Section 1 — Verify ZTA Components & AAP Integration

**AsciiDoc lab:** [`lab/index.adoc`](lab/index.adoc)

> **2-Hour Workshop Delivery Guide**
>
> | Exercise | Status | Est. Time |
> |----------|--------|-----------|
> | Prerequisite — LDAP + Policy as Code on controller (verify) | **Core** | 2 min |
> | 1.1 — Verify AAP credentials (Vault lookups) | **Core** | 5 min |
> | 1.2 — IdM LDAP (Authentication Methods UI) | **Core** | 5 min |
> | 1.3 — Configure Inventory & Project | **Core** | 5 min |
> | 1.4 — Create Job Templates | **Core** | 3 min |
> | 1.5 — Verify All ZTA Services | **Core** | 2 min |
> | 1.6 — Test Vault Dynamic Credentials | **Core** | 3 min |
> | 1.7 — Test Vault SSH Signed Certificates | **Core** | 3 min |
> | 1.8 — Test OPA Policy Decisions | **Core** | 2 min |
> | 1.9 — Certificate Trust Chain Debugging | **Extended** | 25 min |
>
> For a **2-hour workshop**, confirm the **LDAP + Policy as Code** prerequisite (below), then complete exercises **1.1–1.8** (~27–32 min).
> Skip exercise 1.9 unless you have extra time or are running a longer format.

## Objective

Connect Ansible Automation Platform to the Zero Trust infrastructure. Workshop
credentials are **pre-created** with `setup/configure-aap-credentials.yml`
(Vault lookups, NetBox, Vault Signed SSH). You **verify** those integrations,
then configure inventory, project, templates, and run health checks against
IdM, Vault, OPA, Netbox, and Gitea.

## Zero Trust Principles

| Principle | How This Section Demonstrates It |
|-----------|----------------------------------|
| **Never trust, always verify** | Every service health is checked, not assumed |
| **Short-lived credentials** | Vault dynamic DB credentials expire after TTL |
| **No standing access** | Vault SSH signed certificates replace static keys |
| **Least privilege** | Vault policies scope secrets to specific roles |
| **Policy-driven access** | OPA deny-by-default with explicit allow rules |

## Architecture

```
  ┌───────────────────────────────────────────────────┐
  │                 AAP Controller                     │
  │                                                   │
  │  Credentials (all Vault-sourced at runtime):      │
  │    - Machine    ← Vault KV: secret/machine/rhel   │
  │    - Arista     ← Vault KV: secret/network/arista │
  │    - Vault SSH  ← Vault AppRole: ssh/sign/*       │
  │    - NetBox     ← Custom type (env injection)     │
  │                                                   │
  │  Inventory:                                       │
  │    - Static or synced from Netbox                 │
  │                                                   │
  │  Templates:                                       │
  │    - Verify ZTA Services                          │
  │    - Test Vault Integration                       │
  │    - Test Vault SSH Certificates                  │
  │    - Test OPA Policy Check                        │
  └──────┬───────────┬──────────┬─────────────────────┘
         │           │          │
    ┌────▼───┐  ┌───▼────┐  ┌─▼──────────┐  ┌────────────┐
    │  IdM   │  │ Vault  │  │   OPA      │  │  Netbox    │
    │central │  │vault   │  │ central    │  │ netbox     │
    └────────┘  └────────┘  └────────────┘  └────────────┘
```

---

## Controller identity and Policy as Code (prerequisite)

Later sections assume the automation controller accepts **IdM users** for login and enforces **Policy as Code** (OPA gateway) before jobs run. In a typical lab build this is applied **during deployment** (Layer 7), not during Section 1 in the UI.

**Playbooks** (see [`docs/deployment-guide.md`](../docs/deployment-guide.md) — *Layer 7 — Policy*):

| Playbook | Purpose |
|----------|---------|
| `setup/configure-opa-base.yml` | Load OPA policies (including `aap.gateway`). |
| `setup/configure-aap-policy.yml` | Enable controller ↔ OPA (Policy as Code). |
| `setup/configure-aap-ldap.yml` | Controller **LDAP** authentication against IdM (LDAPS). |

Running **LDAP earlier** in setup is fine; Section 1 still asks you to **verify** both integrations so Sections 2–4 match the lab narrative.

### Verify LDAP (controller → IdM)

- **Goal:** Workshop users sign in at `https://control.zta.lab` with **IdM accounts** (e.g. `ztauser` / `ansible123!`), not only platform `admin`.
- **If login fails:** Complete **Exercise 1.2** (Authentication Methods UI), or confirm `configure-aap-ldap.yml` (legacy API) ran, IdM is reachable, and the controller trusts the IdM CA (e.g. after `setup/enroll-idm-clients.yml`). See [`HANDOFF.md`](../HANDOFF.md) (*LDAP: controller → IdM*) and the deployment guide.

### Verify Policy as Code (controller → OPA)

- **Goal:** Before a job runs, the controller can query OPA at `v1/data/aap/gateway/decision`. Sections 3–4 rely on this **outer ring**.
- **UI:** As platform **admin**, open **Settings** → **Policy** / **Open Policy Agent** / **Policy as Code** (label varies by patch). Values should match [*Manual Policy as Code (OPA gateway)*](../docs/deployment-guide.md#manual-policy-as-code-opa) in the deployment guide.
- **API:**

```bash
curl -sk -u "admin:ansible123!" \
  "https://control.zta.lab/api/controller/v2/settings/opa/" | python3 -m json.tool
```

Expect `OPA_ENABLED` and `OPA_PRE_ACTION_ENABLED` true; `OPA_POLICY_PATH` is `v1/data/aap/gateway/decision`; `OPA_URL` matches your lab OPA (typically `http://central.zta.lab:8181` per `inventory/group_vars/all.yml`).

If automation was skipped, use the **manual UI or API** steps in `docs/deployment-guide.md` Layer 7 or run `setup/configure-aap-policy.yml`.

---

## Exercise 1.1 — Verify AAP Credentials (Pre-configured, Vault-sourced)

**Instructor / automation:** Run `setup/configure-aap-credentials.yml` (with Vault
and NetBox already configured) so the controller has the workshop credential
set. In this exercise you **inspect** those credentials and confirm Vault still
holds the expected secrets — you do **not** recreate them in the UI.

In a Zero Trust environment, **machine and switch passwords are not stored in
AAP**. They are resolved from HashiCorp Vault at job runtime via **external
secret lookups**. The bootstrap **Vault lookup** credential (stored password in
AAP) and the **NetBox** API token are exceptions; **Vault Signed SSH** uses
AppRole, not the interactive userpass flow.

```
  Vault (single source of truth for KV secrets + SSH CA)
    │
    ├─→ ZTA Vault Credential         ← bootstrap (stored password in AAP)
    │     │
    │     ├─→ ZTA Machine Credential  ← password / become from KV at runtime
    │     │
    │     └─→ ZTA Arista Credential   ← username / password from KV at runtime
    │
    ├─→ ZTA Vault SSH Credential      ← AppRole → ephemeral signed SSH certs
    │
    └─→ ZTA NetBox Credential         ← API token in AAP (CMDB)
```

### Step 1 — Confirm Vault holds the secrets

From any host with the Vault CLI:

```bash
export VAULT_ADDR=http://vault.zta.lab:8200
vault login -method=userpass username=admin password=ansible123!

vault kv get secret/machine/rhel
# Expected: password, become_password (RHEL SSH / become)

vault kv get secret/network/arista
# Expected: username, password (Arista cEOS)

vault kv get secret/db/admin
# Expected: postgres credentials (later exercises)
```

> **ZTA Concept**: KV secrets used for lookups must exist before jobs run. If
> Vault is sealed or unreachable, lookups fail and jobs fail closed.

---

### Step 2 — Confirm credentials in the automation controller

1. Log in to the **automation controller** (AAP 2.6).
2. Open **Credentials**.
3. Verify these objects exist (created by `setup/configure-aap-credentials.yml`):

| Name | Type | What to verify in **Edit** |
|------|------|------------------------------|
| `ZTA Vault Credential` | HashiCorp Vault Secret Lookup | Vault URL matches your lab; API version `v2`; bootstrap username/password present. |
| `ZTA Machine Credential` | Machine | User `rhel`, privilege escalation enabled; **Password** and **Privilege Escalation Password** use **external secret lookups** (key icon) via `ZTA Vault Credential` on `secret/data/machine/rhel` (`password` / `become_password`). |
| `ZTA Arista Credential` | Network | Username and password fields use lookups on `secret/data/network/arista`. |
| `ZTA NetBox Credential` | NetBox | URL and API token match your NetBox instance. |
| `ZTA Vault SSH Credential` | HashiCorp Vault Signed SSH | Present (AppRole to Vault; not userpass). |

4. Do not change paths or keys unless an instructor is troubleshooting.

> **Gitea:** `setup/configure-aap-credentials.yml` does **not** create **ZTA
> Gitea Credential**. Add or verify that credential when you configure the
> **ZTA Workshop** project (Exercise 1.3), if your Git URL requires authentication.

Proof that lookups work from AAP appears in **Exercise 1.5** (**Verify ZTA
Services**) and **Exercises 1.6–1.7**.

---

### Step 3 — NetBox credential type (troubleshooting only)

If the **NetBox** type or **ZTA NetBox Credential** is missing, create the type
first, then re-run `setup/configure-aap-credentials.yml` (or create the
credential to match the table in Exercise 1.3).

> The NetBox credential type injects `NETBOX_API` and `NETBOX_TOKEN` for
> `netbox.netbox` inventory and modules.

<details>
<summary><strong>Manual: Create the NetBox credential type from scratch</strong></summary>

1. Navigate to **Administration → Credential Types → Add**
2. Name: `NetBox`
3. **Input Configuration** (paste as YAML):

```yaml
fields:
  - id: netbox_url
    label: NetBox URL
    type: string
    help_text: "Full URL (e.g. http://netbox.zta.lab:8880)"
  - id: netbox_token
    label: API Token
    type: string
    secret: true
required:
  - netbox_url
  - netbox_token
```

4. **Injector Configuration** (paste as YAML):

```yaml
env:
  NETBOX_API: "{{ netbox_url }}"
  NETBOX_TOKEN: "{{ netbox_token }}"
```

5. Click **Save**, then restore **ZTA NetBox Credential** via automation or Exercise 1.3.

</details>

---

### Step 4 — Vault SSH CA (for Exercise 1.7)

Confirm Vault’s SSH CA and the signing role **ssh-signer** exist:

```bash
vault read ssh/config/ca
# Expected: public_key = ssh-rsa AAAA...

vault read ssh/roles/ssh-signer
# Expected: allowed_users includes rhel; lab TTL (e.g. 30m)
```

Run **Exercise 1.7 — Test Vault SSH Certificates** to see AAP obtain a signed cert.

---

### Credential summary

| Credential | Type | Secret source | Notes |
|------------|------|---------------|--------|
| ZTA Vault Credential | HashiCorp Vault Lookup | Stored in AAP | Bootstraps KV lookups |
| ZTA Machine Credential | Machine | Vault KV at job time | `secret/data/machine/rhel` |
| ZTA Arista Credential | Network | Vault KV at job time | `secret/data/network/arista` |
| ZTA NetBox Credential | NetBox (custom) | Token in AAP | CMDB |
| ZTA Vault SSH Credential | Vault Signed SSH | AppRole + CA | Ephemeral SSH certs |

> **Key takeaway**: Machine and Arista **passwords** are not copied into AAP —
> only Vault **paths**. Rotate secrets in Vault and the next job picks them up
> without editing controller credentials.

---

## Exercise 1.2 — IdM LDAP (Authentication Methods UI)

**Goal:** On AAP 2.6, IdM LDAP is often configured under **Access Management → Authentication Methods → Create authentication**. That path is **not** the same as `PATCH /api/controller/v2/settings/ldap/` used by `setup/configure-aap-ldap.yml`. Use this exercise when you need the **gateway UI** values that match the workshop IdM layout.

**Prerequisites:** IdM on `central.zta.lab`, domain `zta.lab` → base DN `dc=zta,dc=lab`. Controller trusts IdM CA for LDAPS (`setup/enroll-idm-clients.yml`). IdM `admin` password matches `idm_admin_password` (default `ansible123!`).

### Steps

1. Log in as platform **admin**. Go to **Access Management** → **Authentication Methods** → **Create authentication**.
2. **Authentication type:** LDAP.
3. Fill the main fields:

| Field | Workshop value |
|-------|----------------|
| Name | `IdM LDAP` (any label) |
| LDAP Server URI | `ldaps://central.zta.lab` |
| LDAP Bind DN | `uid=admin,cn=users,cn=accounts,dc=zta,dc=lab` |
| LDAP Bind Password | IdM `admin` password (`ansible123!` default) |
| LDAP Group Type | `GroupOfNamesType` (or `MemberDNGroupType` — see step 5) |
| LDAP User DN Template | *(empty)* |
| LDAP Start TLS | Off (use LDAPS URI above) |

4. **LDAP Connection Options** (YAML):

```yaml
OPT_REFERRALS: 0
OPT_NETWORK_TIMEOUT: 30
```

5. **LDAP Group Type Parameters** (required). These are **key/value arguments for the chosen group type’s constructor** (`LDAP_GROUP_TYPE_PARAMS` in the docs). **Only keys that type accepts are valid**—extra keys produce *Invalid option for specified GROUP_TYPE*.

Per [django-auth-ldap `LDAPGroupType`](https://django-auth-ldap.readthedocs.io/en/latest/reference.html#django_auth_ldap.config.LDAPGroupType) and the Red Hat LDAP group-type table ([AAP 2.5](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.5/html/access_management_and_authentication/gw-configure-authentication#controller-set-up-LDAP) / [AAP 2.6](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/access_management_and_authentication/gw-configure-authentication)):

- **`GroupOfNamesType`** — for `groupOfNames`; equivalent to `MemberDNGroupType('member')`. Its constructor only takes **`name_attr`** (membership attribute is fixed to `member`). Use:

```yaml
name_attr: cn
```

- **`MemberDNGroupType`** — generic “member DNs live in `member_attr` on the group entry”. Constructor takes **`member_attr`** and **`name_attr`**. To match the same IdM layout explicitly (and the doc’s two-field example), use:

```yaml
name_attr: cn
member_attr: member
```

For **FreeIPA/IdM `groupOfNames`**, those two choices are **functionally the same**. Use **`GroupOfNamesType` + `name_attr` only** for the shortest config; use **`MemberDNGroupType` + `name_attr` and `member_attr`** if you want to mirror Red Hat’s `{"name_attr": "cn", "member_attr": "member"}` style.

If you pick another **LDAP Group Type**, allowed keys change—see [AAP 2.6 Access management and authentication](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/access_management_and_authentication/).

6. **LDAP User Search** (YAML):

```yaml
- cn=users,cn=accounts,dc=zta,dc=lab
- SCOPE_SUBTREE
- (uid=%(user)s)
```

7. **LDAP Group Search** (YAML):

```yaml
- cn=groups,cn=accounts,dc=zta,dc=lab
- SCOPE_SUBTREE
- (objectClass=groupOfNames)
```

8. **LDAP User Attribute Map** (required, YAML):

```yaml
first_name: givenName
last_name: sn
email: mail
```

This is the only “mapping” inside the LDAP form itself: it copies IdM attributes into the platform user profile (name and email). It does **not** assign organizations, teams, or superuser.

9. Enable **Enabled** (and **Create objects** if you want local users on first login). **Create Authentication Method**.

### Organisation, team, and superuser mapping (gateway)

On AAP 2.6, permissions after LDAP login come from **authentication mapping** (authenticator maps), not from the LDAP User Attribute Map above. After you create the LDAP authenticator, use the workflow in Red Hat’s doc: [Define authentication mapping rules and triggers](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/access_management_and_authentication/gw-configure-authentication#gw-define-rules-triggers) (from **Access Management** → **Authentication Methods**). For each rule you pick a **map type** (see [Authenticator map types](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/access_management_and_authentication/gw-configure-authentication#gw-authenticator-map-types)) and a **trigger** such as **Group** when membership in an IdM group should decide access (see [Authenticator map triggers](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/access_management_and_authentication/gw-configure-authentication#gw-authenticator-map-triggers)).

These rules mirror the workshop’s IdM layout (same intent as the `ldap_config` maps in `setup/configure-aap-ldap.yml` if you compare to automation).

| Intent | IdM group DN (domain `dc=zta,dc=lab`) |
|--------|----------------------------------------|
| Platform superusers | `cn=zta-admins,cn=groups,cn=accounts,dc=zta,dc=lab` |
| Org **Default** — admins | `cn=zta-admins,cn=groups,cn=accounts,dc=zta,dc=lab` |
| AAP team **Infrastructure** | `cn=team-infrastructure,cn=groups,cn=accounts,dc=zta,dc=lab` |
| AAP team **DevOps** | `cn=team-devops,cn=groups,cn=accounts,dc=zta,dc=lab` |
| AAP team **Security** | `cn=team-security,cn=groups,cn=accounts,dc=zta,dc=lab` |
| AAP team **Applications** | `cn=team-applications,cn=groups,cn=accounts,dc=zta,dc=lab` |

#### Prerequisites (so Group triggers work)

1. On the **same** LDAP authenticator, **LDAP Group Search** and **LDAP Group Type** / **LDAP Group Type Parameters** must match IdM (`GroupOfNamesType`, `name_attr: cn`, group search under `cn=groups,cn=accounts,dc=zta,dc=lab`) — see steps 5–7 above. If groups are wrong, the platform never sees IdM membership and **Group** maps never match.
2. Turn **Create objects** **on** for this authenticator if org **Default** and the teams should be created automatically on first login (recommended for the lab).
3. **Remove users:** If enabled, every login re-evaluates maps; permissions not covered by a map can be **removed**. For learning environments, either define **complete** maps below or leave **Remove users** off until maps are correct. Details: [Access management and authentication](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/access_management_and_authentication/).

#### Where to add maps (UI)

1. **Access Management** → **Authentication Methods** → open your **IdM LDAP** authenticator.
2. Open the **Mapping** tab (or continue the wizard after **Create Authentication Method**, per [Define authentication mapping rules and triggers](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/access_management_and_authentication/gw-configure-authentication#gw-define-rules-triggers)).
3. Use **Add authentication mapping**. Map types: [Authenticator map types](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/access_management_and_authentication/gw-configure-authentication#gw-authenticator-map-types) (**Allow**, **Organization**, **Team**, **Role**, **Superuser**). For LDAP groups use trigger **Group** and the **full group DN** in **Groups** ([examples](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/access_management_and_authentication/gw-configure-authentication#gw-authenticator-map-examples)).

#### Workshop maps to create (manual)

One rule per row unless you combine groups with **or**. Use **Group** trigger except for the first row.

| Order (suggested) | Map type | Trigger | Groups (DN) | Target / role |
|------------------|----------|---------|-------------|----------------|
| 1 | **Organization** | **Always** | — | Organization **Default**, role **Organization Member** — every IdM user who logs in through this authenticator gets org membership (same idea as `users: true` in the legacy org map). |
| 2 | **Organization** | **Group** | `cn=zta-admins,cn=groups,cn=accounts,dc=zta,dc=lab` | Organization **Default**, role **Organization Admin**. |
| 3 | **Superuser** | **Group** | `cn=zta-admins,cn=groups,cn=accounts,dc=zta,dc=lab` | Platform superuser (optional; matches workshop `is_superuser` for **zta-admins**). |
| 4 | **Team** | **Group** | `cn=team-infrastructure,cn=groups,cn=accounts,dc=zta,dc=lab` | Team **Infrastructure**, organization **Default**, role **Team Member**. |
| 5 | **Team** | **Group** | `cn=team-devops,cn=groups,cn=accounts,dc=zta,dc=lab` | Team **DevOps**, organization **Default**, role **Team Member**. |
| 6 | **Team** | **Group** | `cn=team-security,cn=groups,cn=accounts,dc=zta,dc=lab` | Team **Security**, organization **Default**, role **Team Member**. |
| 7 | **Team** | **Group** | `cn=team-applications,cn=groups,cn=accounts,dc=zta,dc=lab` | Team **Applications**, organization **Default**, role **Team Member**. |

If multiple maps apply, **order matters** — see [Adjusting the Mapping order](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/html/access_management_and_authentication/gw-configure-authentication#gw-adjust-mapping-order).

**Username note:** IdM also has an `admin` user. Prefer **`ztauser`** (or another lab user) for LDAP testing so you do not collide with the local platform **admin** account.

**Verify:** Sign out; log in as `ztauser` / `ansible123!` at `https://control.zta.lab`. Expect **Default** org access and teams that match IdM groups in [`docs/lab/common-environment.adoc`](../docs/lab/common-environment.adoc) / `inventory/group_vars/all.yml`.

---

## Exercise 1.3 — Configure Inventory & Project

### Project from Gitea (create first — the inventory source depends on it)

1. Navigate to **Projects** → **Add**
2. Name: `ZTA Workshop`
3. Source Control Type: `Git`
4. Source Control URL: `http://gitea.zta.lab:3000/zta-workshop/zta-app.git`
5. Source Control Credential: `ZTA Gitea Credential`
6. Click **Save** and wait for the sync to complete (green status)

### Inventory from NetBox

**Step 1 — Create the inventory**

1. Navigate to **Inventories** → **Add** → **Add inventory**
2. Name: `ZTA Lab Inventory`
3. Organization: `Default`
4. Click **Save**

**Step 2 — Add the NetBox inventory source**

1. Inside the `ZTA Lab Inventory`, go to the **Sources** tab
2. Click **Add**
3. Configure:

| Field | Value |
|-------|-------|
| Name | `NetBox CMDB` |
| Source | `Sourced from a Project` |
| Project | `ZTA Workshop` |
| Inventory file | `inventory/netbox_inventory.yml` |
| Credential | `ZTA NetBox Credential` (type: NetBox) |

4. Under **Update options**, enable:
   - **Overwrite** — replace hosts on each sync (NetBox is the source of truth)
   - **Update on launch** — re-sync before every job that uses this inventory
5. Click **Save**

**Step 3 — Sync and verify**

1. Click the **Sync** (refresh) button on the `NetBox CMDB` source
2. Wait for the sync to complete (green status)
3. Go to the **Hosts** tab — you should see all workshop devices:

| Host | Device Role |
|------|-------------|
| `central.zta.lab` | Identity Provider |
| `control.zta.lab` | Automation Controller |
| `vault.zta.lab` | Secrets Manager |
| `wazuh.zta.lab` | Security Appliance |
| `netbox.zta.lab` | CMDB Server |
| `app.zta.lab` | Application Server |
| `db.zta.lab` | Application Server |
| `ceos1.zta.lab` | Network Switch |
| `ceos2.zta.lab` | Network Switch |
| `ceos3.zta.lab` | Network Switch |

4. Go to the **Groups** tab — verify groups were created by device role,
   site, tag, and platform (e.g. `device_role_identity_provider`,
   `tag_zero_trust`, `platform_rhel_9`)

> **ZTA Concept**: The inventory is sourced from the CMDB — not a static file.
> If a device is decommissioned in NetBox, it disappears from AAP on the next
> sync. NetBox is the *single source of truth* for infrastructure state.

**Troubleshooting**

If the sync fails:

```bash
# Verify NetBox is reachable and the token works
curl -s -H "Authorization: Token 0123456789abcdef0123456789abcdef01234567" \
  http://netbox.zta.lab:8880/api/dcim/devices/ | python3 -m json.tool

# Verify the netbox.netbox collection is in the AAP execution environment
# (check the EE image used by the project)
```

---

## Exercise 1.4 — Create Job Templates

| Template Name | Playbook | Inventory | Credentials |
|---------------|----------|-----------|-------------|
| Verify ZTA Services | `section1/playbooks/verify-zta-services.yml` | ZTA Lab Inventory | ZTA Machine Credential |
| Test Vault Integration | `section1/playbooks/test-vault-integration.yml` | ZTA Lab Inventory | ZTA Machine Credential |
| Test Vault SSH Certificates | `section1/playbooks/test-vault-ssh.yml` | ZTA Lab Inventory | ZTA Machine Credential |
| Test OPA Policy | `section1/playbooks/test-opa-policy.yml` | ZTA Lab Inventory | ZTA Machine Credential |

---

## Exercise 1.5 — Verify All ZTA Services

Launch **Verify ZTA Services** and confirm every component is healthy:

- IdM (FreeIPA): `RUNNING`
- Vault: healthy and unsealed
- OPA: loaded policies
- Netbox: API accessible
- Kerberos: TGT obtainable
- DNS: all `*.zta.lab` names resolve
- PostgreSQL: running and accepts queries
- Arista cEOS switches: respond with EOS facts

---

## Exercise 1.6 — Test Vault Dynamic Credentials

Launch **Test Vault Integration**.

**What to observe:**

- A KV secret is read from Vault (`secret/network/arista`)
- A dynamic PostgreSQL user is generated with a 5-minute TTL
- The username is randomised (e.g. `v-root-ztaapp-s-...`)
- The credentials are immediately revoked at the end

Run the template twice — the usernames will be different each time. Vault
never reuses credentials.

---

## Exercise 1.7 — Test Vault SSH Signed Certificates

Launch **Test Vault SSH Certificates**.

Each RHEL host trusts the Vault SSH Certificate Authority. The only way to
authenticate via certificate is with a key signed by Vault. No static SSH
keys are distributed — every certificate is generated on demand, time-bound,
and scoped to specific principals.

**What to observe:**

- An ephemeral keypair is generated and signed by Vault's SSH CA
- Certificate details are displayed (TTL, valid principals, serial number)
- SSH login to `app` and `db` hosts succeeds using the signed certificate
- The certificate has a 30-minute TTL (configurable)

### Manual Demo

```bash
export VAULT_ADDR=http://vault.zta.lab:8200
export VAULT_SKIP_VERIFY=true
vault login -method=userpass username=admin password=ansible123!

# Generate an ephemeral keypair
ssh-keygen -t rsa -b 2048 -f /tmp/ephemeral -N '' -q

# Sign the public key with Vault
vault write -field=signed_key ssh/sign/ssh-signer \
  public_key=@/tmp/ephemeral.pub valid_principals=rhel > /tmp/ephemeral-cert.pub

# Inspect the certificate
ssh-keygen -L -f /tmp/ephemeral-cert.pub

# SSH using the signed certificate
ssh -i /tmp/ephemeral -o CertificateFile=/tmp/ephemeral-cert.pub \
  -p 2023 rhel@192.168.1.11

# Clean up
rm -f /tmp/ephemeral /tmp/ephemeral.pub /tmp/ephemeral-cert.pub
```

---

## Exercise 1.8 — Test OPA Policy Decisions

Launch **Test OPA Policy**.

| Test | Scenario | Expected |
|------|----------|----------|
| 1 | Patch — authorised user, all conditions met | ALLOWED |
| 2 | Patch — user not in `patch-admins` | DENIED |
| 3 | VLAN — network admin, valid VLAN | ALLOWED |
| 4 | VLAN — engineer not in `network-admins` | DENIED |
| 5 | DB access — app deployer, valid request | ALLOWED |

OPA uses **deny-by-default**: no explicit allow rule = no access. Group
membership in IdM determines what each user can do.

---

## Validation Checklist

- [ ] IdM LDAP: **Exercise 1.2** (Authentication Methods UI) or `configure-aap-ldap.yml`; `ztauser` can log into the controller
- [ ] Vault Credential created (bootstrap — only stored password)
- [ ] Machine Credential created with Vault KV external lookup (key icon visible)
- [ ] Arista Credential created with Vault KV external lookup (key icon visible)
- [ ] NetBox Credential created with custom credential type
- [ ] Vault SSH Credential present (instructor pre-configured)
- [ ] Netbox inventory synced with all lab hosts
- [ ] Gitea project synced successfully
- [ ] Verify ZTA Services — all services healthy
- [ ] Vault Integration — dynamic DB credentials generated and revoked
- [ ] Vault SSH Certificates — signed cert login works, certificate details visible
- [ ] OPA Policy — correct allow/deny for each scenario

---

# Extended Exercises (Longer Formats Only)

# Exercise 1.9 — Certificate Trust Chain Debugging (Hands-On)

## The Scenario

A test HTTPS endpoint has been deployed on central, but it was set up with
a **self-signed certificate** instead of one issued by the IdM CA. Any client
that trusts the IdM CA will reject the connection because the certificate
issuer is unknown.

You must diagnose the TLS failure, identify the wrong certificate authority,
and fix it by requesting a proper certificate from IdM.

> **Instructor:** Run `ansible-playbook section1/playbooks/break-cert-trust.yml`

## Duration: ~25 minutes

---

## Step 1 — Observe the TLS Failure

Try to reach the test endpoint:

```bash
curl https://central.zta.lab:9443/
```

You'll get an error:
```
curl: (60) SSL certificate problem: self-signed certificate
```

Even with `-v` (verbose), curl tells you the certificate is not trusted:
```bash
curl -v https://central.zta.lab:9443/ 2>&1 | grep -i "ssl\|issuer\|verify"
```

---

## Step 2 — Inspect the Certificate

Use `openssl` to examine the certificate the server is presenting:

```bash
echo | openssl s_client -connect central.zta.lab:9443 2>/dev/null | \
  openssl x509 -text -noout | grep -E "Issuer|Subject|Not "
```

You'll see:
```
Issuer: CN = central.zta.lab, O = Self-Signed, OU = NOT-IDM-CA
Subject: CN = central.zta.lab, O = Self-Signed, OU = NOT-IDM-CA
Not Before: ...
Not After : ...
```

The **Issuer** is "Self-Signed / NOT-IDM-CA". This certificate was not
issued by the IdM CA, so any client that trusts the IdM CA will reject it.

**Compare with a working service** (the IdM web UI itself):

```bash
echo | openssl s_client -connect central.zta.lab:443 2>/dev/null | \
  openssl x509 -text -noout | grep -E "Issuer|Subject"
```

You'll see the IdM CA as the issuer — this is the trusted chain.

---

## Step 3 — Understand the Trust Chain

In a Zero Trust environment, the IdM CA is the **trust anchor**. All
services should present certificates signed by this CA. When a service
uses a self-signed cert:

- **Automated clients** (like Ansible, curl) reject the connection
- **Other services** cannot verify the identity of the endpoint
- **The service is effectively untrusted** in the ZTA fabric

The IdM CA certificate is available at `/etc/ipa/ca.crt` on enrolled hosts.
You can verify this:

```bash
ssh rhel@central.zta.lab
cat /etc/ipa/ca.crt | openssl x509 -text -noout | grep "Issuer"
```

---

## Step 4 — Fix: Request a Certificate from IdM

SSH to central and request a proper certificate using `ipa-getcert`:

```bash
ssh rhel@central.zta.lab

# Request a certificate from the IdM CA
sudo ipa-getcert request \
  -K HTTP/central.zta.lab \
  -D central.zta.lab \
  -f /etc/pki/tls/certs/zta-test-idm.crt \
  -k /etc/pki/tls/private/zta-test-idm.key \
  -N CN=central.zta.lab \
  -w

# Check the request status
sudo ipa-getcert list | grep -A5 "zta-test"
# Expected: status: MONITORING (certificate issued and tracked)
```

---

## Step 5 — Reconfigure the Endpoint

Update the test endpoint to use the new IdM-signed certificate:

```bash
# Edit the test endpoint script
sudo vi /opt/zta-test-https.py
```

Change the cert paths from:
```python
ctx.load_cert_chain(
    '/etc/pki/tls/certs/zta-test-selfsigned.crt',
    '/etc/pki/tls/private/zta-test-selfsigned.key'
)
```

To:
```python
ctx.load_cert_chain(
    '/etc/pki/tls/certs/zta-test-idm.crt',
    '/etc/pki/tls/private/zta-test-idm.key'
)
```

Restart the service:
```bash
sudo systemctl restart zta-test-https
```

---

## Step 6 — Verify the Fix

```bash
# From any IdM-enrolled host (which trusts the IdM CA):
curl https://central.zta.lab:9443/
# Expected: {"status": "ok", "service": "zta-test-endpoint", ...}

# Verify the certificate chain
echo | openssl s_client -connect central.zta.lab:9443 2>/dev/null | \
  openssl x509 -text -noout | grep "Issuer"
# Expected: Issuer shows the IdM CA, not "Self-Signed"
```

---

## ZTA Lesson

Zero Trust requires **verified identity for services**, not just users.
A self-signed certificate means the service cannot prove its identity to
clients. In a ZTA environment:

- All service certificates should be issued by the organisation's CA (IdM)
- `ipa-getcert` automates certificate lifecycle (request, renew, track)
- Expired or untrusted certificates break service-to-service communication
- Certificate monitoring (`ipa-getcert list`) is part of operational hygiene

## Certificate Trust Validation Checklist

- [ ] `curl https://central.zta.lab:9443/` fails with TLS error
- [ ] `openssl s_client` shows "Self-Signed" issuer
- [ ] Comparison with working IdM service shows the correct CA
- [ ] `ipa-getcert request` issues a new cert from the IdM CA
- [ ] Test endpoint reconfigured with the IdM-signed cert
- [ ] `curl https://central.zta.lab:9443/` succeeds after fix
- [ ] `openssl` confirms the IdM CA is now the issuer
