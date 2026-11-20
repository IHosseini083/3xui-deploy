# WebPanel HTTP API & Operational Bridge Contract

## Authentication & Sessions (`webpanel/auth.py`, `webpanel/server.py`)
- Cookie: `3xui_deploy_sid` (`HttpOnly; Secure; SameSite=Strict; Path=<WEBPANEL_PATH>`)
- Header on mutations: `X-CSRF-Token: <session.csrf_token>` + matching `Origin`
- Endpoints:
  - `GET /api/auth/status` — returns `{authenticated, username?, csrf_token?, domain, base_path, version}`
  - `POST /api/auth/login` — `{username, password}` (IP rate-limited: 5 failures / 15m -> `429`)
  - `POST /api/auth/logout` — clears cookie & invalidates session
  - `POST /api/auth/change-password` — verifies current password, enforces strong password policy, rotates current session, revokes others
  - `GET /api/auth/sessions` — lists active sessions (`sid`, `ip`, `user_agent`, `last_seen`, `current`)
  - `POST /api/auth/sessions/revoke-others` — revokes all other sessions for user

## Real-Time Job Progress & History (`webpanel/ops.py`, `webpanel/server.py`)
- Mutating endpoints support optional `"async": true`, returning `202 Accepted` with `{"accepted": true, "job": {...}}`.
- Persisted history is written atomically (`0600`) to `logs/webpanel-ops-history.json` with secret redaction.
- Endpoints:
  - `GET /api/jobs?limit=50` — returns recent and active operation history entries
  - `GET /api/jobs/<id>?since=N` — returns current job state and lines starting from index `N`
  - `GET /api/jobs/<id>/stream` — Server-Sent Events (`text/event-stream`) emitting `state`, `update`, `done` events and `: keepalive` heartbeats

## Operational Endpoints (`webpanel/ops.py`)
- `GET /api/overview` — host metrics (CPU, RAM/Swap, disk, network, OS), `3xui_*` containers + live stats, health summary, `version` (`deploy`, `webpanel`, `in_sync`), URLs, TLS certs, probe state
- `GET /api/version[?check=1]` — returns installed `current_version`, `webpanel_version`, `in_sync`, and (with `?check=1`) remote `latest_version`, `latest_ref`, `channel`, `update_available`, `release_url`
- `GET /api/health` — runs `manage.sh health`
- `GET /api/xray` — runs `manage.sh xray-status`
- `GET /api/compat` — runs `manage.sh compat check`
- `POST /api/compat/test` — `{tag, async?}` -> runs `manage.sh compat test <tag>`
- `POST /api/deploy` — `{db_type, pg_user?, async?}` -> runs `manage.sh deploy <sqlite|postgres> [user]`
- `POST /api/self-update` — `{target?, force?, async?}` -> runs `manage.sh self-update [--force] [target]` and schedules `3xui-deploy-web` restart if WebPanel files changed
- `POST /api/lifecycle` — `{action, async?}` in `{start, stop, restart, reload_caddy, verify_proxy, sync_inbounds_caddy, verify_inbounds, sync_firewall, self_update}`
- `POST /api/update` — `{tag?, force_compat?, async?}` -> runs `manage.sh [--force-compat] update [tag]`
- `POST /api/rollback` — `{async?}` -> runs `manage.sh rollback`

## SSL/TLS Certificate Management (`webpanel/ops.py`, `manage.sh certs`)
- `GET /api/certs` — inspects `cert/` and Caddy ACME certificates (SANs, issuer, expiry, days remaining, usage, revocable/renewable flags)
- `POST /api/certs/issue` — `{domain, email?, apply_mode?, async?}` -> runs `manage.sh certs issue`
- `POST /api/certs/self-signed` — `{host, days?, apply_mode?, async?}` -> runs `manage.sh certs self-signed`
- `POST /api/certs/renew` — `{domain?, force?, async?}` -> runs `manage.sh certs renew`
- `POST /api/certs/revoke` — `{domain, reason?, async?}` -> runs `manage.sh certs revoke` (revokes Let's Encrypt cert + removes local dir + updates Caddy/DB)
- `POST /api/certs/apply` — `{domain, target?, async?}` -> runs `manage.sh certs apply <domain> <caddy|panel>`

## Domains, Panel Settings, DNS & Network (`webpanel/ops.py`, `manage.sh`)
- `GET /api/network` — reads proxy, panel, subscription, WebPanel settings, `/etc/resolv.conf`, interfaces, and BBR status
- `PUT /api/network/proxy` — `{domain, port, email?, sub_mode, sub_domain?, sub_port?, sub_path?, sub_json_path?, use_panel_cert?, use_sub_cert?, async?}` -> runs `manage.sh proxy configure` with atomic rollback
- `POST /api/network/proxy/disable` — `{async?}` -> runs `manage.sh proxy disable`
- `PUT /api/network/panel` — `{port?, listen_ip?, web_path?, randomize_path?, session_max_age?, web_domain?, async?}` -> runs `manage.sh settings`
- `PUT /api/network/subscription` — `{enable, mode?, domain?, listen_ip?, port?, path?, json_enable?, json_path?, encrypt?, async?}` -> runs `manage.sh settings set-sub`
- `POST /api/network/panel/reset-2fa` — `{async?}` -> runs `manage.sh settings reset-2fa`
- `POST /api/network/panel/credentials` — `{username, password, async?}` -> passes credentials strictly via stdin to `manage.sh settings reset-credentials`
- `POST /api/network/dns-check` — `{domain}` -> runs `manage.sh dns check <domain>`
- `POST /api/network/bbr` — `{async?}` -> runs `manage.sh bbr`
- `GET /api/network/firewall` / `POST /api/network/firewall` — inspects rules or runs `{action: sync|open|close, port?, proto?, async?}` (blocks closing SSH or active proxy port)

## Decoy, Probe, Inbounds, Backups & Logs
- `GET /api/probe` / `PUT /api/probe` — reads or validates & atomically updates `caddy/probe.conf` + triggers `manage.sh proxy sync-caddy`
- `POST /api/probe/check` — tests explicit `{url}` or refreshes `caddy/probe-state.json`
- `POST /api/probe/simulate` — simulates routing for `{method, path, user_agent, client_ip}`
- `GET /api/decoy` / `PUT /api/decoy` — reads/updates decoy theme/metadata or custom HTML and applies via `manage.sh proxy decoy-apply`
- `GET /api/inbounds` — runs `manage.sh inbounds list` and returns parsed `rows` + `output`
- `POST /api/audit` — `{async?}` -> runs `manage.sh audit` and parses `[PASS]` / `[WARN]` / `[FAIL]` items
- `GET /api/backups`, `POST /api/backups`, `POST /api/backups/restore` (`{name, async?}`), `POST /api/backups/prune` (`{keep}`), `GET /api/backups/cron`, `PUT /api/backups/cron` (`{enabled, hour, keep}`)
- `GET /api/logs?source={deploy|audit|xui|caddy|postgres|backup}&lines=150&level=ALL&query=`
- `POST /api/geo-update` — `{scope, async?}` in `{std, ir, ru, all}`
- `PUT /api/webpanel/settings` — `{idle_minutes}` -> updates `webpanel.conf` and live `AuthStore` idle timeout
