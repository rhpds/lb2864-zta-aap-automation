#!/usr/bin/env bash
# Configure Podman default network DNS so AAP containers can resolve lab names
# (e.g. central.zta.lab for LDAP). Run as root on the AAP host.
#
# For DNS + IdM CA in automation-gateway in one go (run as rhel / podman user), use:
#   ./setup/aap-podman-lab-bootstrap.sh
#
# Usage:
#   sudo ./setup/podman-containers-dns-lab.sh
#   sudo IDM_DNS=192.168.1.11 FALLBACK_DNS=8.8.8.8 ./setup/podman-containers-dns-lab.sh
#
# After running: restart AAP / gateway container (or full stack) so resolv.conf is refreshed.

set -euo pipefail

IDM_DNS="${IDM_DNS:-192.168.1.11}"
FALLBACK_DNS="${FALLBACK_DNS:-172.30.0.10}"
DROPIN_DIR="/etc/containers/containers.conf.d"
DROPIN_FILE="${DROPIN_DIR}/99-lab-dns.conf"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

mkdir -p "$DROPIN_DIR"

umask 022
cat >"$DROPIN_FILE" <<EOF
# Added by zta-workshop-aap setup/podman-containers-dns-lab.sh
# IdM / lab DNS first, public fallback second (pulls + internal names).
[network]
dns_servers = ["${IDM_DNS}", "${FALLBACK_DNS}"]
EOF

echo "Wrote ${DROPIN_FILE}"
echo "---"
cat "$DROPIN_FILE"
echo "---"
echo "Next:"
echo "  1) Restart AAP (or at least: podman restart automation-gateway)."
echo "  2) Verify: podman exec -it automation-gateway getent hosts central.zta.lab"
echo "If IdM does not host DNS for zta.lab, use AddHost on the gateway instead of relying on dns_servers."
