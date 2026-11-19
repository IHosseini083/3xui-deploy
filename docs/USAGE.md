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

Connection details are saved in `~/.3xui-manager.conf` (`chmod 600`), and persistent ControlMaster sockets live in `${XDG_RUNTIME_DIR:-$HOME/.ssh}/3xui_mux/mux-%C` (`chmod 700`) with a 15-minute persist window.

Use **Target & SSH manager → Install SSH public key & clear saved password** to:
1. Locate `~/.ssh/id_ed25519.pub` (or `id_ecdsa.pub` / `id_rsa.pub`), or generate a new Ed25519 key pair.
2. Append it safely to `~/.ssh/authorized_keys` on the VPS.
3. Verify `BatchMode=yes` login, switch config to key auth, and wipe `SSH_PASS_B64` from `~/.3xui-manager.conf`.

---

## Deployment, Forward Compatibility, Upgrades & Rollbacks

1. **Deploy / Install**: Installs Docker + Compose plugin if missing, lets you choose **SQLite** or **PostgreSQL**, fetches the latest release tag from `mhsanaei/3x-ui`, generates `/opt/3x-ui/compose.yaml` (and `.env` for PostgreSQL), starts containers, and runs the optional **Post-Deploy Hardening** wizard.
2. **Forward Compatibility (`compat`)**: Run `3xui-deploy compat check`, `compat matrix`, or `compat test <tag>` to inspect the detected 3X-UI release (`v2.x`–`v3.x`), Go binary path, DB schema (`settings` & `inbounds`), and CLI flags. Unsupported versions (`< v2.0.0` or `>= v4.0.0`) are blocked unless `--force-compat` is explicitly passed.
3. **Safe Updates & Auto-Rollback (`update [tag]`)**: Pulls and preflight-checks the candidate image *before* modifying `compose.yaml`, saves `compose.yaml.bak` + a `pre_update` archive, updates containers, verifies DB schema and live panel/subscription endpoints, and automatically rolls back to `compose.yaml.bak` if startup or verification fails.
4. **Structured Logging (`logs deploy`)**: Staged operational logs (`INFO`, `OK`, `WARN`, `ERROR`, `CRITICAL`) with automatic secret redaction are written to `$INSTALL_DIR/logs/3xui-deploy.log` (or `~/.3xui-deploy.log`).
5. **Rollback version**: Displays current vs. backup image tags and restores `compose.yaml.bak`.

Environment overrides:
- `XUI_INSTALL_DIR` (or `-d, --dir`): default `/opt/3x-ui`
- `XUI_BACKUP_DIR`: default `/opt/3x-ui-backups`

---

## Panel Settings & Security

Under **Panel settings & security** (`manage.sh settings`), `x-ui setting` queries and updates the running container (`3xui_app`):

- **Show full panel & subscription settings**: Prints `x-ui setting -show=true`, `-getListen=true`, `-getCert=true`, `webDomain`, `sessionMaxAge`, 2FA status, subscription DB configuration, and the effective URL.
- **Change panel port**: Updates `-port` (validated `1–65535`).
- **Change panel listen IP (`webListen`)**: Binds the panel to `0.0.0.0` / blank (all interfaces), `127.0.0.1`, `::1`, or a specific host interface IP (with loopback validation warning if Caddy proxy is active).
- **Change / randomize Web Base Path**: Updates `-webBasePath` or generates a random `/12chars/` path.
- **Configure subscription domain & network**: Works in both Caddy reverse-proxy mode (`127.0.0.1` loopback + `subDomain` + `subURI` + `subJsonEnable` + `subJsonURI` + Caddy sync) and direct mode (`subListen`, `subDomain`, `subPort`, optional TLS cert), followed by live endpoint & DNS verification.
- **Harden auth, session & web domain**: Sets `sessionMaxAge` (`5–10080` minutes, recommended `60`) and `webDomain` (enforcing strict `Host` validation).
- **Reset admin username & password**: Enforces password strength rules (min 12 chars, no control chars or weak defaults, >= 16 chars or >= 2 classes) or auto-generates a 20-character password, passed securely over stdin (`_xui_set_credentials_stdin`).
- **Reset / Disable 2FA**: Calls `x-ui setting -resetTwoFactor=true` if locked out of TOTP.

---

## Reverse Proxy (Caddy), Multi-Page Decoy Website & Probe Redirection

Under **Reverse proxy (Caddy)** (`manage.sh proxy`), `manage.sh` runs `caddy:2-alpine` (`3xui_caddy`) inside `/opt/3x-ui/compose.yaml` with `network_mode: host`:

- **Loopback Isolation & Host Synchronization**: Automatically locks 3X-UI's panel (`webListen`) and subscription server (`subListen`) to `127.0.0.1`, sets `webDomain` and `subDomain` in 3X-UI's database to prevent `DomainValidatorMiddleware` `403` mismatches or `X-Real-IP` fallback issues, clears direct panel/sub TLS so Caddy terminates HTTPS cleanly, and sends `Host`, `X-Forwarded-Host`, `X-Forwarded-Port`, `X-Real-IP`, `X-Forwarded-For`, and `X-Forwarded-Proto` upstream.
- **Legitimate Multi-Page Decoy Site (`/`)**: Requires a non-root `webBasePath` (offers to auto-generate one if currently `/`) and serves a multi-page static website (`index.html`, `services.html`, `docs.html`, `about.html`, `contact.html`, `404.html`, local CSS/JS, `robots.txt`, `sitemap.xml`) under `/opt/3x-ui/caddy/site/` with three selectable themes (`cloud`, `studio`, `docs`) and strict CSP headers. Use **Customize decoy site** to pick a theme, edit HTML, upload custom HTML, or reset.
- **Configurable Probe & Bot Redirection (`proxy probe` / WebPanel)**: Optionally redirect detected vulnerability scanners, CLI tools, missing/empty User-Agents, unusual HTTP methods, blocked CIDRs, or exploit probe paths (`/.env`, `/.git`, `/wp-admin`, etc.) to a custom external URL (e.g., `https://www.cloudflare.com`, `https://www.speedtest.net`). Legitimate browser traffic and protected routes (`PANEL_PATH`, `/deploy/`, `/sub/`, `/json/`, loopback inbounds) are never redirected. Automatic health checks fall back safely to the decoy website, a secondary URL, or a decoy `404` page if the redirect destination becomes unreachable.
- **Custom HTTPS Port (Xray Reality Coexistence)**: Defaults to `443`, or lets you choose a custom port (e.g. `8443`) while disabling Caddy's `TLS-ALPN-01` challenge (`disable_tlsalpn_challenge`) so port `443` stays free for Xray VLESS/Reality (uses HTTP-01 on port `80`, or existing certs under `/opt/3x-ui/cert/<domain>/`).
- **Subscription Proxy Modes**:
  1. **Dedicated subscription domain** (e.g., `sub.example.com`): Creates an isolated vhost proxying `/sub/*` and `/json/*` to `127.0.0.1:<subPort>`, serving the decoy site on `/`, enabling `subJsonEnable` and `subEncrypt`, and setting `subDomain`, `subURI`, and `subJsonURI` in 3X-UI's database.
  2. **Same domain as panel** (e.g., `panel.example.com/sub/` & `/json/`): Proxies subscriptions alongside the panel under the same domain.
  3. **Disabled**: Proxies only the panel (clearing any stale loopback `subListen` or proxy `subURI` overrides).
- **Auto-Sync, DNS & Endpoint Verification (`proxy verify`)**: Changing panel port, `webBasePath`, probe rules, or subscription settings automatically regenerates `Caddyfile` (with automatic rollback on validation error) and reloads Caddy via its isolated Unix admin socket (`unix//config/admin.sock`).

---

## Standalone Web Management Panel (`/deploy/`)

When you configure a panel domain via `proxy setup` (or set `webDomain` in Panel Settings and enable proxy), `3xui-deploy` automatically installs and starts the standalone **Web Management Panel** (`3xui-deploy-web.service`):

- **Exclusive Domain & Dedicated Path**: Bound strictly to `127.0.0.1` (`2059`) and reverse-proxied exclusively under the main panel domain (`https://panel.example.com/deploy/`), automatically selecting a non-overlapping path if `/deploy/` collides with existing panel/subscription routes. Never mounted on dedicated subscription domains (`sub.example.com`).
- **Capabilities**: View system metrics & container status, start/stop/restart stack, run 3X-UI compatibility & preflight checks, execute rollback-safe updates, configure decoy themes and probe redirection rules (including live target health tester and request simulator), inspect Xray inbounds, run `audit`, create/prune backups, update GeoIP/GeoSite datasets, and filter `3xui-deploy` / audit / container logs.
- **CLI Commands**: `webpanel enable`, `webpanel status`, `webpanel reset-password`, `webpanel logs`, `webpanel disable`.

---

## Security Audit (`audit`)

Run `manage.sh audit` (or select **Security audit** in the TUI) to inspect default credentials, 2FA, `sessionMaxAge`, `webBasePath`, loopback/TLS isolation, subscription domain consistency, Caddy Unix admin socket & container hardening (`cap_drop`, `no-new-privileges`), secret file permissions, `XRAY_VMESS_AEAD_FORCED`, Fail2ban, firewall state, and local SSH config hygiene.

---

## Inbounds & Multi-Protocol Routing

Under **Inbounds & protocol routing** (`manage.sh inbounds`), `manage.sh` inspects the 3X-UI SQLite or PostgreSQL `inbounds` table directly alongside host listening sockets (`ss -tulnp`):

- **Inspect inbounds (`inbounds list`)**: Displays each inbound's ID, enabled state, protocol (`vless`, `vmess`, `trojan`, `shadowsocks`, `hysteria2`, `wireguard`, `tuic`, `dokodemo-door`, etc.), bind address, port, transport/security (`tcp`, `ws`, `grpc`, `httpupgrade`, `xhttp`, `kcp`, `tls`, `reality`), firewall layer (`tcp`/`udp`/`both`), live kernel socket status, and Caddy/direct route.
- **Verify listeners & conflicts (`inbounds verify`)**: Detects duplicate inbound ports, collisions between public inbounds and Caddy (`PROXY_PORT` / TCP `80`) or direct `PANEL_PORT`, empty or colliding Caddy paths, and missing live TCP/UDP sockets.
- **Sync loopback transports to Caddy (`inbounds sync-proxy`)**: Any enabled inbound bound to loopback (`127.0.0.1` / `::1`) using `ws`, `httpupgrade`, `xhttp`, `splithttp`, or `grpc` with a unique non-root path/serviceName is automatically added to `Caddyfile` (using `h2c://` upstream transport for `grpc`) and reloaded without exposing its backend port publicly.
- **Sync TCP/UDP firewall rules (`inbounds sync-fw`)**: Automatically opens exact `tcp`, `udp` (`wireguard`, `hysteria`/`hysteria2`, `tuic`, `kcp`/`quic`), or `tcp+udp` (`shadowsocks`, `dokodemo-door`, `mixed`, `socks`) rules in `ufw`/`firewalld` for enabled public inbounds while skipping internal loopback inbounds fronted by Caddy.

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
