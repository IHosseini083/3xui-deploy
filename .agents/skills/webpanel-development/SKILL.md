---
name: webpanel-development
description: >-
  Guides development of the standalone Python stdlib Web Management Panel in webpanel/
  and its systemd/Caddy integration in manage.sh. Use when adding API endpoints, UI views,
  authentication/session hardening, or manage.sh operational bridges.
---

# Standalone Web Management Panel Development

Use this skill when modifying `webpanel/*.py`, `webpanel/static/*`, or the WebPanel lifecycle functions in `manage.sh`.

## Security & Design Rules

1. **Zero External Dependencies**:
   - Backend uses Python 3.9+ standard library only (`http.server`, `hashlib.scrypt`, `hmac`, `secrets`, `subprocess`, `threading`, `json`, `urllib`, `ipaddress`).
   - Frontend (`webpanel/static/`) uses vanilla HTML/CSS/JS with zero external CDNs, zero inline `<script>`, and zero `on*=` attributes so strict CSP (`script-src 'self'`) holds.
2. **Fail-Closed Access Control & Exclusive Domain Routing**:
   - Bind strictly to `127.0.0.1` (or `::1`) via `WEBPANEL_BIND`.
   - Validate `X-Forwarded-Host` (trusted only from loopback peer) / `Host` against `WEBPANEL_DOMAIN`; return `403` on any mismatch or raw IP request.
   - Caddy mounts `@webpanel` (`WEBPANEL_PATH`, default `/deploy/`) **only** inside the main `PROXY_DOMAIN` site block and **never** on dedicated subscription domains (`SUB_DOMAIN`).
   - Every `/api/*` endpoint except `GET /api/auth/status` and `POST /api/auth/login` requires a valid session cookie (`3xui_deploy_sid`, `Path=<WEBPANEL_PATH>; HttpOnly; Secure; SameSite=Strict`).
   - Every state-changing request (`POST`, `PUT`, `PATCH`, `DELETE` except login) requires matching `Origin` and `X-CSRF-Token` verified with `hmac.compare_digest`.
3. **Subprocess & XSS Safety**:
   - Call `manage.sh` only via fixed allowlisted argument lists in `webpanel/ops.py` with `shell=False` and `self._op_lock`.
   - Never pass passwords via argv; `webpanel.auth` CLI reads passwords from `stdin`.
   - In `webpanel/static/app.js`, render dynamic strings with `.textContent` only (never `.innerHTML`).
   - Keep [API Contract Reference](./references/api-contract.md) updated when adding or changing endpoints.

## Verification

1. Run `python3 -m py_compile webpanel/__init__.py webpanel/auth.py webpanel/probe.py webpanel/ops.py webpanel/server.py`.
2. Run `python3 -m unittest discover -s tests -p "test_*.py" -v`.
3. Run `bash tests/test_manage.sh` to verify Caddy `@webpanel` routing and path non-overlap.
