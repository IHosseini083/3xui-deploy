# 3xui-deploy Engineering Guide (`AGENTS.md`)

Repository guidelines for human engineers and AI coding agents working on `3xui-deploy`.

## Architecture Map

- **`manage.sh`** — Zero-dependency Bash TUI & CLI suite managing Docker Compose (`3xui_app`, `3xui_postgres`, `3xui_caddy`), 3x-ui compatibility adapters, TLS/certs, multi-page decoy site generation, Caddy reverse-proxy & probe redirection rules, backups/restores, host tuning, and WebPanel lifecycle.
- **`webpanel/`** — Standalone zero-dependency Python 3.9+ stdlib Web Management Panel:
  - `webpanel/auth.py`: scrypt password hashing, server-side sessions, CSRF protection, rate limiting, and secret-redacted audit logging.
  - `webpanel/probe.py`: `caddy/probe.conf` & `caddy/probe-state.json` persistence, SSRF-safe URL validation, target health probing, safe fallback state evaluation, and request simulation.
  - `webpanel/ops.py`: thread-safe allowlisted CLI bridge (`subprocess.run(..., shell=False)`) invoking `manage.sh` + safe host/container metrics inspection.
  - `webpanel/server.py`: loopback-bound `ThreadingHTTPServer`, strict domain-only `Host`/`X-Forwarded-Host` validation, security headers, and background redirect-target health monitor.
  - `webpanel/static/{index.html,app.css,app.js}`: minimal responsive vanilla frontend with strict CSP compliance (no inline `<script>` or `on*=` attributes).
- **`tests/`** — Automated test suites (`tests/test_manage.sh`, `tests/test_compat.sh`, `tests/test_webpanel.py`).
- **`.agents/skills/`** — Modular agent runbooks for 3x-ui compatibility, decoy/probe engineering, webpanel development, and testing/release verification.

## Non-Negotiable Invariants

1. **Unix LF (`\n`) Line Endings Always**: Every `.sh`, `.py`, `.html`, `.css`, `.js`, `.json`, `.yml`, and `.md` file must use LF (`\n`). CI fails on any `\r`.
2. **Never Patch 3x-ui Core Internals**: Do not modify source files or templates inside `ghcr.io/mhsanaei/3x-ui`. Interact solely via documented CLI flags (`setting`), env vars (`XUI_DB_TYPE`, `XUI_DB_DSN`, `XUI_DB_FOLDER`, `XUI_BIN_FOLDER`), and the `settings`/`inbounds` schema through adapter functions in `manage.sh`.
3. **Zero External Runtime Dependencies**: `manage.sh` uses standard POSIX/Bash utilities; `webpanel/` uses Python 3.9+ stdlib only; `webpanel/static/` and `caddy/site/` use vanilla HTML/CSS/JS with zero CDN calls.
4. **Shell Quoting & Secret Hygiene**:
   - Escape all variables passed to `run`, `run_out`, `run_q`, or `ssh_cmd` with `quote_sh`.
   - Never pass passwords in CLI argv or `compose.yaml`. Use stdin (`_xui_set_credentials_stdin`, `python3 -m webpanel.auth`) and `0600` `.env` / `auth.json` files.
   - Never log raw passwords, `XUI_DB_DSN`, or session/CSRF tokens. Keep `_sanitize_log_text` and `auth.sanitize_log_text` updated.
5. **Preserve Mock & Caddy Contracts**:
   - Preserve `b=/app/x-ui; [ -x "$b" ] || b=/usr/local/x-ui/x-ui` inside `_xui_set_credentials_stdin` so `tests/test_manage.sh` mock sed hook matches.
   - Keep `generate_caddyfile` backward-compatible with its 12 positional parameters.
   - In Caddy v2 Caddyfiles, define `@named` matchers at the site-block level (never inside `handle { ... }`) and use `not header User-Agent *` (never `header !User-Agent`).
6. **Route Non-Interference & Decoy Stealth**:
   - Mount `@webpanel` (`/deploy/` or exclusive non-overlapping path) only on the main `PROXY_DOMAIN` vhost, never on dedicated subscription vhosts (`SUB_DOMAIN`), and never overlapping `PANEL_PATH`, `SUB_PATH`, `SUB_JSON_PATH`, or `@inbound_*`.
   - Generated decoy site files under `caddy/site/` must never contain `3x-ui`, `3xui`, `xray`, or VPN terminology.
7. **Transactional Rollback**: Mutating operations (`apply_version`, `_sync_caddy_if_active`, `manage_geo_assets`, `update_probe_config`) must validate/pull/snapshot before applying and automatically roll back on failure.

## Verification Commands

- Line endings: ensure no `\r` in modified files.
- Bash checks:
  - `bash -n manage.sh tests/test_manage.sh tests/test_compat.sh`
  - `bash tests/test_manage.sh`
  - `bash tests/test_compat.sh`
- Python checks:
  - `python3 -m py_compile webpanel/__init__.py webpanel/auth.py webpanel/probe.py webpanel/ops.py webpanel/server.py tests/test_webpanel.py`
  - `python3 -m unittest discover -s tests -p "test_*.py" -v`
- CLI smoke: `./manage.sh --help`
