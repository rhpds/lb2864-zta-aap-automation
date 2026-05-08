#!/usr/bin/env bash
# Append-only NDJSON debug probe for AAP gateway vs controller (session aba44c).
# Same intent as debug_aap_gateway_probe.py — use either script.
# Requires: curl, jq. Does not write passwords or bearer tokens to the log.
# #region agent log
set -euo pipefail

LOG_PATH="${DEBUG_LOG_PATH:-/home/nmartins/Development/.cursor/debug-aba44c.log}"
SESSION="aba44c"
RUN_ID="${DEBUG_RUN_ID:-bash-probe}"

AAP_URL="${AAP_URL:-https://control.zta.lab}"
AAP_URL="${AAP_URL%/}"
AAP_USER="${AAP_USER:-admin}"
AAP_PASSWORD="${AAP_PASSWORD:-${AAP_ADMIN_PASSWORD:-ansible123!}}"

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (dnf install jq / apt install jq)" >&2
  exit 1
fi

_ts_ms() { echo $(( $(date +%s) * 1000 )); }

_emit() {
  local hypothesis_id="$1" message="$2" data_json="$3"
  jq -nc \
    --arg sessionId "$SESSION" \
    --arg hypothesisId "$hypothesis_id" \
    --arg message "$message" \
    --arg location "setup/scripts/debug_aap_gateway_probe.sh" \
    --arg runId "$RUN_ID" \
    --argjson timestamp "$(_ts_ms)" \
    --argjson data "$data_json" \
    '{sessionId: $sessionId, timestamp: $timestamp, hypothesisId: $hypothesisId, location: $location, message: $message, data: $data, runId: $runId}' \
    >>"$LOG_PATH"
}

# Run curl; set ${prefix}_code _ctype _server _envoy_ms _body_len _bodyf
_http() {
  local prefix="$1" method="$2" url="$3"
  shift 3
  local hdrf bodyf
  hdrf="$(mktemp)"
  bodyf="$(mktemp)"
  # shellcheck disable=SC2068
  local code
  code="$(curl -skS -g -X "$method" -D "$hdrf" -o "$bodyf" -w '%{http_code}' "$@" "$url" || true)"
  local ctype server envoy_ms
  ctype="$(grep -i '^content-type:' "$hdrf" 2>/dev/null | tail -1 | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r' || true)"
  server="$(grep -i '^server:' "$hdrf" 2>/dev/null | tail -1 | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r' || true)"
  envoy_ms="$(grep -i '^x-envoy-upstream-service-time:' "$hdrf" 2>/dev/null | tail -1 | awk '{print $2}' | tr -d '\r' || true)"
  local body_len
  body_len="$(wc -c <"$bodyf" | tr -d ' ')"
  rm -f "$hdrf"
  printf -v "${prefix}_code" '%s' "$code"
  printf -v "${prefix}_ctype" '%s' "$ctype"
  printf -v "${prefix}_server" '%s' "$server"
  printf -v "${prefix}_envoy_ms" '%s' "$envoy_ms"
  printf -v "${prefix}_body_len" '%s' "$body_len"
  printf -v "${prefix}_bodyf" '%s' "$bodyf"
}

_preview_file() {
  local f="$1" limit="${2:-280}"
  head -c "$limit" "$f" | jq -Rs . 2>/dev/null || echo '""'
}

_json_status() {
  local c="$1"
  if [[ -z "$c" ]] || ! [[ "$c" =~ ^[0-9]+$ ]]; then
    echo 'null'
  else
    echo "$c"
  fi
}

# --- H1 ---
_http h1 GET "${AAP_URL}/api/controller/v2/ping/"
data="$(jq -nc \
  --argjson status "$(_json_status "${h1_code:-}")" \
  --arg content_type "${h1_ctype:-}" \
  --arg server "${h1_server:-}" \
  --arg envoy_upstream_ms "${h1_envoy_ms:-}" \
  --argjson body_len "${h1_body_len:-0}" \
  '{status: $status, content_type: $content_type, server: $server, envoy_upstream_ms: $envoy_upstream_ms, body_len: $body_len}')"
_emit H1 controller_ping "$data"
rm -f "${h1_bodyf:-}"

# --- H2 ---
_http h2 POST "${AAP_URL}/api/gateway/v1/tokens/" \
  -u "${AAP_USER}:${AAP_PASSWORD}" \
  -H 'Content-Type: application/json' \
  -d '{}'
if [[ "${h2_code:-}" == "200" || "${h2_code:-}" == "201" ]]; then
  tok_preview='"[redacted-success-body]"'
else
  tok_preview="$(_preview_file "${h2_bodyf}" 400)"
fi
data="$(jq -nc \
  --argjson status "$(_json_status "${h2_code:-}")" \
  --arg content_type "${h2_ctype:-}" \
  --arg server "${h2_server:-}" \
  --arg envoy_upstream_ms "${h2_envoy_ms:-}" \
  --argjson body_len "${h2_body_len:-0}" \
  --argjson body_preview "${tok_preview}" \
  '{status: $status, content_type: $content_type, server: $server, envoy_upstream_ms: $envoy_upstream_ms, body_len: $body_len, body_preview: $body_preview}')"
_emit H2 gateway_oauth_token_post "$data"

TOKEN=""
if [[ "${h2_code:-}" == "200" || "${h2_code:-}" == "201" ]] && [[ -s "${h2_bodyf:-}" ]]; then
  TOKEN="$(jq -r '.token // .access_token // empty' "${h2_bodyf}" 2>/dev/null || true)"
fi
rm -f "${h2_bodyf:-}"

h3_summary='null'
h4_summary='null'

# --- H3 ---
if [[ -n "$TOKEN" ]]; then
  _http h3 GET "${AAP_URL}/api/gateway/v1/users/?limit=1" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Accept: application/json'
  prev="$(_preview_file "${h3_bodyf}" 400)"
  data="$(jq -nc \
    --argjson status "$(_json_status "${h3_code:-}")" \
    --arg content_type "${h3_ctype:-}" \
    --arg server "${h3_server:-}" \
    --arg envoy_upstream_ms "${h3_envoy_ms:-}" \
    --argjson body_len "${h3_body_len:-0}" \
    --argjson body_preview "${prev}" \
    '{status: $status, content_type: $content_type, server: $server, envoy_upstream_ms: $envoy_upstream_ms, body_len: $body_len, body_preview: $body_preview}')"
  _emit H3 gateway_users_get "$data"
  h3_summary="$(_json_status "${h3_code:-}")"
  rm -f "${h3_bodyf:-}"
else
  _emit H3 gateway_users_get "$(jq -nc '{skipped: true, reason: "no_oauth_token"}')"
fi

# --- H4 ---
if [[ -n "$TOKEN" ]]; then
  uname="dbg_$(tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 8 || echo "$RANDOM")"
  payload="$(jq -nc \
    --arg u "$uname" \
    --arg e "${uname}@probe.invalid" \
    '{username: $u, password: "DbgProbe_ChangeMe_9!", email: $e, first_name: "Debug", last_name: "Probe"}')"
  _http h4 POST "${AAP_URL}/api/gateway/v1/users/" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "$payload"
  prev="$(_preview_file "${h4_bodyf}" 400)"
  data="$(jq -nc \
    --argjson status "$(_json_status "${h4_code:-}")" \
    --arg content_type "${h4_ctype:-}" \
    --arg server "${h4_server:-}" \
    --arg envoy_upstream_ms "${h4_envoy_ms:-}" \
    --argjson body_len "${h4_body_len:-0}" \
    --arg probe_username "$uname" \
    --argjson body_preview "${prev}" \
    '{status: $status, content_type: $content_type, server: $server, envoy_upstream_ms: $envoy_upstream_ms, body_len: $body_len, body_preview: $body_preview, probe_username: $probe_username}')"
  _emit H4 gateway_user_post "$data"
  h4_summary="$(_json_status "${h4_code:-}")"
  rm -f "${h4_bodyf:-}"
else
  _emit H4 gateway_user_post "$(jq -nc '{skipped: true, reason: "no_oauth_token"}')"
fi

# --- H5: summary ---
_emit H5 probe_summary "$(jq -nc \
  --argjson controller_ping_status "$(_json_status "${h1_code:-}")" \
  --argjson gateway_token_status "$(_json_status "${h2_code:-}")" \
  --argjson gateway_users_get_status "${h3_summary}" \
  --argjson gateway_user_post_status "${h4_summary}" \
  '{controller_ping_status: $controller_ping_status, gateway_token_status: $gateway_token_status, gateway_users_get_status: $gateway_users_get_status, gateway_user_post_status: $gateway_user_post_status}')"

# #endregion
exit 0
