# 3X-UI Deploy & VPS Manager

[![CI](https://github.com/IHosseini083/3xui-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/IHosseini083/3xui-deploy/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A zero-dependency Bash TUI & CLI manager for deploying, hardening, monitoring, and maintaining the [mhsanaei/3x-ui](https://github.com/mhsanaei/3x-ui) Xray panel via Docker Compose — **locally on a VPS or remotely from your workstation over multiplexed SSH**.

---

## Key Features

- **Local & Remote SSH Management**: Auto-detects VPS vs. workstation environments, persists persistent SSH `ControlMaster` sockets (`mux-%C`) with zero password leaks in process lists (`SSHPASS` env mode), and includes a built-in SSH public-key installer.
- **SQLite or PostgreSQL Deployment**: Automatic Docker & Compose installation, GitHub release resolution without API rate-limit failures, Docker log rotation (`10m` × `3`), loopback-bound PostgreSQL (`127.0.0.1:5432`) with healthchecks, and `.env` credential isolation (`chmod 600`).
- **Immediate Panel Hardening & Settings**: Guided post-deploy hardening plus a settings menu to change or randomize the listening port, `webBasePath`, admin credentials, and reset 2FA (`x-ui setting`).
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
| `-h, --help` | Show CLI help |

### Commands

| Command | Description |
| :--- | :--- |
| *(none)* | Launch the interactive TUI menu |
| `deploy` | Install Docker if missing and deploy 3X-UI |
| `status` | Show container status and live panel URL |
| `start` / `stop` / `restart` | Control the Docker Compose stack |
| `update` | Pull and apply the latest 3X-UI release tag |
| `rollback` | Restore `compose.yaml.bak` and recreate containers |
| `logs [follow\|all\|N]` | View container logs (default: last `100` lines) |
| `backup` | Create a timestamped backup in `/opt/3x-ui-backups` |
| `restore [archive]` | Restore a backup archive (with pre-restore safety snapshot) |
| `health` | Run system, Docker, Xray, Fail2ban, and cert diagnostics |
| `bbr` | Enable TCP BBR + FQ + proxy socket tuning (`/etc/sysctl.d/99-3xui-optimizer.conf`) |
| `geo-update [std\|ir\|ru\|all]` | Update Xray `geoip*.dat` and `geosite*.dat` inside `3xui_app:/app/bin/` |
| `settings` | Open the Panel Settings & Security menu |
| `certs` | Open the Certificate Management menu |
| `self-install` | Install `manage.sh` globally to `/usr/local/bin/3xui-deploy` |
| `self-update` | Update `manage.sh` / `/usr/local/bin/3xui-deploy` from GitHub `main` |

---

## Documentation

- [Usage & Feature Guide](docs/USAGE.md) — TUI controls, remote SSH setup, backups, certs, BBR, firewall, and GeoIP updates
- [Security & Hardening Guide](docs/SECURITY.md) — Post-install checklist and script security design

## License

Released under the [MIT License](LICENSE).
