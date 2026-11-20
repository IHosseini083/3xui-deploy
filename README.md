# 3X-UI Deploy & VPS Manager

[![CI](https://github.com/IHosseini083/3xui-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/IHosseini083/3xui-deploy/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A zero-dependency Bash TUI & CLI manager for deploying, hardening, monitoring, and maintaining the [mhsanaei/3x-ui](https://github.com/mhsanaei/3x-ui) Xray panel via Docker Compose — **locally on a VPS or remotely from your workstation over multiplexed SSH**.

---

## Key Features

- **Local & Remote SSH Management**: Auto-detects VPS vs. workstation environments, persists short-lived SSH `ControlMaster` sockets (`mux-%C`, `ControlPersist=15m`, forwarding disabled) without saving SSH passwords to disk, and includes a built-in SSH public-key installer.
- **SQLite or PostgreSQL Deployment**: Automatic Docker & Compose installation, GitHub release resolution without API rate-limit failures, Docker log rotation (`10m` × `3`), loopback-bound PostgreSQL (`127.0.0.1:5432`) with `scram-sha-256` auth, `XUI_DB_DSN` isolated in `.env` (`chmod 600`), and `XRAY_VMESS_AEAD_FORCED: "true"`.
- **Immediate Panel Hardening, Verification & Settings**: Guided post-deploy hardening (stdin credential passing, password strength policy, 60-minute `sessionMaxAge`) plus a settings menu to change the port, listening IP (`webListen`), `webBasePath`, subscription domain/listen IP/URIs, `webDomain`, session timeout, admin credentials, and reset 2FA. Automatically verifies that the 3X-UI Web UI and subscription endpoints actually respond.
- **Forward Compatibility, Diagnostics & Auto-Rollback (`compat`)**: Probes `3xui_app` binary paths, DB schemas (`settings` / `inbounds`), and `setting` CLI flags before applying changes; explicitly blocks unsupported releases unless `--force-compat` is passed; pulls and runs read-only preflight container checks before touching `compose.yaml`; logs staged operations (`INFO`, `WARN`, `ERROR`, `CRITICAL`) with secret redaction to `logs/3xui-deploy.log`; and automatically rolls back failed updates or Caddy reloads.
- **Caddy Reverse Proxy, Legitimate Multi-Page Decoy & Probe Redirection**: Deploy a hardened containerized Caddy v2 reverse proxy (`3xui_caddy` with `cap_drop: ALL` + `no-new-privileges`, admin API isolated to `unix//config/admin.sock`), automatic HTTPS (including custom ports like `8443` when port `443` is occupied by Xray Reality), loopback-locked panel & subscription servers (`127.0.0.1`), a multi-page responsive decoy website (`Meridian Cloud Systems` / `Northstar Digital Studio` / `Atlas Engineering Docs`) on `/`, configurable probe/scanner redirection (e.g., `https://www.cloudflare.com`, `https://www.speedtest.net`) with automatic safe fallback when targets are unreachable, and support for either a **dedicated subscription domain** (`sub.example.com`) or shared path (`/sub/`, `/json/`).
- **Standalone Web Management Panel (`/deploy/`)**: Automatically enabled when a domain is configured for the main panel and served exclusively over HTTPS on that domain at `/deploy/` (never modifying 3X-UI routes or exposing on subscription domains). Built with zero-dependency Python 3 stdlib + a mobile-first responsive UI featuring scrypt authentication, CSRF/Origin checks, session & idle timeout management, live SSE operation progress console & persistent history, full SSL/TLS certificate management (issue, renew, apply, revoke), domain/DNS/listen-IP/BBR/firewall controls, compatibility & deployment operations, probe-redirection manager + live simulator, decoy theme designer, backup/restore/cron automation, audit runner, and multi-source log viewer.
- **Security Audit (`audit`)**: Built-in compliance & configuration audit verifying default credentials, 2FA, session timeouts, TLS/loopback isolation, subscription domain consistency, 3X-UI compatibility status, WebPanel isolation & permissions, probe-redirect config validity, Caddy socket/header hardening, secret file permissions, Fail2ban, and firewall status.
- **Multi-Protocol Inbounds & Routing**: Inspect SQLite/PostgreSQL Xray inbounds (`list`), verify live TCP/UDP sockets & port conflicts (`verify`), automatically expose loopback `ws`/`httpupgrade`/`xhttp`/`splithttp`/`grpc` inbounds behind Caddy HTTPS (`sync-proxy`), and sync exact TCP/UDP/both firewall rules for enabled public inbounds (`sync-fw`).
- **TLS Certificate Lifecycle**: Issue Let's Encrypt standalone certificates (with automatic `/etc/letsencrypt/renewal-hooks/deploy/` sync & container restart), renew/sync all certs, or generate 10-year ECDSA P-256 self-signed certs with SANs.
- **Online Backups, Upload Restore & Cron**: Consistent SQLite `.backup` and PostgreSQL `pg_dump`, pre-restore safety snapshots, local-to-remote archive upload restores, archive pruning, and daily automated cron backups.
- **VPS Diagnostics & Network Tuning**: Single-trip health dashboard (CPU/RAM/Swap/Disk, BBR state, container stats, Fail2ban, cert expiry alerts), one-click TCP BBR + socket buffer sysctl tuning, UFW/Firewalld helper, and Xray GeoIP/GeoSite updaters (`Loyalsoldier`, `Iran`, `Russia`).
- **Full CLI Automation**: Every major action can run headlessly via CLI flags for scripting and cron workflows.

---

## Quick Start & Installation via GitHub

### Option 1: Run Directly (No Clone Needed)

Launch the interactive TUI directly from GitHub:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IHosseini083/3xui-deploy/main/manage.sh)
```

Or via pipe (`manage.sh` automatically reattaches `/dev/tty` for interactive input):

```bash
curl -fsSL https://raw.githubusercontent.com/IHosseini083/3xui-deploy/main/manage.sh | bash
```

### Option 2: Install Globally as `3xui-deploy`

Install to `/usr/local/bin/3xui-deploy` in one command:

```bash
curl -fsSL https://raw.githubusercontent.com/IHosseini083/3xui-deploy/main/manage.sh | sudo bash -s -- self-install
```

Then run from anywhere:

```bash
sudo 3xui-deploy
```

### Option 3: Manage a Remote VPS From Your Laptop

Connect straight to a remote server without cloning or installing on the VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IHosseini083/3xui-deploy/main/manage.sh) --remote root@YOUR_VPS_IP
```

Or run a single remote command headlessly:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IHosseini083/3xui-deploy/main/manage.sh) -r admin@YOUR_VPS_IP:2222 health
```

### Option 4: Git Clone

```bash
git clone https://github.com/IHosseini083/3xui-deploy.git
cd 3xui-deploy
chmod +x manage.sh
./manage.sh
```

---

## CLI Usage & Commands

```text
manage.sh [OPTIONS] [COMMAND] [ARGS]
```

### Options

| Flag | Description |
| :--- | :--- |
| `-r, --remote <target>` | Target a remote VPS (`[user@]host[:port]`, IPv6 supported via `[addr]:port`) |
| `-l, --local` | Force local execution mode |
| `-d, --dir <path>` | Override installation directory (default: `/opt/3x-ui`) |
| `-y, --yes` | Auto-confirm confirmation prompts |
| `-v, --verbose` | Enable debug logging output |
| `--force-compat` | Override unsupported 3X-UI version or preflight checks |
| `-h, --help` | Show CLI help |

### Commands

| Command | Description |
| :--- | :--- |
| *(none)* | Launch the interactive TUI menu |
| `deploy` | Install Docker if missing and deploy 3X-UI |
| `status` | Show container status and live panel URL |
| `start` / `stop` / `restart` | Control the Docker Compose stack |
| `update [tag]` | Pull, preflight-check, and apply 3X-UI release with automatic rollback |
| `rollback` | Restore `compose.yaml.bak` and recreate containers |
| `compat [check\|matrix\|test <tag>]` | Inspect 3X-UI version compatibility, DB schema & preflight image contract |
| `logs [follow\|all\|N\|deploy]` | View container logs or `3xui-deploy` diagnostic log (`logs deploy`) |
| `backup` | Create a timestamped backup in `/opt/3x-ui-backups` |
| `restore [archive]` | Restore a backup archive (with pre-restore safety snapshot) |
| `health` | Run system, Docker, Xray, Fail2ban, and cert diagnostics |
| `bbr` | Enable TCP BBR + FQ + proxy socket tuning (`/etc/sysctl.d/99-3xui-optimizer.conf`) |
| `geo-update [std\|ir\|ru\|all]` | Update Xray `geoip*.dat` and `geosite*.dat` with automatic rollback |
| `settings` | Open the Panel Settings & Security menu |
| `certs` | Open the Certificate Management menu |
| `proxy [setup\|status\|verify\|reload\|probe\|check-redirect\|disable]` | Manage Caddy reverse proxy, multi-page decoy site, probe redirection & subscription domains |
| `webpanel [enable\|disable\|status\|reset-password\|logs]` | Manage standalone Web Management Panel (`/deploy/`) |
| `inbounds [list\|verify\|sync-proxy\|sync-fw]` | List Xray inbounds, verify TCP/UDP sockets, sync Caddy routes & firewall rules |
| `audit` | Run the built-in security & configuration audit |
| `self-install` | Install `manage.sh` globally to `/usr/local/bin/3xui-deploy` |
| `self-update` | Update `manage.sh` / `/usr/local/bin/3xui-deploy` from GitHub `main` |

---

## Documentation

- [Usage & Feature Guide](docs/USAGE.md) — TUI controls, remote SSH setup, backups, certs, BBR, firewall, and GeoIP updates
- [Security & Hardening Guide](docs/SECURITY.md) — Post-install checklist and script security design

## License

Released under the [MIT License](LICENSE).
