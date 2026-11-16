# Usage & Feature Guide

## Interactive TUI Controls

The arrow-key TUI (`tui_select`) automatically sizes to your terminal height and supports:

- `↑` / `↓` or `k` / `j` — Move selection up/down (wraps around; skips section headers)
- `1`–`9` — Jump directly to the 1st–9th selectable option
- `g` / `Home` and `G` / `End` — Jump to top or bottom
- `PageUp` / `PageDown` — Scroll by page
- `Enter` — Execute selected item
- `q` / `Esc` — Back / Exit

---

## Local vs. Remote SSH Execution

When started without flags, `manage.sh` scores environment hints (`DISPLAY`, `uname`, WSL, Docker Desktop, DMI vendor, `systemd-detect-virt`, and cloud metadata only when ambiguous):

- **Workstation / macOS / WSL**: Offers **Connect to remote VPS via SSH** or **Run locally**.
- **VPS / Server**: Runs locally (offering `sudo` re-exec if needed) or connects to another VPS.

### SSH Multiplexing & Key Migration

Connection details are saved in `~/.3xui-manager.conf` (`chmod 600`), and persistent ControlMaster sockets live in `${XDG_RUNTIME_DIR:-$HOME/.ssh}/3xui_mux/mux-%C` (`chmod 700`) with a 1-hour persist window.

Use **Target & SSH manager → Install SSH public key & clear saved password** to:
1. Locate `~/.ssh/id_ed25519.pub` (or `id_ecdsa.pub` / `id_rsa.pub`), or generate a new Ed25519 key pair.
2. Append it safely to `~/.ssh/authorized_keys` on the VPS.
3. Verify `BatchMode=yes` login, switch config to key auth, and wipe `SSH_PASS_B64` from `~/.3xui-manager.conf`.

---

## Deployment, Upgrades & Rollbacks

1. **Deploy / Install**: Installs Docker + Compose plugin if missing, lets you choose **SQLite** or **PostgreSQL**, fetches the latest release tag from `mhsanaei/3x-ui`, generates `/opt/3x-ui/compose.yaml` (and `.env` for PostgreSQL), starts containers, and runs the optional **Post-Deploy Hardening** wizard.
2. **Update to latest version / Change version manually**: Backs up `compose.yaml` to `compose.yaml.bak`, updates the image tag cleanly via `awk`, pulls the image, and runs `compose up -d`.
3. **Rollback version**: Displays current vs. backup image tags and restores `compose.yaml.bak`.

Environment overrides:
- `XUI_INSTALL_DIR` (or `-d, --dir`): default `/opt/3x-ui`
- `XUI_BACKUP_DIR`: default `/opt/3x-ui-backups`

---

## Panel Settings & Security

Under **Panel settings & security** (`manage.sh settings`), `x-ui setting` queries and updates the running container (`3xui_app`):

- **Show full panel settings**: Prints `x-ui setting -show=true`, `-getCert=true`, and the computed `http(s)://ip:port/path/` URL.
- **Change panel port**: Updates `-port` (validated `1–65535`).
- **Change / randomize Web Base Path**: Updates `-webBasePath` or generates a random `/12chars/` path.
- **Reset admin username & password**: Prompts for username/password (or auto-generates a 16-character alphanumeric password).
- **Reset / Disable 2FA**: Calls `x-ui setting -resetTwoFactor=true` if locked out of TOTP.

---

## Certificate Management

Under **Manage certificates** (`manage.sh certs`):

- **Issue Let's Encrypt cert (certbot standalone)**: Stops `3xui_app` briefly if running so port `80` is available, issues via `certbot certonly --standalone`, copies dereferenced files (`cp -L`) into `/opt/3x-ui/cert/<domain>/`, installs `/etc/letsencrypt/renewal-hooks/deploy/3xui-cert-sync.sh`, restarts the panel, and offers to apply `-webCert` / `-webCertKey`.
- **Renew & sync all certbot certs**: Runs `certbot renew`, syncs all domains under `/opt/3x-ui/cert/`, and restarts the container.
- **Generate self-signed cert (ECDSA P-256)**: Generates a 10-year `prime256v1` certificate with `DNS:` or `IP:` SANs (useful for Cloudflare Full SSL or IP-only HTTPS panels).
- **Set panel TLS cert**: Lists folders in `/opt/3x-ui/cert/` and configures `-webCert` / `-webCertKey`.

---

## Backups, Upload Restores & Scheduled Cron

Under **Backup & restore**:

- **Create backup now**: Takes a consistent SQLite online `.backup` (if `sqlite3` is available in container or host), `pg_dump` (when `3xui_postgres` is running), `cert/`, `compose.yaml`, `.env`, and `pgdata/` into `/opt/3x-ui-backups/backup_<timestamp>.tar.gz` (`chmod 600`). In remote mode, offers immediate SCP download to `./3xui-backups/`.
- **Restore backup**: Supports choosing from remote archives or uploading a local `.tar.gz` file. Creates a `pre_restore_<timestamp>.tar.gz` safety snapshot before replacing `db/`, `cert/`, `pgdata/` (or restoring `postgres_dump.sql` if `pgdata/` is absent).
- **Scheduled daily backup (cron)**: Installs `/usr/local/bin/3xui-auto-backup.sh` and `/etc/cron.d/3xui-backup` at your chosen UTC/server hour with configurable retention (default `7` archives).
- **Prune old backups**: Retains the newest `N` archives and removes older tarballs.

---

## VPS Network, Firewall & GeoIP Assets

- **Health & diagnostics (`health`)**: Displays OS, kernel, CPU/RAM/Swap/Disk, active TCP congestion control/qdisc, public IPv4/IPv6, `docker stats`, panel URL, Xray process, Fail2ban bans, and flags TLS certificates expiring within 14 days.
- **BBR & network tuning (`bbr`)**: Writes `/etc/sysctl.d/99-3xui-optimizer.conf` enabling `fq` + `bbr`, 16 MB TCP/UDP buffers (`rmem_max`/`wmem_max`), `tcp_mtu_probing=1`, `tcp_fastopen=3`, and `somaxconn=4096`.
- **Firewall helper**: Supports `ufw` and `firewalld` to inspect rules, open custom TCP/UDP ports, or auto-allow SSH + Panel + active `xray` listening ports.
- **Update GeoIP / GeoSite (`geo-update`)**: Downloads validated `.dat` databases (`> 10 KB`) into `3xui_app:/app/bin/` and restarts the container:
  - `std`: `geoip.dat` & `geosite.dat` from `Loyalsoldier/v2ray-rules-dat`
  - `ir`: adds `geoip_IR.dat` & `geosite_IR.dat` from `chocolate4u/Iran-v2ray-rules`
  - `ru`: adds `geoip_RU.dat` & `geosite_RU.dat` from `runetfreedom/russia-v2ray-rules-dat`
  - `all`: all three sets
