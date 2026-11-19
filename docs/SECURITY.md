# Security & Hardening Guide

## Recommended Post-Deploy Checklist

1. **Change default `admin / admin` credentials immediately** via the post-deploy hardening prompt or **Panel settings & security** (enforces >= 12-char password complexity or auto-generates a 20-char password, transmitted over stdin).
2. **Set a non-standard port, random `webBasePath`, and finite `sessionMaxAge`** (e.g., `60` minutes) so automated scanners and stale browser sessions cannot abuse administrative endpoints.
3. **Put the panel behind the Caddy reverse proxy (or enable panel TLS)**: Use **Reverse proxy (Caddy)** (`manage.sh proxy setup`) to bind 3X-UI and the subscription server to `127.0.0.1`, sync `webDomain` / `subDomain`, serve a neutral decoy site on `/`, and proxy only your random `webBasePath` and subscription routes over HTTPS.
4. **Enable Two-Factor Authentication (2FA)** inside the 3X-UI web settings (and remember `manage.sh settings` can reset it via CLI if you ever lose your authenticator).
5. **Keep Fail2ban enabled and VMess AEAD forced** (`XUI_ENABLE_FAIL2BAN: "true"` and `XRAY_VMESS_AEAD_FORCED: "true"` in `compose.yaml`).
6. **Use SSH key authentication**: `manage.sh` keeps any interactive SSH password in memory only for the active session (`ControlPersist=15m`, `ForwardAgent=no`, `ForwardX11=no`, `ClearAllForwardings=yes`) and never writes `SSH_PASS_B64` to `~/.3xui-manager.conf`. Use **Target & SSH manager → Install SSH public key & clear saved password** to migrate legacy configs and enable key-only logins.
7. **Restrict firewall ports** using **Firewall helper** (`inbounds sync-fw`) so only SSH, active Xray inbound ports, and either Caddy (`80/tcp` + `<PROXY_PORT>/tcp+udp`) or direct panel/subscription ports are exposed.
8. **Run `manage.sh audit`** regularly to verify credentials, 2FA, session expiry, TLS/loopback isolation, subscription consistency, container hardening, file permissions, Fail2ban, and firewall status.

---

## Script Security Model

- **Input Validation & Quoting**: User-supplied inputs (ports, IPv4/IPv6 listen addresses, domains, emails, image tags, bounded web paths, non-system absolute paths, Postgres identifiers, SSH hosts/users, and strong passwords) are validated and escaped with `quote_sh` before local or remote shell execution.
- **No Shell Sourcing & Permission-Checked Configs**: `~/.3xui-manager.conf` is parsed line-by-line with strict key/regex checks instead of `source`, and `load_config` refuses symlinks, wrong-owner files, or world-writable permissions while tightening loose modes to `0600`.
- **No Secrets in Process Arguments or Compose Files**:
  - Panel credential resets pipe passwords over `stdin` (`_xui_set_credentials_stdin`) instead of CLI `-password=` arguments.
  - PostgreSQL `XUI_DB_DSN` is stored in `$INSTALL_DIR/.env` (`chmod 600`) and injected via `env_file`, keeping `compose.yaml` free of database passwords and enabling `scram-sha-256` auth.
  - `sshpass` receives passwords via `SSHPASS` env (`sshpass -e`) instead of `-p`, and passwords are not persisted to disk.
- **Container & Reverse Proxy Hardening**:
  - Containers set `no-new-privileges:true`; `3xui_caddy` additionally applies `cap_drop: ALL` with only `NET_BIND_SERVICE`.
  - Caddy's admin API is isolated to `unix//config/admin.sock` inside a `0700` directory instead of TCP `127.0.0.1:2019`.
  - Security headers (`HSTS`, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`, `X-Robots-Tag`, decoy `CSP`, `Cache-Control: no-store` on subscriptions) and request-body limits are enforced automatically.
- **Tar-Slip & Symlink Protection on Restores**: `_validate_tar_archive` inspects `tar -tzf` and `tar -tvzf` before extraction to reject absolute paths, `..` traversal, symlinks, hardlinks, device nodes, and FIFOs, and extracts with `--no-same-owner --no-same-permissions`.
- **Private Directories, TLS Downloads & Integrity Checks**:
  - SSH ControlMaster sockets use `${XDG_RUNTIME_DIR:-$HOME/.ssh}/3xui_mux/` (`chmod 700`).
  - Temporary directories for backups, restores, uploads, SSL config generation, and downloads use `mktemp -d` (`chmod 700`) and are cleaned up unconditionally.
  - Sensitive files (`.env`, `compose.yaml`, `compose.yaml.bak`, `privkey.pem`, `~/.3xui-manager.conf`, `caddy/proxy.conf`, backup `.tar.gz` archives) are created under `umask 077` with `0600` permissions.
  - All HTTPS downloads enforce `--proto '=https' --tlsv1.2` (`--https-only --secure-protocol=TLSv1_2` for `wget`); `lazydocker` binaries are verified against release `checksums.txt` (`sha256sum`); and `self-install` / `self-update` validate shebang, marker, and `bash -n` before atomic `install`.
