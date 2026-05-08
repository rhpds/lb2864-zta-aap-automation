#!/usr/bin/env python3
# region agent log
"""Emit NDJSON debug lines for NetBox inventory sync (session d07fbd). Do not log secrets."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

LOG_PATH = Path("/home/nmartins/Development/.cursor/debug-d07fbd.log")
SESSION = "d07fbd"
REPO = Path(__file__).resolve().parent.parent


def _log(hypothesis_id: str, location: str, message: str, data: dict) -> None:
    payload = {
        "sessionId": SESSION,
        "timestamp": int(time.time() * 1000),
        "hypothesisId": hypothesis_id,
        "location": location,
        "message": message,
        "data": data,
        "runId": os.environ.get("DEBUG_RUN_ID", "pre-fix"),
    }
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a", encoding="utf-8") as f:
        f.write(json.dumps(payload, ensure_ascii=False) + "\n")


def main() -> int:
    # H1: extensionless path fails auto.verify_file (.yml/.yaml only)
    for name in ("inventory/netbox_inventory", "inventory/netbox_inventory.yml"):
        p = REPO / name
        ext = os.path.splitext(str(p))[-1].lower()
        auto_would_accept = p.suffix.lower() in (".yml", ".yaml")
        _log(
            "H1",
            "scripts/agent_debug_netbox_inventory.py:auto_extension",
            "auto plugin verify_file requires .yml or .yaml",
            {
                "path": name,
                "exists": p.is_file(),
                "suffix": ext or "(empty)",
                "auto_would_accept": auto_would_accept,
            },
        )

    # H2: netbox collection visible to ansible-galaxy (EE / local)
    try:
        r = subprocess.run(
            ["ansible-galaxy", "collection", "list"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        out = (r.stdout or "") + (r.stderr or "")
        _log(
            "H2",
            "scripts/agent_debug_netbox_inventory.py:galaxy_list",
            "netbox.netbox in collection list",
            {
                "exit_code": r.returncode,
                "netbox_netbox_present": "netbox.netbox" in out,
            },
        )
    except Exception as e:
        _log(
            "H2",
            "scripts/agent_debug_netbox_inventory.py:galaxy_list",
            "ansible-galaxy failed or missing",
            {"error": type(e).__name__, "error_msg": str(e)[:200]},
        )

    # H3: root ansible.cfg [inventory] enable_plugins (default omits collection plugins)
    root_cfg = REPO / "ansible.cfg"
    inv_cfg = REPO / "inventory" / "ansible.cfg"
    root_text = root_cfg.read_text(encoding="utf-8", errors="replace") if root_cfg.is_file() else ""
    inv_text = inv_cfg.read_text(encoding="utf-8", errors="replace") if inv_cfg.is_file() else ""
    _log(
        "H3",
        "scripts/agent_debug_netbox_inventory.py:ansible_cfg",
        "inventory enable_plugins presence",
        {
            "root_has_inventory_section": "[inventory]" in root_text,
            "root_enable_plugins_line": next(
                (ln.strip() for ln in root_text.splitlines() if ln.strip().lower().startswith("enable_plugins")),
                None,
            ),
            "inventory_subdir_cfg_has_enable_netbox": "netbox.netbox.nb_inventory" in inv_text,
        },
    )

    # H4: yaml plugin accepts empty extension (matches failure mode)
    p_noext = REPO / "inventory" / "netbox_inventory"
    ext4 = os.path.splitext(str(p_noext))[-1]
    yaml_accepts_empty_ext = not ext4 or ext4.lower() in (".yaml", ".yml", ".json")
    _log(
        "H4",
        "scripts/agent_debug_netbox_inventory.py:yaml_verify",
        "yaml inventory plugin treats empty extension as valid",
        {
            "path": "inventory/netbox_inventory",
            "splitext_suffix": ext4 or "(empty)",
            "yaml_would_try_parse": yaml_accepts_empty_ext,
        },
    )

    return 0


# endregion agent log

if __name__ == "__main__":
    sys.exit(main())
