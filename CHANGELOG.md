# Changelog

All notable changes to `3xui-deploy` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v2.0.0] - 2026-11-20

### Added
- **Semantic Versioning & Release-Aware Upgrades**:
  - Added canonical `VERSION`, `DEPLOY_VERSION`, `webpanel.__version__`, `--version` / `version` CLI commands, and WebPanel version visibility.
  - Upgraded `self-update` to track the latest GitHub Release tag (`vX.Y.Z`) with automatic fallback to `main`, explicit `<tag|main>`, `--check`, `--force`, optional `SHA256SUMS.txt` verification, synchronized full-stack WebPanel file updates, and clean service restart handoff.
  - Added `GET /api/version` (`?check=1`) and upgraded `POST /api/self-update` with target/force selection and reload coordination.
  - Added GitHub Actions CI version-sync enforcement and automated tagged Release publishing (`SHA256SUMS.txt` + changelog notes).
- **Mobile-First WebPanel v2 Control Plane**:
  - Rebuilt `webpanel/static/{index.html,app.css,app.js}` as a responsive 8-view console (`overview`, `certs`, `network`, `probe`, `inbounds`, `deploy`, `operations`, `settings`) with mobile drawer + bottom navigation bar, horizontal sub-tabs, dark/light theme, and strict CSP/XSS compliance.
  - Added Live Operation Console Drawer powered by Server-Sent Events (`GET /api/jobs/<id>/stream`) with automatic incremental polling fallback (`GET /api/jobs/<id>?since=N`) and redacted persistent operation history (`logs/webpanel-ops-history.json`).
  - Added severity-badged confirmation dialogs (including typed confirmation phrases for high-risk actions).
- **Expanded CLI & WebPanel Operations**:
  - Full SSL/TLS certificate lifecycle: inspect (`cert/` + Caddy ACME certs), issue Let's Encrypt standalone, generate ECDSA P-256 self-signed, renew, apply (`caddy`/`panel`), and revoke (`certbot revoke` + DB/Caddy cleanup).
  - Non-interactive `manage.sh` subcommands & WebPanel endpoints for `deploy`, `settings`, `proxy configure`, `dns`, `firewall` (with SSH & active proxy port lockout protection), `xray-status`, `backup cron-*`, and `webpanel update-settings`.
  - Backend performance & runtime sync: gzip + ETag/304 caching on `/assets/*` and hot-reload of `webpanel.conf` settings.

## [v1.0.0] - 2026-06-01

### Added
- Zero-dependency Bash TUI & CLI manager (`manage.sh`) for local and multiplexed SSH remote deployments of `mhsanaei/3x-ui` (SQLite & PostgreSQL).
- Forward-compatibility guardrails (`compat`), DB schema probing, preflight container checks, redacted diagnostic logging, and transactional rollback.
- Hardened Caddy v2 reverse proxy (`3xui_caddy`), multi-page decoy websites, SSRF-safe probe redirection with automatic health fallback, and standalone Python stdlib WebPanel (`/deploy/`).
- Security compliance audit, multi-protocol inbound proxy/firewall syncing, online backups, BBR tuning, and GeoIP/GeoSite updaters.
