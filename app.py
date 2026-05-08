"""
ZTA Workshop — Live Topology Dashboard
Serves a real-time status page for every component in the lab.
"""

import socket
import ssl
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.request import urlopen, Request
from urllib.error import URLError

from flask import Flask, jsonify, render_template

app = Flask(__name__)

TIMEOUT = 4  # seconds for each probe

# ---------------------------------------------------------------------------
# Component definitions — mirrors the architecture diagram
# ---------------------------------------------------------------------------
COMPONENTS = [
    # ── Management Plane VMs ──────────────────────────────────────────────
    {
        "id": "aap",
        "name": "AAP Controller",
        "group": "mgmt",
        "ip": "192.168.1.10",
        "details": "EDA :5000",
        "tooltip": {
            "description": "Ansible Automation Platform 2.6 \u2014 controller and Event-Driven Ansible (EDA). Orchestrates all lab automation, job templates, and incident response workflows.",
            "zta_role": "Automation & Orchestration \u2014 executes policy-gated playbooks, enforces RBAC via OPA, and triggers auto-remediation through EDA.",
            "aap_managed": "Self \u2014 this IS the automation platform.",
            "workshop_sections": "All sections (1\u20137)",
        },
        "checks": [
            {"type": "https", "url": "https://192.168.1.10", "label": "Web UI"},
        ],
    },
    {
        "id": "central",
        "name": "Central VM",
        "group": "mgmt",
        "ip": "192.168.1.11",
        "details": "IdM \u2022 OPA \u2022 SPIRE",
        "tooltip": {
            "description": "RHEL host running IdM, OPA, SPIRE server, cEOS switches, and workload containers. The infrastructure backbone of the lab.",
            "zta_role": "Identity & Policy Hub \u2014 hosts the identity provider (IdM), policy engine (OPA), and workload identity system (SPIRE).",
            "aap_managed": "Yes \u2014 configured via setup playbooks (firewall, DNS, container networking, IdM enrollment).",
            "workshop_sections": "All sections",
        },
        "checks": [
            {"type": "tcp", "host": "localhost", "port": 22, "label": "SSH"},
        ],
    },
    {
        "id": "vault",
        "name": "Vault",
        "group": "mgmt",
        "ip": "192.168.1.12",
        "details": "Secrets :8200",
        "tooltip": {
            "description": "HashiCorp Vault \u2014 secrets engine providing dynamic database credentials, SSH certificate signing, and KV secret storage.",
            "zta_role": "Secrets & Credential Management \u2014 issues short-lived credentials (5 min TTL) so no standing access exists. Signs SSH certificates for zero-trust SSH.",
            "aap_managed": "Yes \u2014 Vault engines, policies, and AppRoles configured by AAP playbooks. AAP reads credentials via input sources.",
            "workshop_sections": "Section 2 (DB creds), Section 5 (revocation), Section 6 (SSH signing)",
        },
        "checks": [
            {"type": "http", "url": "http://192.168.1.12:8200/v1/sys/health", "label": "Vault API"},
        ],
    },
    {
        "id": "netbox",
        "name": "Netbox",
        "group": "mgmt",
        "ip": "192.168.1.15",
        "details": "CMDB :8880",
        "tooltip": {
            "description": "NetBox \u2014 CMDB and IPAM. Source of truth for devices, interfaces, IPs, VLANs, and services in the lab.",
            "zta_role": "Asset Inventory & CMDB \u2014 provides the single source of truth for network topology. AAP uses it as a dynamic inventory source and VLAN registry.",
            "aap_managed": "Yes \u2014 seeded and updated by AAP playbooks. Serves as AAP\u2019s dynamic inventory via nb_inventory plugin.",
            "workshop_sections": "Section 1 (inventory), Section 4 (VLAN registration)",
        },
        "checks": [
            {"type": "http", "url": "http://192.168.1.15:8000", "label": "Web UI"},
        ],
    },
    # ── Services on Central ───────────────────────────────────────────────
    {
        "id": "idm",
        "name": "IdM (FreeIPA)",
        "group": "services",
        "details": "LDAP \u2022 DNS",
        "tooltip": {
            "description": "Red Hat Identity Management (FreeIPA) \u2014 LDAP directory, Kerberos KDC, DNS, and certificate authority for the lab.",
            "zta_role": "Identity Provider \u2014 authenticates users and manages group memberships. AAP\u2019s LDAP authenticator maps IdM groups to AAP teams for RBAC.",
            "aap_managed": "Yes \u2014 IdM client enrollment and user/group management automated via AAP playbooks.",
            "workshop_sections": "Section 1 (LDAP auth), Section 4 (identity management)",
        },
        "checks": [
            {"type": "https", "url": "https://localhost/ipa/ui/", "label": "Web UI"},
            {"type": "tcp", "host": "localhost", "port": 389, "label": "LDAP"},
        ],
    },
    {
        "id": "opa",
        "name": "OPA (PDP)",
        "group": "services",
        "details": "Policies :8181",
        "tooltip": {
            "description": "Open Policy Agent \u2014 policy decision point evaluating Rego policies for access control, data classification, and network segmentation.",
            "zta_role": "Policy Decision Point (PDP) \u2014 enforces zero-trust policies. AAP queries OPA before every job (gateway policy) and during workflows (db_access, network, data classification).",
            "aap_managed": "Yes \u2014 Rego policies deployed and updated by AAP playbooks. AAP Policy as Code integration queries OPA on every job launch.",
            "workshop_sections": "Section 2 (db_access), Section 3 (gateway + patching), Section 4 (network policy)",
        },
        "checks": [
            {"type": "http", "url": "http://localhost:8181/health", "label": "Health"},
        ],
    },
    {
        "id": "keycloak",
        "name": "Keycloak",
        "group": "services",
        "details": "SSO :8443",
        "tooltip": {
            "description": "Red Hat build of Keycloak \u2014 SSO and OIDC provider. Optional component for federated identity.",
            "zta_role": "SSO & Federation \u2014 provides OIDC/SAML authentication federation. Optional layer on top of IdM for external identity sources.",
            "aap_managed": "Yes \u2014 deployed via AAP playbooks (optional, skip with --skip-tags keycloak).",
            "workshop_sections": "Optional",
        },
        "checks": [
            {"type": "https", "url": "https://localhost:8543", "label": "Web UI"},
        ],
    },
    {
        "id": "wazuh",
        "name": "Wazuh",
        "group": "services",
        "details": "SIEM",
        "tooltip": {
            "description": "Wazuh \u2014 open-source SIEM and XDR platform for threat detection, file integrity monitoring, and compliance.",
            "zta_role": "Security Monitoring (alternate) \u2014 detects brute-force attacks and anomalies, triggers EDA webhooks for automated incident response.",
            "aap_managed": "Yes \u2014 agents deployed via AAP. EDA rulebook auto-revokes Vault credentials on Wazuh alerts.",
            "workshop_sections": "Section 7 (optional Wazuh path)",
        },
        "checks": [
            {"type": "http", "url": "http://localhost:5601", "label": "Dashboard"},
        ],
    },
    {
        "id": "splunk",
        "name": "Splunk",
        "group": "services",
        "details": "Log Analytics :8000",
        "tooltip": {
            "description": "Splunk Enterprise \u2014 log aggregation, search, alerting, and dashboards for security event monitoring.",
            "zta_role": "Security Monitoring (primary) \u2014 aggregates logs from all components, detects suspicious activity, and fires webhook alerts to EDA for automated credential revocation.",
            "aap_managed": "Yes \u2014 Splunk integration, forwarder configs, and HEC tokens managed by AAP playbooks.",
            "workshop_sections": "Section 5 (incident response)",
        },
        "checks": [
            {"type": "http", "url": "http://localhost:8000", "label": "Web UI"},
        ],
    },
    {
        "id": "spire",
        "name": "SPIRE Server",
        "group": "services",
        "details": "Workload Identity :8082",
        "tooltip": {
            "description": "SPIRE Server \u2014 issues SPIFFE Verifiable Identity Documents (SVIDs) to registered workloads. Agents run on control, db, and vault.",
            "zta_role": "Workload Identity \u2014 provides cryptographic identity to workloads without relying on network location. OPA network policy verifies SVIDs before authorising VLAN changes.",
            "aap_managed": "Yes \u2014 deployed via deploy-spire.yml. Server on central, agents on control/db/vault, workload entries registered automatically.",
            "workshop_sections": "Section 4 (SPIFFE + VLAN automation)",
        },
        "checks": [
            {"type": "tcp", "host": "localhost", "port": 8082, "label": "Registration API"},
        ],
    },
    # ── Arista cEOS Switches ──────────────────────────────────────────────
    {
        "id": "ceos1",
        "name": "ceos1 (SPINE)",
        "group": "switches",
        "details": "10.10.0.1 \u2022 10.20.0.254",
        "tooltip": {
            "description": "Arista cEOS spine switch \u2014 central backbone router interconnecting leaf switches across the app and data tiers.",
            "zta_role": "Micro-segmentation Backbone \u2014 routes traffic between VLANs/subnets. ACLs enforced here control which workloads can communicate.",
            "aap_managed": "Yes \u2014 switch configs deployed and ACLs managed via AAP network automation (arista.eos collection).",
            "workshop_sections": "Section 2 (ACLs), Section 4 (VLAN creation)",
        },
        "checks": [
            {"type": "tcp", "host": "localhost", "port": 2001, "label": "SSH"},
            {"type": "http", "url": "http://localhost:6031", "label": "eAPI"},
        ],
    },
    {
        "id": "ceos2",
        "name": "ceos2 (LEAF)",
        "group": "switches",
        "details": "10.10.0.2 \u2022 10.30.0.1",
        "tooltip": {
            "description": "Arista cEOS leaf switch \u2014 connects the database container to the data-plane network (net2, 10.30.0.0/24).",
            "zta_role": "Data Tier Gateway \u2014 enforces ACLs that only permit authorised traffic to reach the database. Part of the micro-segmentation fabric.",
            "aap_managed": "Yes \u2014 ACL rules pushed by AAP as part of the Section 2 deploy workflow.",
            "workshop_sections": "Section 2 (DB access ACLs), Section 4 (VLAN)",
        },
        "checks": [
            {"type": "tcp", "host": "localhost", "port": 2002, "label": "SSH"},
            {"type": "http", "url": "http://localhost:6032", "label": "eAPI"},
        ],
    },
    {
        "id": "ceos3",
        "name": "ceos3 (LEAF)",
        "group": "switches",
        "details": "10.20.0.1",
        "tooltip": {
            "description": "Arista cEOS leaf switch \u2014 connects the application container to the app-plane network (net3, 10.20.0.0/24).",
            "zta_role": "App Tier Gateway \u2014 enforces network segmentation between the app tier and other zones. ACLs ensure only permitted flows.",
            "aap_managed": "Yes \u2014 network configuration managed via AAP playbooks.",
            "workshop_sections": "Section 2, Section 4",
        },
        "checks": [
            {"type": "tcp", "host": "localhost", "port": 2003, "label": "SSH"},
            {"type": "http", "url": "http://localhost:6033", "label": "eAPI"},
        ],
    },
    # ── Workload Containers ───────────────────────────────────────────────
    {
        "id": "db",
        "name": "DB Container",
        "group": "workloads",
        "details": "db.zta.lab \u2022 10.30.0.10:5432",
        "tooltip": {
            "description": "PostgreSQL database container \u2014 hosts the ztaapp database. Credentials are short-lived (5 min TTL) and issued dynamically by Vault.",
            "zta_role": "Protected Data Store \u2014 access requires Vault dynamic credentials, OPA policy approval, and Arista ACL permit. No standing access exists.",
            "aap_managed": "Yes \u2014 container deployed, networking configured, and credentials rotated by AAP. Vault leases revoked via EDA on security alerts.",
            "workshop_sections": "Section 2 (deploy + creds), Section 5 (revocation)",
        },
        "checks": [
            {"type": "tcp", "host": "localhost", "port": 5432, "label": "PostgreSQL"},
            {"type": "tcp", "host": "localhost", "port": 2022, "label": "SSH"},
        ],
    },
    {
        "id": "app",
        "name": "App Container",
        "group": "workloads",
        "details": "app.zta.lab \u2022 10.20.0.10:8081",
        "tooltip": {
            "description": "Flask web application container \u2014 serves the ZTA demo app with a health dashboard. Connects to PostgreSQL using Vault-issued dynamic credentials.",
            "zta_role": "Workload \u2014 demonstrates zero-trust application deployment: OPA-gated access, Vault dynamic DB credentials, SPIFFE workload identity, and network micro-segmentation.",
            "aap_managed": "Yes \u2014 application deployed, health-checked, and credentials injected by AAP playbooks.",
            "workshop_sections": "Section 2 (deploy), Section 4 (SPIFFE identity)",
        },
        "checks": [
            {"type": "http", "url": "http://localhost:8081/health", "label": "Health"},
            {"type": "tcp", "host": "localhost", "port": 2023, "label": "SSH"},
        ],
    },
]


# ---------------------------------------------------------------------------
# Probe functions
# ---------------------------------------------------------------------------
def _check_tcp(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=TIMEOUT):
            return True
    except (OSError, socket.timeout):
        return False


def _make_ssl_ctx():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _check_http(url: str) -> bool:
    try:
        req = Request(url, method="GET")
        with urlopen(req, timeout=TIMEOUT, context=_make_ssl_ctx()) as r:
            return r.status < 500
    except URLError as e:
        if hasattr(e, "code") and e.code < 500:
            return True
        return False
    except Exception:
        return False


def _run_check(check: dict) -> dict:
    ctype = check["type"]
    ok = False
    if ctype == "tcp":
        ok = _check_tcp(check["host"], check["port"])
    elif ctype in ("http", "https"):
        ok = _check_http(check["url"])
    return {"label": check["label"], "ok": ok}


# ---------------------------------------------------------------------------
# Cached status — refreshed in background thread
# ---------------------------------------------------------------------------
_status_cache: dict = {}
_cache_lock = threading.Lock()


def _refresh_status():
    """Run all health checks concurrently and update the cache."""
    results = {}
    with ThreadPoolExecutor(max_workers=20) as pool:
        futures = {}
        for comp in COMPONENTS:
            comp_futures = []
            for chk in comp["checks"]:
                f = pool.submit(_run_check, chk)
                futures[f] = (comp["id"], chk["label"])
                comp_futures.append(f)

        check_results: dict[str, list] = {}
        for f in as_completed(futures):
            comp_id, label = futures[f]
            if comp_id not in check_results:
                check_results[comp_id] = []
            check_results[comp_id].append(f.result())

    for comp in COMPONENTS:
        cid = comp["id"]
        checks = check_results.get(cid, [])
        all_ok = all(c["ok"] for c in checks) if checks else False
        any_ok = any(c["ok"] for c in checks) if checks else False

        if all_ok:
            status = "healthy"
        elif any_ok:
            status = "degraded"
        else:
            status = "down"

        results[cid] = {
            "id": cid,
            "name": comp["name"],
            "group": comp["group"],
            "details": comp.get("details", ""),
            "ip": comp.get("ip", ""),
            "status": status,
            "checks": checks,
            "tooltip": comp.get("tooltip", {}),
        }

    with _cache_lock:
        _status_cache.update(results)
        _status_cache["_ts"] = time.time()


def _background_poller():
    while True:
        try:
            _refresh_status()
        except Exception:
            pass
        time.sleep(10)


# Start background thread on import
_poller = threading.Thread(target=_background_poller, daemon=True)
_poller.start()
# Also run one synchronous pass so the first request has data
_refresh_status()


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/status")
def api_status():
    with _cache_lock:
        return jsonify(_status_cache)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5050, debug=False)
