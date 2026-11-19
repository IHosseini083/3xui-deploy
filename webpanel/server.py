"""Standalone HTTPS-proxied HTTP server for the 3xui-deploy Web Management Panel."""

from __future__ import annotations

import argparse
import ipaddress
import json
import mimetypes
import os
import posixpath
import signal
import sys
import threading
import urllib.parse
from dataclasses import dataclass
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from . import auth, ops, probe

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
SESSION_COOKIE_NAME = "3xui_deploy_sid"
MAX_JSON_BODY_BYTES = 1024 * 1024  # 1 MiB (allows custom decoy HTML safely)

CSP_HEADER = (
    "default-src 'self'; script-src 'self'; style-src 'self'; "
    "img-src 'self' data:; font-src 'self'; connect-src 'self'; "
    "base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
)


@dataclass
class WebPanelConfig:
    install_dir: str
    backup_dir: str
    manage_script: str
    bind_host: str = "127.0.0.1"
    bind_port: int = 2059
    base_path: str = "/deploy/"
    allowed_domain: str = ""
    session_idle_minutes: int = 30
    session_max_hours: int = 12
    monitor_interval_seconds: int = 60

    @classmethod
    def from_install_dir(
        cls, install_dir: str, backup_dir: str = "/opt/3x-ui-backups"
    ) -> "WebPanelConfig":
        wp_conf = ops.read_kv_conf(
            os.path.join(install_dir, "webpanel", "webpanel.conf")
        )
        proxy_conf = ops.read_kv_conf(os.path.join(install_dir, "caddy", "proxy.conf"))

        bind_host = wp_conf.get("WEBPANEL_BIND", "127.0.0.1").strip() or "127.0.0.1"
        if bind_host not in ("127.0.0.1", "::1"):
            raise ValueError(f"Refusing non-loopback WebPanel bind host: {bind_host}")

        try:
            bind_port = int(wp_conf.get("WEBPANEL_PORT", "2059"))
        except ValueError:
            bind_port = 2059

        base_path = wp_conf.get("WEBPANEL_PATH", "/deploy/").strip() or "/deploy/"
        if not base_path.startswith("/"):
            base_path = "/" + base_path
        if not base_path.endswith("/"):
            base_path += "/"

        allowed_domain = (
            (wp_conf.get("WEBPANEL_DOMAIN") or proxy_conf.get("PROXY_DOMAIN") or "")
            .strip()
            .lower()
        )
        try:
            idle_min = int(wp_conf.get("WEBPANEL_SESSION_IDLE", "30"))
        except ValueError:
            idle_min = 30

        manage_script = os.path.join(install_dir, "webpanel", "manage.sh")
        if not os.path.isfile(manage_script):
            repo_manage = os.path.join(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "manage.sh"
            )
            if os.path.isfile(repo_manage):
                manage_script = repo_manage

        return cls(
            install_dir=install_dir,
            backup_dir=backup_dir,
            manage_script=manage_script,
            bind_host=bind_host,
            bind_port=bind_port,
            base_path=base_path,
            allowed_domain=allowed_domain,
            session_idle_minutes=max(5, min(1440, idle_min)),
        )


def _extract_hostname(host_header: str) -> str:
    h = (host_header or "").strip().lower()
    if not h:
        return ""
    if h.startswith("["):
        end = h.find("]")
        return h[1:end] if end != -1 else ""
    if ":" in h:
        return h.split(":", 1)[0]
    return h


def _is_loopback_peer(addr: str) -> bool:
    try:
        return ipaddress.ip_address(addr).is_loopback
    except ValueError:
        return False


class DeployHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(
        self,
        server_address: tuple[str, int],
        handler_cls: type[BaseHTTPRequestHandler],
        config: WebPanelConfig,
        auth_store: auth.AuthStore,
        deploy_ops: ops.DeployOps,
    ) -> None:
        self.config = config
        self.auth_store = auth_store
        self.deploy_ops = deploy_ops
        super().__init__(server_address, handler_cls)


class DeployRequestHandler(BaseHTTPRequestHandler):
    server_version = "3xui-deploy-web/1.0"
    sys_version = ""

    def log_message(self, format: str, *args: Any) -> None:
        # Suppress default stderr HTTP request logs with unvalidated tokens/headers.
        return

    @property
    def cfg(self) -> WebPanelConfig:
        return self.server.config  # type: ignore[attr-defined]

    @property
    def auth_store(self) -> auth.AuthStore:
        return self.server.auth_store  # type: ignore[attr-defined]

    @property
    def deploy_ops(self) -> ops.DeployOps:
        return self.server.deploy_ops  # type: ignore[attr-defined]

    def _effective_client_ip(self) -> str:
        peer = self.client_address[0] if self.client_address else ""
        if _is_loopback_peer(peer):
            xfwd = (
                self.headers.get("X-Real-IP")
                or self.headers.get("X-Forwarded-For", "").split(",")[0].strip()
            )
            if xfwd:
                return xfwd.strip()
        return peer or "127.0.0.1"

    def _check_allowed_domain(self) -> bool:
        expected = self.cfg.allowed_domain.strip().lower()
        if not expected:
            return False
        peer = self.client_address[0] if self.client_address else ""
        raw_host = ""
        if _is_loopback_peer(peer) and self.headers.get("X-Forwarded-Host"):
            raw_host = self.headers.get("X-Forwarded-Host", "")
        else:
            raw_host = self.headers.get("Host", "")
        host = _extract_hostname(raw_host)
        if not host:
            return False
        return host == expected

    def _check_origin_header(self) -> bool:
        origin = self.headers.get("Origin")
        if not origin:
            return True
        parsed = urllib.parse.urlsplit(origin)
        scheme = (parsed.scheme or "").lower()
        host = (parsed.hostname or "").lower()
        if not host or host != self.cfg.allowed_domain.strip().lower():
            return False
        xf_proto = (self.headers.get("X-Forwarded-Proto") or "").strip().lower()
        if xf_proto == "https" and scheme != "https":
            return False
        return scheme in ("http", "https")

    def _normalized_route(self) -> str:
        raw_path = urllib.parse.urlsplit(self.path).path or "/"
        base = self.cfg.base_path.rstrip("/")
        if base and (raw_path == base or raw_path.startswith(base + "/")):
            stripped = raw_path[len(base) :]
            return stripped or "/"
        return raw_path

    def _query_params(self) -> dict[str, str]:
        qs = urllib.parse.parse_qs(
            urllib.parse.urlsplit(self.path).query, keep_blank_values=False
        )
        return {k: v[0] for k, v in qs.items() if v}

    def _get_cookie_token(self) -> str | None:
        raw_cookie = self.headers.get("Cookie")
        if not raw_cookie:
            return None
        jar = cookies.SimpleCookie()
        try:
            jar.load(raw_cookie)
        except cookies.CookieError:
            return None
        morsel = jar.get(SESSION_COOKIE_NAME)
        return morsel.value if morsel else None

    def _format_session_cookie(self, token: str, max_age: int | None = None) -> str:
        path_attr = (
            self.cfg.base_path
            if self.cfg.base_path.endswith("/")
            else self.cfg.base_path + "/"
        )
        parts = [
            f"{SESSION_COOKIE_NAME}={token}",
            f"Path={path_attr}",
            "HttpOnly",
            "Secure",
            "SameSite=Strict",
        ]
        if max_age is not None:
            parts.append(f"Max-Age={max(0, int(max_age))}")
        return "; ".join(parts)

    def _send_common_headers(
        self, extra_headers: list[tuple[str, str]] | None = None
    ) -> None:
        self.send_header("Content-Security-Policy", CSP_HEADER)
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        if extra_headers:
            for k, v in extra_headers:
                self.send_header(k, v)

    def _send_json(
        self,
        status: int,
        payload: dict[str, Any],
        extra_headers: list[tuple[str, str]] | None = None,
    ) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._send_common_headers(extra_headers)
        self.end_headers()
        self.wfile.write(body)

    def _send_text_error(self, status: int, message: str) -> None:
        body = message.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._send_common_headers()
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self) -> tuple[bool, dict[str, Any], str]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return False, {}, "Invalid Content-Length header."
        if length < 0 or length > MAX_JSON_BODY_BYTES:
            return False, {}, "Request body too large."
        if length == 0:
            return True, {}, ""
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except Exception:  # noqa: BLE001
            return False, {}, "Malformed JSON body."
        if not isinstance(data, dict):
            return False, {}, "JSON body must be an object."
        return True, data, ""

    def _require_auth(
        self, require_csrf: bool = False
    ) -> tuple[dict[str, Any] | None, str | None]:
        token = self._get_cookie_token()
        session = self.auth_store.validate_session(token, touch=True)
        if not session:
            self._send_json(401, {"error": "Authentication required."})
            return None, None
        if require_csrf:
            if not self._check_origin_header():
                self._send_json(403, {"error": "Origin header mismatch."})
                return None, None
            csrf_hdr = self.headers.get("X-CSRF-Token")
            if not self.auth_store.verify_csrf(session, csrf_hdr):
                self._send_json(403, {"error": "Invalid or missing CSRF token."})
                return None, None
        return session, token

    def _serve_static(self, rel_path: str) -> None:
        clean = posixpath.normpath("/" + rel_path).lstrip("/")
        if not clean or clean == ".":
            clean = "index.html"
        if ".." in clean.split("/") or clean.startswith("/"):
            self._send_text_error(404, "Not found")
            return
        static_root = os.path.realpath(STATIC_DIR)
        candidate = os.path.realpath(os.path.join(static_root, clean))
        if not candidate.startswith(static_root + os.sep) and candidate != static_root:
            self._send_text_error(403, "Forbidden")
            return
        if not os.path.isfile(candidate):
            self._send_text_error(404, "Not found")
            return

        ctype, _ = mimetypes.guess_type(candidate)
        if candidate.endswith(".js"):
            ctype = "application/javascript; charset=utf-8"
        elif candidate.endswith(".css"):
            ctype = "text/css; charset=utf-8"
        elif candidate.endswith(".html"):
            ctype = "text/html; charset=utf-8"
        elif not ctype:
            ctype = "application/octet-stream"

        with open(candidate, "rb") as fh:
            data = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self._send_common_headers()
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        if not self._check_allowed_domain():
            self._send_text_error(403, "Forbidden: domain mismatch")
            return

        raw_path = urllib.parse.urlsplit(self.path).path or "/"
        base = self.cfg.base_path.rstrip("/")
        if base and raw_path == base:
            self.send_response(308)
            self.send_header("Location", base + "/")
            self.send_header("Content-Length", "0")
            self._send_common_headers()
            self.end_headers()
            return

        route = self._normalized_route()
        if route in ("/", "/index.html"):
            self._serve_static("index.html")
            return
        if route.startswith("/assets/"):
            self._serve_static(route[len("/assets/") :])
            return

        if route == "/api/auth/status":
            tok = self._get_cookie_token()
            sess = self.auth_store.validate_session(tok, touch=False)
            if not sess:
                self._send_json(
                    200,
                    {
                        "authenticated": False,
                        "configured": self.auth_store.has_users(),
                        "domain": self.cfg.allowed_domain,
                        "base_path": self.cfg.base_path,
                    },
                )
                return
            self._send_json(
                200,
                {
                    "authenticated": True,
                    "username": sess["username"],
                    "csrf_token": sess["csrf_token"],
                    "domain": self.cfg.allowed_domain,
                    "base_path": self.cfg.base_path,
                },
            )
            return

        if route == "/api/auth/sessions":
            sess, tok = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, {"sessions": self.auth_store.list_sessions(tok)})
            return

        if route == "/api/overview":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, self.deploy_ops.get_overview())
            return

        if route == "/api/compat":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, self.deploy_ops.get_compatibility())
            return

        if route == "/api/probe":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, self.deploy_ops.get_probe_bundle())
            return

        if route == "/api/decoy":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, self.deploy_ops.get_decoy_config())
            return

        if route == "/api/inbounds":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, self.deploy_ops.get_inbounds())
            return

        if route == "/api/backups":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, {"backups": self.deploy_ops.list_backups()})
            return

        if route == "/api/logs":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            params = self._query_params()
            source = params.get("source", "deploy")
            try:
                lines = int(params.get("lines", "150"))
            except ValueError:
                lines = 150
            level = params.get("level", "ALL")
            self._send_json(200, self.deploy_ops.get_logs(source, lines, level))
            return

        self._send_json(404, {"error": "Endpoint not found."})

    def do_POST(self) -> None:
        if not self._check_allowed_domain():
            self._send_text_error(403, "Forbidden: domain mismatch")
            return

        route = self._normalized_route()
        client_ip = self._effective_client_ip()
        user_agent = self.headers.get("User-Agent", "")

        if route == "/api/auth/login":
            if not self._check_origin_header():
                self._send_json(403, {"error": "Origin header mismatch."})
                return
            ok_b, body, err_b = self._read_json_body()
            if not ok_b:
                self._send_json(400, {"error": err_b})
                return
            username = str(body.get("username", "")).strip()
            password = str(body.get("password", ""))
            ok_a, res = self.auth_store.authenticate(
                username, password, client_ip, user_agent
            )
            if not ok_a:
                extra = []
                if "retry_after" in res:
                    extra.append(("Retry-After", str(res["retry_after"])))
                self._send_json(
                    int(res.get("status", 401)),
                    {"error": res.get("error", "Login failed.")},
                    extra,
                )
                return
            cookie_hdr = self._format_session_cookie(res["session_token"])
            self._send_json(
                200,
                {
                    "authenticated": True,
                    "username": res["username"],
                    "csrf_token": res["csrf_token"],
                    "expires_in": res["expires_in"],
                },
                [("Set-Cookie", cookie_hdr)],
            )
            return

        sess, tok = self._require_auth(require_csrf=True)
        if not sess or not tok:
            return
        actor = sess["username"]

        if route == "/api/auth/logout":
            self.auth_store.logout(tok, client_ip)
            expired_cookie = self._format_session_cookie("deleted", max_age=0)
            self._send_json(200, {"ok": True}, [("Set-Cookie", expired_cookie)])
            return

        if route == "/api/auth/sessions/revoke-others":
            cnt = self.auth_store.revoke_other_sessions(tok, actor, client_ip)
            self._send_json(200, {"ok": True, "revoked": cnt})
            return

        ok_b, body, err_b = self._read_json_body()
        if not ok_b:
            self._send_json(400, {"error": err_b})
            return

        if route == "/api/auth/change-password":
            cur_pw = str(body.get("current_password", ""))
            new_pw = str(body.get("new_password", ""))
            ok_cp, msg_cp, rotated = self.auth_store.change_password(
                actor, cur_pw, new_pw, tok, client_ip, user_agent
            )
            if not ok_cp or not rotated:
                self._send_json(400, {"error": msg_cp})
                return
            cookie_hdr = self._format_session_cookie(rotated["session_token"])
            self._send_json(
                200,
                {"ok": True, "message": msg_cp, "csrf_token": rotated["csrf_token"]},
                [("Set-Cookie", cookie_hdr)],
            )
            return

        if route == "/api/compat/test":
            tag = str(body.get("tag", "")).strip()
            self.auth_store.audit_log("compat_test", actor, client_ip, f"tag={tag}")
            res = self.deploy_ops.run_compat_test(tag)
            self._send_json(200 if res["ok"] else 400, res)
            return

        if route == "/api/lifecycle":
            action = str(body.get("action", "")).strip()
            self.auth_store.audit_log("lifecycle", actor, client_ip, f"action={action}")
            res = self.deploy_ops.run_lifecycle(action)
            self._send_json(200 if res["ok"] else 400, res)
            return

        if route == "/api/update":
            tag = body.get("tag")
            force_compat = bool(body.get("force_compat", False))
            self.auth_store.audit_log(
                "xui_update",
                actor,
                client_ip,
                f"tag={tag or 'latest'} force={force_compat}",
            )
            res = self.deploy_ops.run_update(
                str(tag) if tag else None, force_compat=force_compat
            )
            self._send_json(200 if res["ok"] else 400, res)
            return

        if route == "/api/rollback":
            self.auth_store.audit_log("xui_rollback", actor, client_ip, "")
            res = self.deploy_ops.run_rollback()
            self._send_json(200 if res["ok"] else 400, res)
            return

        if route == "/api/audit":
            self.auth_store.audit_log("security_audit", actor, client_ip, "")
            self._send_json(200, self.deploy_ops.run_security_audit())
            return

        if route == "/api/backups":
            self.auth_store.audit_log("backup_create", actor, client_ip, "")
            res = self.deploy_ops.create_backup()
            self._send_json(200 if res["ok"] else 400, res)
            return

        if route == "/api/backups/prune":
            try:
                keep = int(body.get("keep", 7))
            except (TypeError, ValueError):
                self._send_json(400, {"error": "Invalid keep count."})
                return
            self.auth_store.audit_log("backup_prune", actor, client_ip, f"keep={keep}")
            res = self.deploy_ops.prune_backups(keep)
            self._send_json(200 if res["ok"] else 400, res)
            return

        if route == "/api/probe/check":
            target_url = str(body.get("url", "")).strip()
            if target_url:
                norm = probe.normalize_redirect_url(target_url)
                res = probe.check_target_reachability(norm)
                self._send_json(200, {"url": norm, "probe": res})
                return
            self.auth_store.audit_log("probe_health_check", actor, client_ip, "")
            self._send_json(
                200,
                self.deploy_ops.check_and_update_probe_state(sync_caddy_on_change=True),
            )
            return

        if route == "/api/probe/simulate":
            cfg = probe.load_probe_conf(self.deploy_ops.probe_conf_path)
            state = probe.load_probe_state(self.deploy_ops.probe_state_path)
            prot = self.deploy_ops.get_protected_paths()
            sim = probe.simulate_request(
                cfg=cfg,
                state=state,
                protected_paths=prot,
                method=str(body.get("method", "GET")),
                path=str(body.get("path", "/")),
                user_agent=str(body.get("user_agent", "Mozilla/5.0")),
                client_ip=str(body.get("client_ip", "198.51.100.25")),
            )
            self._send_json(200, sim)
            return

        if route == "/api/geo-update":
            scope = str(body.get("scope", "std")).strip()
            self.auth_store.audit_log("geo_update", actor, client_ip, f"scope={scope}")
            res = self.deploy_ops.run_geo_update(scope)
            self._send_json(200 if res["ok"] else 400, res)
            return

        self._send_json(404, {"error": "Endpoint not found."})

    def do_PUT(self) -> None:
        if not self._check_allowed_domain():
            self._send_text_error(403, "Forbidden: domain mismatch")
            return
        sess, _ = self._require_auth(require_csrf=True)
        if not sess:
            return
        actor = sess["username"]
        client_ip = self._effective_client_ip()
        route = self._normalized_route()

        ok_b, body, err_b = self._read_json_body()
        if not ok_b:
            self._send_json(400, {"error": err_b})
            return

        if route == "/api/probe":
            self.auth_store.audit_log(
                "probe_config_update",
                actor,
                client_ip,
                f"enabled={body.get('PROBE_REDIRECT_ENABLED')}",
            )
            ok_u, res = self.deploy_ops.update_probe_config(body)
            self._send_json(200 if ok_u else 400, res)
            return

        if route == "/api/decoy":
            self.auth_store.audit_log(
                "decoy_config_update", actor, client_ip, f"theme={body.get('theme')}"
            )
            ok_d, res = self.deploy_ops.update_decoy_config(body)
            self._send_json(200 if ok_d else 400, res)
            return

        self._send_json(404, {"error": "Endpoint not found."})


def start_probe_monitor(
    stop_event: threading.Event,
    deploy_ops: ops.DeployOps,
    auth_store: auth.AuthStore,
) -> threading.Thread:
    """Background watcher evaluating redirect destination health & safe fallback."""

    def _loop() -> None:
        while not stop_event.is_set():
            cfg = probe.load_probe_conf(deploy_ops.probe_conf_path)
            interval = max(15, min(3600, int(cfg.get("PROBE_CHECK_INTERVAL", 60))))
            if cfg.get("PROBE_REDIRECT_ENABLED"):
                try:
                    res = deploy_ops.check_and_update_probe_state(
                        sync_caddy_on_change=True
                    )
                    if res.get("changed"):
                        st = res.get("state", {})
                        auth_store.audit_log(
                            "probe_fallback_transition",
                            "system",
                            "127.0.0.1",
                            f"active_state={st.get('active_state')} reason={st.get('reason')}",
                        )
                except Exception as exc:  # noqa: BLE001
                    auth_store.audit_log(
                        "probe_monitor_error", "system", "127.0.0.1", str(exc)
                    )
            stop_event.wait(interval)

    thread = threading.Thread(target=_loop, name="probe-monitor", daemon=True)
    thread.start()
    return thread


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="3xui-deploy Standalone Web Management Panel"
    )
    parser.add_argument(
        "--install-dir",
        default=os.environ.get("XUI_INSTALL_DIR", "/opt/3x-ui"),
        help="3x-ui installation directory (default: /opt/3x-ui)",
    )
    parser.add_argument(
        "--backup-dir",
        default=os.environ.get("XUI_BACKUP_DIR", "/opt/3x-ui-backups"),
        help="3x-ui backup directory (default: /opt/3x-ui-backups)",
    )
    args = parser.parse_args(argv)

    cfg = WebPanelConfig.from_install_dir(args.install_dir, args.backup_dir)
    if not cfg.allowed_domain:
        print(
            "ERROR: WEBPANEL_DOMAIN / PROXY_DOMAIN is not configured; refusing to start.",
            file=sys.stderr,
        )
        return 1

    auth_file = os.path.join(cfg.install_dir, "webpanel", "auth.json")
    audit_file = os.path.join(cfg.install_dir, "logs", "webpanel-audit.log")
    auth_store = auth.AuthStore(
        auth_file=auth_file,
        audit_log_file=audit_file,
        idle_minutes=cfg.session_idle_minutes,
        max_hours=cfg.session_max_hours,
    )
    deploy_ops = ops.DeployOps(cfg.install_dir, cfg.backup_dir, cfg.manage_script)
    server = DeployHTTPServer(
        (cfg.bind_host, cfg.bind_port),
        DeployRequestHandler,
        cfg,
        auth_store,
        deploy_ops,
    )

    stop_event = threading.Event()
    start_probe_monitor(stop_event, deploy_ops, auth_store)

    def _handle_sig(_signum: int, _frame: Any) -> None:
        stop_event.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _handle_sig)
    signal.signal(signal.SIGINT, _handle_sig)

    auth_store.audit_log(
        "webpanel_started",
        "system",
        cfg.bind_host,
        f"listen={cfg.bind_host}:{cfg.bind_port} domain={cfg.allowed_domain} path={cfg.base_path}",
    )
    try:
        server.serve_forever()
    finally:
        stop_event.set()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
