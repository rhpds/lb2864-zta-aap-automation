#!/usr/bin/env python3
"""Print whether netbox.netbox is visible to ansible-galaxy (local or EE-like PATH)."""
import os
import subprocess


def main() -> None:
    r = subprocess.run(
        ["ansible-galaxy", "collection", "list"],
        capture_output=True,
        text=True,
        timeout=120,
    )
    out = (r.stdout or "") + (r.stderr or "")
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    req_path = os.path.join(repo_root, "collections", "requirements.yml")
    print(
        "ansible-galaxy collection list: exit=%s, netbox.netbox present=%s"
        % (r.returncode, "netbox.netbox" in out)
    )
    print("Output (head):\n%s" % out[:2500])
    print("Repo root: %s" % repo_root)
    print("collections/requirements.yml exists: %s" % os.path.isfile(req_path))


if __name__ == "__main__":
    main()
