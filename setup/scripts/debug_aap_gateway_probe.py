#!/usr/bin/env python3
"""
Append-only NDJSON debug probe for AAP gateway vs controller (session aba44c).
Does not print or log passwords or bearer tokens — only status codes and safe previews.
"""
# #region agent log
from __future__ import annotations

import base64
import json
import os
import ssl
import sys
import time
import uuid
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

LOG_PATH = "/home/nmartins/Development/.cursor/debug-aba44c.log"
SESSION = "aba44c"


def _log(hypothesis_id: str, message: str, data: dict) -> None:
    entry = {
        "sessionId": SESSION,
        "timestamp": int(time.time() * 1000),
        "hypothesisId": hypothesis_id,
        "location": "setup/scripts/debug_aap_gateway_probe.py",
        "message": message,
        "data": data,
        "runId": os.environ.get("DEBUG_RUN_ID", "probe1"),
    }
    with open(LOG_PATH, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry, default=str) + "\n")


def _http(
    method: str,
    url: str,
    *,
    headers: dict | None = None,
    body: bytes | None = None,
    ctx: ssl.SSLContext,
) -> tuple[int | None, dict, bytes]:
    req = Request(url, method=method, headers=dict(headers or {}))
    if body is not None:
        req.data = body
    try:
        with urlopen(req, context=ctx, timeout=45) as resp:
            raw = resp.read()
            return resp.status, dict(resp.headers), raw
    except HTTPError as exc:
        raw = exc.read() if exc.fp else b""
        return exc.code, dict(exc.headers), raw
    except URLError as exc:
        return None, {}, repr(exc).encode()


def _safe_preview(raw: bytes, limit: int = 280) -> str:
    if not raw:
        return ""
    text = raw[:limit].decode(errors="replace")
    return text.replace("\n", "\\n")


def _envoy_ms(hdrs: dict) -> str | None:
    for key in hdrs:
        if key.lower() == "x-envoy-upstream-service-time":
            return str(hdrs.get(key))
    return None


def main() -> int:
    base = os.environ.get("AAP_URL", "https://control.zta.lab").rstrip("/")
    user = os.environ.get("AAP_USER", "admin")
    password = os.environ.get("AAP_PASSWORD", "")

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    st3: int | None = None
    st4: int | None = None

    # H1: controller reachable (baseline)
    st, hdrs, body = _http("GET", f"{base}/api/controller/v2/ping/", ctx=ctx)
    _log(
        "H1",
        "controller_ping",
        {
            "status": st,
            "content_type": hdrs.get("Content-Type"),
            "body_len": len(body or b""),
            "server": hdrs.get("Server"),
            "envoy_upstream_ms": _envoy_ms(hdrs),
        },
    )

    # H2: gateway OAuth token (same contract as configure-aap-gateway-ldap.yml)
    tok_url = f"{base}/api/gateway/v1/tokens/"
    basic = base64.b64encode(f"{user}:{password}".encode()).decode()
    st2, hdrs2, body2 = _http(
        "POST",
        tok_url,
        headers={
            "Authorization": f"Basic {basic}",
            "Content-Type": "application/json",
        },
        body=json.dumps({}).encode(),
        ctx=ctx,
    )
    # Never log token body on success
    _log(
        "H2",
        "gateway_oauth_token_post",
        {
            "status": st2,
            "content_type": hdrs2.get("Content-Type"),
            "body_len": len(body2 or b""),
            "server": hdrs2.get("Server"),
            "envoy_upstream_ms": _envoy_ms(hdrs2),
            "body_preview": _safe_preview(body2) if st2 not in (200, 201) else "[redacted-success-body]",
        },
    )

    token = ""
    if body2 and st2 in (200, 201):
        try:
            parsed = json.loads(body2.decode())
            token = str(parsed.get("token") or parsed.get("access_token") or "")
        except (json.JSONDecodeError, UnicodeError):
            token = ""

    # H3: list users (authenticated gateway; bearer not logged)
    if token:
        st3, hdrs3, body3 = _http(
            "GET",
            f"{base}/api/gateway/v1/users/?limit=1",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
            ctx=ctx,
        )
        _log(
            "H3",
            "gateway_users_get",
            {
                "status": st3,
                "content_type": hdrs3.get("Content-Type"),
                "body_len": len(body3 or b""),
                "server": hdrs3.get("Server"),
                "envoy_upstream_ms": _envoy_ms(hdrs3),
                "body_preview": _safe_preview(body3),
            },
        )
    else:
        _log("H3", "gateway_users_get", {"skipped": True, "reason": "no_oauth_token"})

    # H4: POST create user (reproduces UI local user path if permissions OK)
    if token:
        uname = f"dbg_{uuid.uuid4().hex[:8]}"
        payload = {
            "username": uname,
            "password": "DbgProbe_ChangeMe_9!",
            "email": f"{uname}@probe.invalid",
            "first_name": "Debug",
            "last_name": "Probe",
        }
        st4, hdrs4, body4 = _http(
            "POST",
            f"{base}/api/gateway/v1/users/",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            body=json.dumps(payload).encode(),
            ctx=ctx,
        )
        _log(
            "H4",
            "gateway_user_post",
            {
                "status": st4,
                "content_type": hdrs4.get("Content-Type"),
                "body_len": len(body4 or b""),
                "server": hdrs4.get("Server"),
                "envoy_upstream_ms": _envoy_ms(hdrs4),
                "body_preview": _safe_preview(body4, 400),
                "probe_username": uname,
            },
        )
    else:
        _log("H4", "gateway_user_post", {"skipped": True, "reason": "no_oauth_token"})

    # H5: single-line summary for quick triage (maps UI 500 to which hop failed)
    _log(
        "H5",
        "probe_summary",
        {
            "controller_ping_status": st,
            "gateway_token_status": st2,
            "gateway_users_get_status": st3,
            "gateway_user_post_status": st4,
        },
    )

    return 0


# #endregion

if __name__ == "__main__":
    sys.exit(main())
