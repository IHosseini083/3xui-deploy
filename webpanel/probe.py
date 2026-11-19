"""Decoy site configuration, probe redirection validation, health probing, and request simulator."""

from __future__ import annotations

import datetime as dt
import ipaddress
import json
import os
import re
import ssl
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

DOMAIN_RE = re.compile(
    r"^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$"
)
EMAIL_RE = re.compile(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$")
FORBIDDEN_URL_CHARS = re.compile(r"[\x00-\x1f\x7f\s\"'<>`{}\[\];\\]")

DECOY_THEMES = ("cloud", "studio", "docs")
REDIRECT_STATUSES = ("301", "302", "307")
FALLBACK_MODES = ("decoy", "secondary_url", "not_found")

SCANNER_UA_PATTERNS = (
    "nikto",
    "sqlmap",
    "nmap",
    "masscan",
    "zgrab",
    "gobuster",
    "dirbuster",
    "nuclei",
    "ffuf",
    "wpscan",
    "acunetix",
    "nessus",
    "openvas",
    "censys",
    "shodan",
    "httpx",
    "feroxbuster",
    "wfuzz",
    "hydra",
    "jaeles",
)

CRAWLER_UA_PATTERNS = (
    "ahrefsbot",
    "semrushbot",
    "mj12bot",
    "dotbot",
    "petalbot",
    "bytespider",
    "gptbot",
    "ccbot",
    "claudebot",
    "yandexbot",
    "bingbot",
    "googlebot",
    "baiduspider",
)

CLI_UA_PATTERNS = (
    "curl/",
    "wget/",
    "python-requests",
    "python-urllib",
    "aiohttp",
    "go-http-client",
    "libwww-perl",
    "httpie",
    "okhttp",
    "axios/",
    "java/",
)

SUSPICIOUS_PATHS = (
    "/.env",
    "/.env.*",
    "/.git",
    "/.git/*",
    "/.svn/*",
    "/wp-admin",
    "/wp-admin/*",
    "/wp-login.php",
    "/xmlrpc.php",
    "/phpmyadmin",
    "/phpmyadmin/*",
    "/admin.php",
    "/config.php",
    "/cgi-bin/*",
    "/actuator",
    "/actuator/*",
    "/server-status",
    "/vendor/phpunit/*",
    "/boaform/*",
    "/HNAP1",
    "/shell",
    "/sdk",
)

DEFAULT_PROBE_CONFIG: dict[str, Any] = {
    "DECOY_THEME": "cloud",
    "DECOY_SITE_NAME": "Meridian Cloud Systems",
    "DECOY_SITE_TAGLINE": "Managed Edge Infrastructure & Reliability Engineering",
    "DECOY_CONTACT_EMAIL": "hello@meridiancloud.example",
    "PROBE_REDIRECT_ENABLED": False,
    "PROBE_REDIRECT_TARGET": "https://www.cloudflare.com",
    "PROBE_REDIRECT_STATUS": "302",
    "PROBE_FALLBACK_MODE": "decoy",
    "PROBE_FALLBACK_URL": "",
    "PROBE_CHECK_INTERVAL": 60,
    "PROBE_DETECT_SCANNERS": True,
    "PROBE_DETECT_CRAWLERS": False,
    "PROBE_DETECT_CLI": True,
    "PROBE_DETECT_EMPTY_UA": True,
    "PROBE_DETECT_BAD_METHODS": True,
    "PROBE_DETECT_PATHS": True,
    "PROBE_CUSTOM_UA": "",
    "PROBE_CUSTOM_PATHS": "",
    "PROBE_BLOCK_CIDRS": "",
    "PROBE_ALLOW_CIDRS": "",
}

BOOL_KEYS = frozenset(
    {
        "PROBE_REDIRECT_ENABLED",
        "PROBE_DETECT_SCANNERS",
        "PROBE_DETECT_CRAWLERS",
        "PROBE_DETECT_CLI",
        "PROBE_DETECT_EMPTY_UA",
        "PROBE_DETECT_BAD_METHODS",
        "PROBE_DETECT_PATHS",
    }
)


def _strip_quotes(val: str) -> str:
    if len(val) >= 2 and ((val[0] == '"' and val[-1] == '"') or (val[0] == "'" and val[-1] == "'")):
        return val[1:-1]
    return val


def normalize_redirect_url(raw: str) -> str:
    """Normalize user input like 'www.cloudflare.com' into 'https://www.cloudflare.com'."""
    text = (raw or "").strip()
    if not text:
        return ""
    if "://" not in text:
        text = "https://" + text
    return text


def _is_disallowed_ip(ip_obj: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    return bool(
        ip_obj.is_private
        or ip_obj.is_loopback
        or ip_obj.is_link_local
        or ip_obj.is_multicast
        or ip_obj.is_reserved
        or ip_obj.is_unspecified
    )


def validate_redirect_url(url: str) -> tuple[bool, str]:
    """Validate an external HTTP/HTTPS redirect destination against SSRF & injection."""
    if not url:
        return False, "Redirect URL cannot be empty."
    if len(url) > 512:
        return False, "Redirect URL is too long (max 512 chars)."
    if FORBIDDEN_URL_CHARS.search(url):
        return False, "Redirect URL contains forbidden whitespace, quotes, or Caddy syntax characters."

    try:
        parsed = urllib.parse.urlsplit(url)
    except ValueError:
        return False, "Malformed URL."

    if parsed.scheme.lower() not in ("http", "https"):
        return False, "Redirect URL must start with http:// or https://."
    if parsed.username or parsed.password:
        return False, "Redirect URL cannot contain embedded credentials."

    host = (parsed.hostname or "").strip().lower()
    if not host:
        return False, "Redirect URL is missing a hostname."
    if host in ("localhost",) or host.endswith((".localhost", ".local", ".internal")):
        return False, "Loopback or internal hostnames cannot be used as redirect targets."

    try:
        ip_obj = ipaddress.ip_address(host)
    except ValueError:
        if not DOMAIN_RE.fullmatch(host):
            return False, f"Invalid redirect hostname: {host}"
    else:
        if _is_disallowed_ip(ip_obj):
            return False, "Private, loopback, link-local, or reserved IPs cannot be used as redirect targets."

    if parsed.port is not None and not (1 <= parsed.port <= 65535):
        return False, "Invalid port in redirect URL."
    return True, ""


def validate_cidr_csv(raw: str) -> tuple[bool, list[str], str]:
    """Validate comma-separated IP addresses or CIDRs."""
    items: list[str] = []
    for part in (raw or "").split(","):
        token = part.strip()
        if not token:
            continue
        try:
            net = ipaddress.ip_network(token, strict=False)
        except ValueError:
            return False, [], f"Invalid IP/CIDR entry: {token}"
        items.append(str(net))
    return True, items, ""


def validate_token_csv(raw: str, is_path: bool = False) -> tuple[bool, list[str], str]:
    """Validate comma-separated custom User-Agent substrings or suspicious paths."""
    items: list[str] = []
    for part in (raw or "").split(","):
        token = part.strip()
        if not token:
            continue
        if len(token) > 120 or FORBIDDEN_URL_CHARS.search(token):
            return False, [], f"Forbidden characters or excessive length in rule: {token}"
        if is_path:
            if not token.startswith("/"):
                token = "/" + token
            if token == "/" or token == "/*" or ".." in token or "//" in token:
                return False, [], f"Unsafe or overly broad path pattern: {token}"
        items.append(token)
    return True, items, ""


def validate_decoy_fields(theme: str, site_name: str, tagline: str, email: str) -> tuple[bool, str]:
    if theme not in DECOY_THEMES:
        return False, f"Invalid decoy theme '{theme}'. Choose one of: {', '.join(DECOY_THEMES)}."
    for label, value, max_len in (
        ("Site name", site_name, 80),
        ("Tagline", tagline, 140),
    ):
        if not value or not value.strip():
            return False, f"{label} cannot be empty."
        if len(value) > max_len or re.search(r"[\x00-\x1f\x7f<>\"'`;{}]", value):
            return False, f"{label} contains unsupported characters or exceeds {max_len} chars."
    if email and (len(email) > 254 or not EMAIL_RE.fullmatch(email)):
        return False, "Contact email is invalid."
    return True, ""


def validate_probe_update(payload: dict[str, Any]) -> tuple[bool, dict[str, Any], str]:
    """Validate and normalize a full probe configuration payload."""
    cfg = dict(DEFAULT_PROBE_CONFIG)
    for bkey in BOOL_KEYS:
        if bkey in payload:
            val = payload[bkey]
            if isinstance(val, bool):
                cfg[bkey] = val
            elif isinstance(val, str):
                cfg[bkey] = val.strip().lower() == "true"
            else:
                return False, {}, f"Invalid boolean for {bkey}."

    target = normalize_redirect_url(str(payload.get("PROBE_REDIRECT_TARGET", cfg["PROBE_REDIRECT_TARGET"])))
    if cfg["PROBE_REDIRECT_ENABLED"] or target:
        ok_u, err_u = validate_redirect_url(target)
        if not ok_u:
            return False, {}, f"Primary redirect destination invalid: {err_u}"
    cfg["PROBE_REDIRECT_TARGET"] = target or str(DEFAULT_PROBE_CONFIG["PROBE_REDIRECT_TARGET"])

    status = str(payload.get("PROBE_REDIRECT_STATUS", cfg["PROBE_REDIRECT_STATUS"])).strip()
    if status not in REDIRECT_STATUSES:
        return False, {}, "Redirect status must be 301, 302, or 307."
    cfg["PROBE_REDIRECT_STATUS"] = status

    fb_mode = str(payload.get("PROBE_FALLBACK_MODE", cfg["PROBE_FALLBACK_MODE"])).strip()
    if fb_mode not in FALLBACK_MODES:
        return False, {}, "Fallback mode must be decoy, secondary_url, or not_found."
    cfg["PROBE_FALLBACK_MODE"] = fb_mode

    fb_url = normalize_redirect_url(str(payload.get("PROBE_FALLBACK_URL", "")))
    if fb_mode == "secondary_url":
        ok_fb, err_fb = validate_redirect_url(fb_url)
        if not ok_fb:
            return False, {}, f"Secondary fallback URL invalid: {err_fb}"
        if fb_url.rstrip("/") == cfg["PROBE_REDIRECT_TARGET"].rstrip("/"):
            return False, {}, "Secondary fallback URL should differ from primary redirect target."
    elif fb_url:
        ok_fb, err_fb = validate_redirect_url(fb_url)
        if not ok_fb:
            return False, {}, f"Secondary fallback URL invalid: {err_fb}"
    cfg["PROBE_FALLBACK_URL"] = fb_url

    try:
        interval = int(payload.get("PROBE_CHECK_INTERVAL", cfg["PROBE_CHECK_INTERVAL"]))
    except (TypeError, ValueError):
        return False, {}, "Health check interval must be an integer."
    if interval < 15 or interval > 3600:
        return False, {}, "Health check interval must be between 15 and 3600 seconds."
    cfg["PROBE_CHECK_INTERVAL"] = interval

    ok_ua, ua_list, err_ua = validate_token_csv(str(payload.get("PROBE_CUSTOM_UA", "")), is_path=False)
    if not ok_ua:
        return False, {}, err_ua
    cfg["PROBE_CUSTOM_UA"] = ",".join(ua_list)

    ok_p, path_list, err_p = validate_token_csv(str(payload.get("PROBE_CUSTOM_PATHS", "")), is_path=True)
    if not ok_p:
        return False, {}, err_p
    cfg["PROBE_CUSTOM_PATHS"] = ",".join(path_list)

    ok_bc, block_list, err_bc = validate_cidr_csv(str(payload.get("PROBE_BLOCK_CIDRS", "")))
    if not ok_bc:
        return False, {}, f"Block CIDRs: {err_bc}"
    cfg["PROBE_BLOCK_CIDRS"] = ",".join(block_list)

    ok_ac, allow_list, err_ac = validate_cidr_csv(str(payload.get("PROBE_ALLOW_CIDRS", "")))
    if not ok_ac:
        return False, {}, f"Allow CIDRs: {err_ac}"
    cfg["PROBE_ALLOW_CIDRS"] = ",".join(allow_list)

    # Preserve decoy fields if provided or keep defaults
    theme = str(payload.get("DECOY_THEME", cfg["DECOY_THEME"])).strip()
    site_name = str(payload.get("DECOY_SITE_NAME", cfg["DECOY_SITE_NAME"])).strip()
    tagline = str(payload.get("DECOY_SITE_TAGLINE", cfg["DECOY_SITE_TAGLINE"])).strip()
    email = str(payload.get("DECOY_CONTACT_EMAIL", cfg["DECOY_CONTACT_EMAIL"])).strip()
    ok_d, err_d = validate_decoy_fields(theme, site_name, tagline, email)
    if not ok_d:
        return False, {}, err_d
    cfg["DECOY_THEME"] = theme
    cfg["DECOY_SITE_NAME"] = site_name
    cfg["DECOY_SITE_TAGLINE"] = tagline
    cfg["DECOY_CONTACT_EMAIL"] = email

    return True, cfg, ""


def load_probe_conf(path: str) -> dict[str, Any]:
    """Read caddy/probe.conf safely without executing shell syntax."""
    cfg = dict(DEFAULT_PROBE_CONFIG)
    if not os.path.isfile(path):
        return cfg
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, raw_val = line.split("=", 1)
                key = key.strip()
                if key not in cfg:
                    continue
                val = _strip_quotes(raw_val.strip())
                if key in BOOL_KEYS:
                    cfg[key] = val.lower() == "true"
                elif key == "PROBE_CHECK_INTERVAL":
                    try:
                        iv = int(val)
                        if 15 <= iv <= 3600:
                            cfg[key] = iv
                    except ValueError:
                        pass
                else:
                    cfg[key] = val
    except OSError:
        pass
    return cfg


def save_probe_conf(path: str, cfg: dict[str, Any]) -> None:
    """Atomically save caddy/probe.conf with mode 0600 and LF line endings."""
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, mode=0o755, exist_ok=True)
    ordered_keys = list(DEFAULT_PROBE_CONFIG.keys())
    lines: list[str] = []
    for k in ordered_keys:
        v = cfg.get(k, DEFAULT_PROBE_CONFIG[k])
        if isinstance(v, bool):
            s = "true" if v else "false"
        else:
            s = str(v).replace('"', "").replace("\n", " ").replace("\r", "")
        lines.append(f'{k}="{s}"\n')

    fd, tmp_path = tempfile.mkstemp(prefix=".probe-", suffix=".conf", dir=parent)
    try:
        os.chmod(tmp_path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.writelines(lines)
        os.replace(tmp_path, path)
        os.chmod(path, 0o600)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def load_probe_state(path: str) -> dict[str, Any]:
    """Load caddy/probe-state.json with defaults."""
    default_state = {
        "active_state": "primary",
        "effective_target": "",
        "reason": "initial",
        "consecutive_failures": 0,
        "last_checked": "",
        "primary_ok": True,
        "primary_status": 0,
        "primary_latency_ms": 0,
        "primary_error": "",
        "secondary_ok": False,
        "secondary_error": "",
    }
    if not os.path.isfile(path):
        return default_state
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
        if isinstance(raw, dict):
            default_state.update(raw)
    except Exception:  # noqa: BLE001, S110
        pass
    return default_state


def save_probe_state(path: str, state: dict[str, Any]) -> None:
    """Atomically write caddy/probe-state.json."""
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, mode=0o755, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".probe-state-", suffix=".json", dir=parent)
    try:
        os.chmod(tmp_path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(state, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp_path, path)
        os.chmod(path, 0o600)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[override]
        return None


def check_target_reachability(url: str, timeout: float = 4.0) -> dict[str, Any]:
    """Check whether a redirect destination URL is reachable over HTTP/HTTPS."""
    now_iso = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    ok_u, err_u = validate_redirect_url(url)
    if not ok_u:
        return {
            "reachable": False,
            "status_code": 0,
            "latency_ms": 0,
            "error": err_u,
            "checked_at": now_iso,
        }

    ctx = ssl.create_default_context()
    opener = urllib.request.build_opener(_NoRedirectHandler(), urllib.request.HTTPSHandler(context=ctx))
    headers = {"User-Agent": "Mozilla/5.0 (compatible; MeridianHealthProbe/1.0)"}

    for method in ("HEAD", "GET"):
        req = urllib.request.Request(url, method=method, headers=headers)
        t0 = time.monotonic()
        try:
            with opener.open(req, timeout=timeout) as resp:
                if method == "GET":
                    resp.read(128)
                elapsed = int((time.monotonic() - t0) * 1000)
                code = int(getattr(resp, "status", 200))
                return {
                    "reachable": code < 500,
                    "status_code": code,
                    "latency_ms": elapsed,
                    "error": "" if code < 500 else f"HTTP {code}",
                    "checked_at": now_iso,
                }
        except urllib.error.HTTPError as exc:
            elapsed = int((time.monotonic() - t0) * 1000)
            if exc.code in (301, 302, 303, 307, 308):
                return {
                    "reachable": True,
                    "status_code": exc.code,
                    "latency_ms": elapsed,
                    "error": "",
                    "checked_at": now_iso,
                }
            if method == "HEAD" and exc.code in (403, 405, 501):
                continue
            reachable = exc.code < 500
            return {
                "reachable": reachable,
                "status_code": exc.code,
                "latency_ms": elapsed,
                "error": "" if reachable else f"HTTP {exc.code}",
                "checked_at": now_iso,
            }
        except Exception as exc:  # noqa: BLE001
            elapsed = int((time.monotonic() - t0) * 1000)
            return {
                "reachable": False,
                "status_code": 0,
                "latency_ms": elapsed,
                "error": str(exc),
                "checked_at": now_iso,
            }
    return {"reachable": False, "status_code": 0, "latency_ms": 0, "error": "Probe failed", "checked_at": now_iso}


def evaluate_effective_state(
    cfg: dict[str, Any],
    primary_probe: dict[str, Any] | None,
    secondary_probe: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Compute effective redirect state with safe fallback guarantees."""
    if not cfg.get("PROBE_REDIRECT_ENABLED"):
        return {
            "active_state": "disabled",
            "effective_target": "",
            "reason": "Probe redirection is disabled; serving decoy site.",
        }

    primary_url = str(cfg.get("PROBE_REDIRECT_TARGET") or "")
    if primary_probe and primary_probe.get("reachable"):
        return {
            "active_state": "primary",
            "effective_target": primary_url,
            "reason": "Primary redirect destination is reachable.",
        }

    fb_mode = str(cfg.get("PROBE_FALLBACK_MODE") or "decoy")
    fb_url = str(cfg.get("PROBE_FALLBACK_URL") or "")
    if fb_mode == "secondary_url" and fb_url:
        if secondary_probe and secondary_probe.get("reachable"):
            return {
                "active_state": "fallback_secondary",
                "effective_target": fb_url,
                "reason": "Primary redirect target unreachable; using secondary fallback URL.",
            }
        return {
            "active_state": "fallback_decoy",
            "effective_target": "",
            "reason": "Primary and secondary redirect targets unreachable; safely serving decoy site.",
        }
    if fb_mode == "not_found":
        return {
            "active_state": "fallback_404",
            "effective_target": "",
            "reason": "Primary redirect target unreachable; fallback serving 404 page.",
        }
    return {
        "active_state": "fallback_decoy",
        "effective_target": "",
        "reason": "Primary redirect target unreachable; safely serving decoy site.",
    }


def _normalize_path(path: str) -> str:
    p = (path or "/").strip().split("?", 1)[0]
    if not p.startswith("/"):
        p = "/" + p
    return p


def paths_overlap(a: str, b: str) -> bool:
    na = _normalize_path(a).rstrip("/") or "/"
    nb = _normalize_path(b).rstrip("/") or "/"
    if na == nb or na == "/" or nb == "/":
        return True
    return nb.startswith(na + "/") or na.startswith(nb + "/")


def _path_matches_pattern(req_path: str, pattern: str) -> bool:
    p = req_path.lower()
    pat = pattern.lower()
    if pat.endswith("*"):
        prefix = pat[:-1]
        return p.startswith(prefix)
    return p == pat


def simulate_request(
    cfg: dict[str, Any],
    state: dict[str, Any],
    protected_paths: list[str],
    method: str = "GET",
    path: str = "/",
    user_agent: str = "Mozilla/5.0",
    client_ip: str = "198.51.100.25",
) -> dict[str, Any]:
    """Simulate Caddy routing & probe detection for a sample HTTP request."""
    norm_path = _normalize_path(path)
    norm_method = (method or "GET").strip().upper()

    # 1. Protected service routes are matched before any fallback/decoy/probe handler.
    for prot in protected_paths:
        clean_prot = (prot or "").strip()
        if not clean_prot or clean_prot == "/":
            continue
        base = clean_prot.rstrip("/")
        if norm_path == base or norm_path.startswith(base + "/"):
            return {
                "decision": "pass_to_service",
                "matched_rule": f"protected_route:{clean_prot}",
                "reason": "Legitimate panel/webpanel/subscription/inbound route never touched by probe redirection.",
                "target": clean_prot,
                "status": 200,
            }

    if not cfg.get("PROBE_REDIRECT_ENABLED"):
        return {
            "decision": "decoy",
            "matched_rule": "redirect_disabled",
            "reason": "Probe redirection is disabled; normal decoy page is served.",
            "target": "/srv/site",
            "status": 200,
        }

    active_state = state.get("active_state", "primary")
    if active_state == "fallback_decoy":
        return {
            "decision": "decoy",
            "matched_rule": "safe_fallback_decoy",
            "reason": "Redirect destination unavailable; safe fallback serves decoy website.",
            "target": "/srv/site",
            "status": 200,
        }
    if active_state == "fallback_404":
        return {
            "decision": "not_found",
            "matched_rule": "safe_fallback_404",
            "reason": "Redirect destination unavailable; fallback returns 404 page.",
            "target": "/404.html",
            "status": 404,
        }

    dest = (
        str(cfg.get("PROBE_FALLBACK_URL") or "")
        if active_state == "fallback_secondary"
        else str(cfg.get("PROBE_REDIRECT_TARGET") or "")
    )
    status = int(cfg.get("PROBE_REDIRECT_STATUS") or 302)

    # 2. Loopback + custom allowlist never redirected
    allow_nets = [ipaddress.ip_network("127.0.0.1/32"), ipaddress.ip_network("::1/128")]
    for raw in str(cfg.get("PROBE_ALLOW_CIDRS") or "").split(","):
        if raw.strip():
            try:
                allow_nets.append(ipaddress.ip_network(raw.strip(), strict=False))
            except ValueError:
                pass
    try:
        ip_obj = ipaddress.ip_address(client_ip.strip())
    except ValueError:
        ip_obj = None

    if ip_obj and any(ip_obj in net for net in allow_nets):
        return {
            "decision": "decoy",
            "matched_rule": "allowlisted_ip",
            "reason": "Client IP is allowlisted (loopback or admin CIDR).",
            "target": "/srv/site",
            "status": 200,
        }

    # 3. Blocked CIDRs
    if ip_obj:
        for raw in str(cfg.get("PROBE_BLOCK_CIDRS") or "").split(","):
            if raw.strip():
                try:
                    if ip_obj in ipaddress.ip_network(raw.strip(), strict=False):
                        return {
                            "decision": "redirect",
                            "matched_rule": f"blocked_cidr:{raw.strip()}",
                            "reason": "Client IP matches configured suspicious CIDR.",
                            "target": dest,
                            "status": status,
                        }
                except ValueError:
                    pass

    # 4. Suspicious HTTP methods (aligned with Caddy: not method GET HEAD OPTIONS)
    if cfg.get("PROBE_DETECT_BAD_METHODS") and norm_method not in ("GET", "HEAD", "OPTIONS"):
        return {
            "decision": "redirect",
            "matched_rule": f"suspicious_method:{norm_method}",
            "reason": f"Method {norm_method} is outside normal static site browsing methods.",
            "target": dest,
            "status": status,
        }

    # 5. Missing / empty User-Agent
    ua_clean = (user_agent or "").strip()
    if cfg.get("PROBE_DETECT_EMPTY_UA") and not ua_clean:
        return {
            "decision": "redirect",
            "matched_rule": "missing_or_empty_ua",
            "reason": "Empty or missing User-Agent header.",
            "target": dest,
            "status": status,
        }

    ua_low = ua_clean.lower()
    ua_groups: list[tuple[str, tuple[str, ...]]] = []
    if cfg.get("PROBE_DETECT_SCANNERS"):
        ua_groups.append(("scanner_ua", SCANNER_UA_PATTERNS))
    if cfg.get("PROBE_DETECT_CRAWLERS"):
        ua_groups.append(("crawler_ua", CRAWLER_UA_PATTERNS))
    if cfg.get("PROBE_DETECT_CLI"):
        ua_groups.append(("cli_ua", CLI_UA_PATTERNS))
    custom_ua = tuple(t.strip().lower() for t in str(cfg.get("PROBE_CUSTOM_UA") or "").split(",") if t.strip())
    if custom_ua:
        ua_groups.append(("custom_ua", custom_ua))

    for group_name, patterns in ua_groups:
        for pat in patterns:
            if pat in ua_low:
                return {
                    "decision": "redirect",
                    "matched_rule": f"{group_name}:{pat}",
                    "reason": f"User-Agent matched {group_name} pattern '{pat}'.",
                    "target": dest,
                    "status": status,
                }

    # 6. Suspicious probe paths (excluding any overlap with protected paths)
    path_patterns: list[str] = []
    if cfg.get("PROBE_DETECT_PATHS"):
        path_patterns.extend(SUSPICIOUS_PATHS)
    for t in str(cfg.get("PROBE_CUSTOM_PATHS") or "").split(","):
        if t.strip():
            path_patterns.append(t.strip())

    for pat in path_patterns:
        pat_base = pat.rstrip("*").rstrip("/") or "/"
        if any(paths_overlap(pat_base, prot) for prot in protected_paths if prot and prot != "/"):
            continue
        if _path_matches_pattern(norm_path, pat):
            return {
                "decision": "redirect",
                "matched_rule": f"suspicious_path:{pat}",
                "reason": f"Request path '{norm_path}' matched probe path pattern '{pat}'.",
                "target": dest,
                "status": status,
            }

    return {
        "decision": "decoy",
        "matched_rule": "legitimate_traffic",
        "reason": "Request resembles normal browser traffic; serving decoy site.",
        "target": "/srv/site",
        "status": 200,
    }
