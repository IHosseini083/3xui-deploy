---
name: decoy-probe-engineering
description: >-
  Guides development of the multi-page static decoy website, Caddy v2 probe/scanner
  detection rules, SSRF-safe redirection targets, and safe fallback transitions in
  manage.sh and webpanel/probe.py. Use when changing decoy templates, Caddyfile routing,
  or bot/scanner detection logic.
---

# Decoy Website & Probe Redirection Engineering

Use this skill when modifying `generate_decoy_site`, `_caddy_probe_redirect_blocks`, `generate_caddyfile`, or `webpanel/probe.py`.

## Architectural Constraints

1. **Zero Info Leakage in Decoy Assets**:
   - The decoy site (`$INSTALL_DIR/caddy/site/`) must look like an authentic, functional multi-page static website (`index.html`, `services.html`, `docs.html`, `about.html`, `contact.html`, `404.html`, `assets/style.css`, `assets/app.js`, `favicon.svg`, `robots.txt`, `sitemap.xml`).
   - Never include `3x-ui`, `3xui`, `xray`, `vless`, `vmess`, or `proxy` strings or comments in any file served under `caddy/site/`. Use `<!-- static-site-template:v2 -->` as the managed marker.
   - Keep zero external CDN links and zero inline scripts/handlers so strict CSP (`default-src 'self'; script-src 'self'; style-src 'self'`) passes cleanly.

2. **Caddy v2 Syntax & Route Ordering**:
   - Define all named matchers (`@panel`, `@webpanel`, `@sub`, `@subjson`, `@inbound_*`, `@probe_*`, `@decoy_exists`) at the **site block level** (never nested inside `handle { ... }`).
   - Order mutually-exclusive `handle` blocks strictly:
     1. `handle @panel` (3x-ui panel)
     2. `handle @webpanel` (panel vhost only, stripped prefix)
     3. `handle @sub` / `handle @subjson`
     4. `handle @inbound_*` (loopback Xray transports)
     5. `handle @probe_*` (`cidr`, `method`, `missing_ua`, `empty_ua`, `ua`, `path`)
     6. `handle @decoy_exists` (`file { root /srv/site; try_files {path} {path}.html {path}/index.html } }`)
     7. `handle` catch-all (`/404.html` with `status 404`)
   - Use `not header User-Agent *` (never `header !User-Agent`) for missing User-Agent detection, and `not method GET HEAD OPTIONS` for unusual methods.

3. **Safe Fallback & Parity**:
   - Always keep Bash (`manage.sh`) and Python (`webpanel/probe.py`) validation, `probe.conf` schema, and simulator rule ordering synchronized.
   - Never allow loopback, private, link-local, or internal hostnames in `PROBE_REDIRECT_TARGET` or `PROBE_FALLBACK_URL`.
   - Always exclude `127.0.0.1`, `::1`, `PROBE_ALLOW_CIDRS`, and any path overlapping `PANEL_PATH`, `WEBPANEL_PATH`, `SUB_PATH`, `SUB_JSON_PATH`, or `@inbound_*` from probe redirection.

## Verification

1. Run `bash tests/test_manage.sh` to verify decoy content, path collision filtering, Caddyfile matchers, and fallback state rendering.
2. Run `python3 -m unittest tests/test_webpanel.py -v` to verify `webpanel/probe.py` SSRF checks and traffic simulation parity.
3. On a Docker host with Caddy, run `docker exec 3xui_caddy caddy validate --config /etc/caddy/Caddyfile`.
