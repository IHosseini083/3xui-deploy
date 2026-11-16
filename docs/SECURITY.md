# Security & Hardening Guide

## Recommended Post-Deploy Checklist

1. **Change default `admin / admin` credentials immediately** via the post-deploy hardening prompt or **Panel settings & security**.
2. **Set a non-standard port and random `webBasePath`** (e.g., `/x9K2pQ7mR4vL/`) so automated scanners do not find the login form.
3. **Enable TLS on the panel** using Let's Encrypt or an ECDSA self-signed certificate behind Cloudflare/reverse proxy so panel logins and API tokens are encrypted in transit.
4. **Enable Two-Factor Authentication (2FA)** inside the 3X-UI web settings (and remember `manage.sh settings` can reset it via CLI if you ever lose your authenticator).
5. **Keep Fail2ban enabled** (`XUI_ENABLE_FAIL2BAN: "true"` with `NET_ADMIN` + `NET_RAW` in `compose.yaml`) to enforce per-client IP limits and login brute-force bans.
6. **Migrate SSH access to keys** via **Target & SSH manager → Install SSH public key & clear saved password**, removing password obfuscation from `~/.3xui-manager.conf`.
7. **Restrict firewall ports** using **Firewall helper** so only SSH, your panel port (or restrict panel port to your VPN/home IP), and active Xray inbound ports are exposed.

---

## Script Security Model

- **Input Validation & Quoting**: User-supplied inputs (ports, domains, emails, image tags, web paths, Postgres identifiers, SSH hosts/users, and passwords) are validated and escaped with `quote_sh` before local or remote shell execution.
- **No Shell Sourcing of Configs**: `~/.3xui-manager.conf` is parsed line-by-line with strict key/regex checks instead of `source`, preventing arbitrary code execution from malformed config files.
- **No Passwords in Process Arguments**: `sshpass` receives passwords via the `SSHPASS` environment variable (`sshpass -e`) instead of `-p`, preventing leakage in `ps` / `/proc/<pid>/cmdline`.
- **Private Directories & Staging**:
  - SSH ControlMaster sockets use `${XDG_RUNTIME_DIR:-$HOME/.ssh}/3xui_mux/` (`chmod 700`).
  - Temporary directories for backups, restores, SSL config generation, and geo-asset downloads are created with `mktemp -d` (`chmod 700`) and cleaned up unconditionally.
  - Sensitive files (`.env`, `compose.yaml`, `privkey.pem`, `~/.3xui-manager.conf`, backup `.tar.gz` archives) are written with `0600` permissions.
- **Safe `self-update` / `self-install`**: Downloaded scripts are checked to be non-empty and validated with `bash -n` before replacing any binary on disk.
