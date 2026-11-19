# WebPanel HTTP API & Operational Bridge Contract

## Authentication & Sessions (`webpanel/auth.py`, `webpanel/server.py`)
- Cookie: `3xui_deploy_sid` (`HttpOnly; Secure; SameSite=Strict; Path=<WEBPANEL_PATH>`)
- Header on mutations: `X-CSRF-Token: <session.csrf_token>` + matching `Origin`
- Endpoints:
  - `GET /api/auth/status` — returns `{authenticated, username?, csrf_token?, domain, base_path}`
  - `POST /api/auth/login` — `{username, password}` (IP rate-limited: 5 failures / 15m -> `429`)
  - `POST /api/auth/logout` — clears cookie & invalidates session
  - `POST /api/auth/change-password` — verifies current password, enforces strong password policy, rotates current session, revokes others
  - `GET /api/auth/sessions` — lists active sessions (`sid`, `ip`, `user_agent`, `last_seen`, `current`)
  - `POST /api/auth/sessions/revoke-others` — revokes all other sessions for user

## Operational Endpoints (`webpanel/ops.py`)
- `GET /api/overview` — host metrics, `3xui_*` containers, version, URLs, TLS certs, probe state
- `GET /api/compat` — runs `manage.sh compat check`
- `POST /api/compat/test` — `{tag}` -> runs `manage.sh compat test <tag>`
- `POST /api/lifecycle` — `{action}` in `{start, stop, restart, reload_caddy, verify_proxy, sync_inbounds_caddy, verify_inbounds}`
- `POST /api/update` — `{tag?, force_compat?}` -> runs `manage.sh [--force-compat] update [tag]`
- `POST /api/rollback` — runs `manage.sh rollback`
- `GET /api/probe` / `PUT /api/probe` — reads or validates & atomically updates `caddy/probe.conf` + triggers `manage.sh proxy sync-caddy` (auto-rolls back on Caddy rejection)
- `POST /api/probe/check` — tests explicit `{url}` or refreshes `caddy/probe-state.json`
- `POST /api/probe/simulate` — simulates routing for `{method, path, user_agent, client_ip}`
- `GET /api/decoy` / `PUT /api/decoy` — reads/updates decoy theme/metadata or custom HTML and applies via `manage.sh proxy decoy-apply`
- `GET /api/inbounds` — runs `manage.sh inbounds list`
- `POST /api/audit` — runs `manage.sh audit` and parses `[PASS]` / `[WARN]` / `[FAIL]` items
- `GET /api/backups`, `POST /api/backups`, `POST /api/backups/prune` (`{keep}`)
- `GET /api/logs?source={deploy|audit|xui|caddy}&lines=150&level=ALL`
- `POST /api/geo-update` — `{scope}` in `{std, ir, ru, all}`
