#!/usr/bin/env python3
"""
Diagnose NetBox dynamic inventory (same env vars AAP injects: NETBOX_API, NETBOX_TOKEN).
Run from repo root after: export NETBOX_API=... NETBOX_TOKEN=...
"""
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

REPO_ROOT = Path(__file__).resolve().parent.parent


def _group_vars_netbox_url() -> Optional[str]:
    p = REPO_ROOT / "inventory" / "group_vars" / "all.yml"
    if not p.is_file():
        return None
    text = p.read_text(encoding="utf-8", errors="replace")
    m = re.search(r'netbox_url:\s*["\']?([^"\'\n]+)', text)
    return m.group(1).strip() if m else None


def _netbox_status_check(api_base: str, token: str) -> dict:
    url = api_base.rstrip("/") + "/api/status/"
    req = urllib.request.Request(url, method="GET")
    if token:
        req.add_header("Authorization", f"Token {token}")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read(500)
            return {
                "http_status": resp.status,
                "ok": resp.status == 200,
                "body_head": body.decode("utf-8", errors="replace")[:200],
            }
    except urllib.error.HTTPError as e:
        return {
            "http_status": e.code,
            "ok": False,
            "error": "HTTPError",
            "body_head": (e.read(300) or b"").decode("utf-8", errors="replace"),
        }
    except Exception as e:
        return {"ok": False, "error": type(e).__name__, "error_msg": str(e)[:300]}


def main() -> int:
    api = os.environ.get("NETBOX_API", "").strip()
    token_set = bool(os.environ.get("NETBOX_TOKEN", "").strip())
    parsed = urlparse(api) if api else None
    port = (
        parsed.port
        if parsed and parsed.port
        else (
            80
            if parsed and parsed.scheme == "http"
            else 443 if parsed and parsed.scheme == "https" else None
        )
    )

    print(
        "Env: NETBOX_API set=%s, NETBOX_TOKEN set=%s; host=%s port=%s scheme=%s"
        % (
            bool(api),
            token_set,
            parsed.hostname if parsed else None,
            port,
            parsed.scheme if parsed else None,
        )
    )

    gv_url = _group_vars_netbox_url()
    print(
        "group_vars netbox_url: %r (env has :8000=%s :8880=%s; gv has :8000=%s :8880=%s)"
        % (
            gv_url,
            ":8000" in api if api else False,
            ":8880" in api if api else False,
            ":8000" in (gv_url or ""),
            ":8880" in (gv_url or ""),
        )
    )

    r = subprocess.run(
        ["ansible-galaxy", "collection", "list"],
        capture_output=True,
        text=True,
        timeout=120,
    )
    gal = (r.stdout or "") + (r.stderr or "")
    print(
        "ansible-galaxy collection list: exit=%s, netbox.netbox present=%s"
        % (r.returncode, "netbox.netbox" in gal)
    )

    if not api or not token_set:
        print("Set NETBOX_API and NETBOX_TOKEN, then re-run.", file=sys.stderr)
        return 2

    status = _netbox_status_check(api, os.environ.get("NETBOX_TOKEN", "").strip())
    print("NetBox GET /api/status/: %r" % (status,))

    inv_dir = REPO_ROOT / "inventory"
    cfg = inv_dir / "ansible.cfg"
    env = os.environ.copy()
    env.setdefault("ANSIBLE_CONFIG", str(cfg))
    proc = subprocess.run(
        [
            "ansible-inventory",
            "-i",
            str(inv_dir / "netbox_inventory.yml"),
            "--list",
        ],
        capture_output=True,
        text=True,
        timeout=120,
        cwd=str(inv_dir),
        env=env,
    )
    err = (proc.stderr or "")[:1200]
    print(
        "ansible-inventory --list: exit=%s, stdout_bytes=%s"
        % (proc.returncode, len(proc.stdout or ""))
    )
    if err:
        print("ansible-inventory stderr (head):\n%s" % err, file=sys.stderr)

    return 0 if proc.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
