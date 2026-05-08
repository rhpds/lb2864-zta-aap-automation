#!/usr/bin/env bash
# Bootstrap AAP on Podman (lab): container DNS for *.zta.lab + IdM CA in gateway for LDAPS.
#
# Ansible equivalent (recommended for inventory-driven labs):
#   ansible-playbook -i inventory/hosts.ini setup/configure-aap-podman-gateway-prereqs.yml
#
# Run as the SAME Linux user that owns the AAP stack (e.g. rhel) — NOT "sudo podman".
# Requires: sudo (writes /etc/containers; exec as root inside gateway for update-ca-trust).
#
# Fixes:
#   - automation-gateway could not resolve central.zta.lab → Podman [network] dns_servers
#   - LDAPS failed: certificate verify failed (self-signed) → IdM CA in container trust
#
# Usage:
#   ./setup/aap-podman-lab-bootstrap.sh
#   IDM_DNS=192.168.1.11 IDM_HOST=central.zta.lab ./setup/aap-podman-lab-bootstrap.sh
#   IDM_CA_FILE=/path/to/ca.pem SKIP_DNS=1 ./setup/aap-podman-lab-bootstrap.sh
#
# Env:
#   IDM_DNS         Default 192.168.1.11 — first resolver for containers (IdM DNS)
#   FALLBACK_DNS    Default 8.8.8.8 — second resolver (registry, etc.)
#   IDM_HOST        Default central.zta.lab — used for default CA URL only
#   IDM_CA_FILE     If set, use this PEM (skip fetch)
#   IDM_CA_URL      Default http://${IDM_HOST}/ipa/config/ca.crt
#   GATEWAY_CONTAINER  Default automation-gateway
#   SKIP_DNS=1      Do not write containers.conf.d drop-in
#   SKIP_CA=1       Do not install CA into gateway
#   CONTROLLER_CONTAINER  Default automation-controller (restarted after gateway if present)
#   SKIP_CONTROLLER_RESTART=1  Do not restart controller (gateway only)
#   SKIP_RESTART=1  Do not podman restart gateway/controller after changes

set -euo pipefail

IDM_DNS="${IDM_DNS:-192.168.1.11}"
FALLBACK_DNS="${FALLBACK_DNS:-172.30.0.10}"
IDM_HOST="${IDM_HOST:-central.zta.lab}"
IDM_CA_URL="${IDM_CA_URL:-http://${IDM_HOST}/ipa/config/ca.crt}"
GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-automation-gateway}"
CONTROLLER_CONTAINER="${CONTROLLER_CONTAINER:-automation-controller}"

DROPIN_DIR="/etc/containers/containers.conf.d"
DROPIN_FILE="${DROPIN_DIR}/99-lab-dns.conf"
ANCHOR_NAME="zta-ipa-ca.crt"

log() { printf '%s\n' "$*"; }

require_podman_gateway() {
  if ! podman inspect "$GATEWAY_CONTAINER" &>/dev/null; then
    log "ERROR: No container named '${GATEWAY_CONTAINER}' for this user."
    log "Use the same account as 'podman ps' (not sudo podman). Names are per user (rootless vs root)."
    exit 1
  fi
}

write_dns_dropin() {
  sudo install -d -m 0755 "$DROPIN_DIR"
  sudo tee "$DROPIN_FILE" >/dev/null <<EOF
# Added by zta-workshop-aap setup/aap-podman-lab-bootstrap.sh
[network]
dns_servers = ["${IDM_DNS}", "${FALLBACK_DNS}"]
EOF
  log "Wrote ${DROPIN_FILE}"
}

# Print path to a PEM file; may create a temp file (caller removes if path under /tmp).
resolve_ca_pem() {
  if [[ -n "${IDM_CA_FILE:-}" ]]; then
    if [[ ! -f "$IDM_CA_FILE" ]]; then
      log "ERROR: IDM_CA_FILE not found: $IDM_CA_FILE"
      exit 1
    fi
    echo "$IDM_CA_FILE"
    return 0
  fi
  if [[ -r /etc/ipa/ca.crt ]]; then
    log "Using IdM CA from /etc/ipa/ca.crt (host is enrolled)."
    echo /etc/ipa/ca.crt
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  if curl -fsSL "$IDM_CA_URL" -o "$tmp"; then
    log "Downloaded IdM CA from ${IDM_CA_URL}"
    echo "$tmp"
    return 0
  fi
  rm -f "$tmp"
  log "ERROR: No CA found. Enroll this host (ipa-client-install) for /etc/ipa/ca.crt,"
  log "  or set IDM_CA_FILE=/path/to/ca.pem, or fix IDM_CA_URL (current: ${IDM_CA_URL})."
  exit 1
}

install_ca_in_gateway() {
  local ca_path="$1"
  require_podman_gateway
  podman cp "$ca_path" "${GATEWAY_CONTAINER}:/etc/pki/ca-trust/source/anchors/${ANCHOR_NAME}"
  if podman exec -u 0 "$GATEWAY_CONTAINER" update-ca-trust extract; then
    log "update-ca-trust extract OK in ${GATEWAY_CONTAINER}"
  else
    log "ERROR: update-ca-trust failed inside ${GATEWAY_CONTAINER} (need root in container?)."
    exit 1
  fi
}

cleanup_ca_temp=""
ca_path="$(resolve_ca_pem)"
[[ "$ca_path" == /tmp/* ]] && cleanup_ca_temp="$ca_path"
trap '[[ -n "${cleanup_ca_temp}" ]] && rm -f "${cleanup_ca_temp}"' EXIT

if [[ "${SKIP_DNS:-0}" != "1" ]]; then
  write_dns_dropin
else
  log "SKIP_DNS=1 — not writing ${DROPIN_FILE}"
fi

if [[ "${SKIP_CA:-0}" != "1" ]]; then
  install_ca_in_gateway "$ca_path"
else
  log "SKIP_CA=1 — not installing IdM CA into gateway"
fi

if [[ "${SKIP_RESTART:-0}" != "1" ]]; then
  require_podman_gateway
  # stop+start avoids podman restart races (merged/etc/passwd missing, rc 125)
  podman_stop_start() {
    local cname="$1"
    podman stop -t 90 "$cname" || true
    sleep "${RESTART_PAUSE:-3}"
    podman start "$cname"
    log "Stopped then started ${cname}"
  }
  podman_stop_start "$GATEWAY_CONTAINER"
  if [[ "${SKIP_CONTROLLER_RESTART:-0}" != "1" ]] && podman inspect "$CONTROLLER_CONTAINER" &>/dev/null; then
    podman_stop_start "$CONTROLLER_CONTAINER"
  elif [[ "${SKIP_CONTROLLER_RESTART:-0}" != "1" ]]; then
    log "No container '${CONTROLLER_CONTAINER}' — skipped controller restart"
  fi
else
  log "SKIP_RESTART=1 — restart gateway (and controller if used) yourself to apply DNS + trust."
fi

log ""
log "Verify (as this user, no sudo podman):"
log "  podman exec -it ${GATEWAY_CONTAINER} getent hosts ${IDM_HOST}"
log "  podman exec ${GATEWAY_CONTAINER} openssl s_client -connect ${IDM_HOST}:636 -brief </dev/null"
log "Then try LDAP login (ztauser) in the UI."
