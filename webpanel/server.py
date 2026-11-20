"""Standalone HTTPS-proxied HTTP server for the 3xui-deploy Web Management Panel."""

from __future__ import annotations

import argparse
import gzip
import hashlib
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

from . import __version__ as WEBPANEL_VERSION
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
        self._cfg_lock = threading.Lock()
        self._wp_conf_mtime = self._read_wp_mtime(deploy_ops.webpanel_conf_path)
        super().__init__(server_address, handler_cls)

    @staticmethod
    def _read_wp_mtime(path: str) -> float:
        try:
            return os.path.getmtime(path)
        except OSError:
            return 0.0

    def sync_runtime_config(self) -> None:
        """Reload allowed_domain/base_path if webpanel.conf changed on disk."""
        wp_path = self.deploy_ops.webpanel_conf_path
        cur_mtime = self._read_wp_mtime(wp_path)
        if cur_mtime <= 0 or cur_mtime == self._wp_conf_mtime:
            return
        with self._cfg_lock:
            cur_mtime = self._read_wp_mtime(wp_path)
            if cur_mtime <= 0 or cur_mtime == self._wp_conf_mtime:
                return
            wp_conf = ops.read_kv_conf(wp_path)
            new_dom = wp_conf.get("WEBPANEL_DOMAIN", "").strip().lower()
            if new_dom and ops.validate_domain_name(new_dom):
                self.config.allowed_domain = new_dom
            new_bp = wp_conf.get("WEBPANEL_PATH", "").strip()
            if new_bp:
                self.config.base_path = ops.normalize_webpath(new_bp)
            try:
                idle = int(wp_conf.get("WEBPANEL_SESSION_IDLE", str(self.config.session_idle_minutes)))
                self.config.session_idle_minutes = self.auth_store.set_idle_minutes(idle)
            except ValueError:
                pass
            self._wp_conf_mtime = cur_mtime


class DeployRequestHandler(BaseHTTPRequestHandler):
    server_version = f"3xui-deploy-web/{WEBPANEL_VERSION}"
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
        self.server.sync_runtime_config()  # type: ignore[attr-defined]
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
        self,
        extra_headers: list[tuple[str, str]] | None = None,
        cache_control: str = "no-store",
    ) -> None:
        self.send_header("Content-Security-Policy", CSP_HEADER)
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", cache_control)
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

    def _send_op_result(self, res: dict[str, Any]) -> None:
        if res.get("accepted"):
            self._send_json(202, res)
        elif res.get("ok"):
            self._send_json(200, res)
        else:
            self._send_json(400, res)

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

    def _serve_static(self, rel_path: str, is_asset: bool = False) -> None:
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

        etag = '"' + hashlib.sha256(data).hexdigest()[:16] + '"'
        cache_ctrl = "private, no-cache" if is_asset else "no-store"
        if is_asset and self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self._send_common_headers(cache_control=cache_ctrl)
            self.end_headers()
            return

        extra: list[tuple[str, str]] = [("ETag", etag)]
        accept_enc = self.headers.get("Accept-Encoding", "").lower()
        if "gzip" in accept_enc and len(data) > 512:
            data = gzip.compress(data, compresslevel=6)
            extra.append(("Content-Encoding", "gzip"))
            extra.append(("Vary", "Accept-Encoding"))

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self._send_common_headers(extra, cache_control=cache_ctrl)
        self.end_headers()
        self.wfile.write(data)

    def _stream_job_sse(self, job_id: str) -> None:
        snap = self.deploy_ops.get_job(job_id, since=0)
        if not snap:
            self._send_json(404, {"error": "Job not found."})
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self._send_common_headers(cache_control="no-store")
        self.close_connection = True
        self.end_headers()

        def _write_event(ev_name: str, payload: dict[str, Any]) -> None:
            chunk = f"event: {ev_name}\ndata: {json.dumps(payload, separators=(',', ':'))}\n\n".encode()
            self.wfile.write(chunk)
            self.wfile.flush()

        try:
            _write_event("state", snap)
            cursor = int(snap.get("next_index", 0))
            if snap.get("status") in ("succeeded", "failed"):
                _write_event("done", snap)
                return

            while True:
                upd = self.deploy_ops.wait_for_job_update(job_id, cursor, timeout=10.0)
                if not upd:
                    break
                next_idx = int(upd.get("next_index", cursor))
                if next_idx > cursor or upd.get("status") in ("succeeded", "failed"):
                    _write_event("update", upd)
                    cursor = next_idx
                    if upd.get("status") in ("succeeded", "failed"):
                        _write_event("done", upd)
                        break
                else:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

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
            self._serve_static("index.html", is_asset=False)
            return
        if route.startswith("/assets/"):
            self._serve_static(route[len("/assets/") :], is_asset=True)
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
                        "version": WEBPANEL_VERSION,
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
                    "version": WEBPANEL_VERSION,
                },
            )
            return

        if route == "/api/version":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            params = self._query_params()
            check_remote = params.get("check", "").lower() in ("1", "true")
            self._send_json(200, self.deploy_ops.get_version_info(check_remote=check_remote))
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

        if route == "/api/health":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, self.deploy_ops.get_health_diagnostics())
            return

        if route == "/api/xray":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, self.deploy_ops.get_xray_status())
            return

        if route == "/api/compat":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, self.deploy_ops.get_compatibility())
            return

        if route == "/api/certs":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, self.deploy_ops.list_certificates())
            return

        if route == "/api/network":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, self.deploy_ops.get_network_config())
            return

        if route == "/api/network/firewall":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, self.deploy_ops.get_firewall_status())
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
            self._send_json(
                200,
                {
                    "backups": self.deploy_ops.list_backups(),
                    "cron": self.deploy_ops.get_backup_cron(),
                },
            )
            return

        if route == "/api/backups/cron":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            self._send_json(200, self.deploy_ops.get_backup_cron())
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
            query = params.get("query", "")
            self._send_json(200, self.deploy_ops.get_logs(source, lines, level, query))
            return

        if route == "/api/jobs":
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            params = self._query_params()
            try:
                limit = int(params.get("limit", "50"))
            except ValueError:
                limit = 50
            self._send_json(200, {"jobs": self.deploy_ops.list_jobs(limit)})
            return

        if route.startswith("/api/jobs/"):
            sess, _ = self._require_auth(require_csrf=False)
            if not sess:
                return
            rest = route[len("/api/jobs/") :]
            if rest.endswith("/stream"):
                job_id = rest[: -len("/stream")].strip("/")
                self._stream_job_sse(job_id)
                return
            job_id = rest.strip("/")
            params = self._query_params()
            try:
                since = int(params.get("since", "0"))
            except ValueError:
                since = 0
            job = self.deploy_ops.get_job(job_id, since=since)
            if not job:
                self._send_json(404, {"error": "Job not found."})
                return
            self._send_json(200, job)
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

        async_mode = bool(body.get("async", False))

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
            res = self.deploy_ops.run_compat_test(tag, async_mode=async_mode, actor=actor)
            self._send_op_result(res)
            return

        if route == "/api/lifecycle":
            action = str(body.get("action", "")).strip()
            self.auth_store.audit_log("lifecycle", actor, client_ip, f"action={action}")
            res = self.deploy_ops.run_lifecycle(action, async_mode=async_mode, actor=actor)
            self._send_op_result(res)
            return

        if route == "/api/deploy":
            db_type = str(body.get("db_type", "sqlite")).strip().lower()
            pg_user = str(body.get("pg_user", "xui")).strip()
            self.auth_store.audit_log("deploy_stack", actor, client_ip, f"db={db_type}")
            res = self.deploy_ops.run_deploy(
                db_type=db_type, pg_user=pg_user, async_mode=async_mode, actor=actor
            )
            self._send_op_result(res)
            return

        if route == "/api/self-update":
            target = str(body.get("target", "")).strip()
            force = bool(body.get("force", False))
            self.auth_store.audit_log("self_update", actor, client_ip, f"target={target or 'latest'} force={force}")
            res = self.deploy_ops.run_self_update(target=target, force=force, async_mode=async_mode, actor=actor)
            self._send_op_result(res)
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
                str(tag) if tag else None,
                force_compat=force_compat,
                async_mode=async_mode,
                actor=actor,
            )
            self._send_op_result(res)
            return

        if route == "/api/rollback":
            self.auth_store.audit_log("xui_rollback", actor, client_ip, "")
            res = self.deploy_ops.run_rollback(async_mode=async_mode, actor=actor)
            self._send_op_result(res)
            return

        if route == "/api/certs/issue":
            domain = str(body.get("domain", "")).strip()
            email = str(body.get("email", "")).strip()
            apply_mode = str(body.get("apply_mode", "none")).strip()
            self.auth_store.audit_log("cert_issue", actor, client_ip, f"domain={domain} apply={apply_mode}")
            res = self.deploy_ops.issue_certificate(
                domain, email=email, apply_mode=apply_mode, async_mode=async_mode, actor=actor
            )
            self._send_op_result(res)
            return

        if route == "/api/certs/self-signed":
            host = str(body.get("host", "")).strip()
            try:
                days = int(body.get("days", 3650))
            except (TypeError, ValueError):
                self._send_json(400, {"error": "Invalid days value."})
                return
            apply_mode = str(body.get("apply_mode", "none")).strip()
            self.auth_store.audit_log("cert_self_signed", actor, client_ip, f"host={host} days={days}")
            res = self.deploy_ops.generate_self_signed_cert(
                host, days=days, apply_mode=apply_mode, async_mode=async_mode, actor=actor
            )
            self._send_op_result(res)
            return

        if route == "/api/certs/renew":
            domain = str(body.get("domain", "")).strip()
            force = bool(body.get("force", False))
            self.auth_store.audit_log("cert_renew", actor, client_ip, f"domain={domain or 'all'} force={force}")
            res = self.deploy_ops.renew_certificates(
                domain=domain, force=force, async_mode=async_mode, actor=actor
            )
            self._send_op_result(res)
            return

        if route == "/api/certs/revoke":
            domain = str(body.get("domain", "")).strip()
            reason = str(body.get("reason", "unspecified")).strip()
            self.auth_store.audit_log("cert_revoke", actor, client_ip, f"domain={domain} reason={reason}")
            res = self.deploy_ops.revoke_certificate(
                domain=domain, reason=reason, async_mode=async_mode, actor=actor
            )
            self._send_op_result(res)
            return

        if route == "/api/certs/apply":
            domain = str(body.get("domain", "")).strip()
            target = str(body.get("target", "caddy")).strip()
            self.auth_store.audit_log("cert_apply", actor, client_ip, f"domain={domain} target={target}")
            res = self.deploy_ops.apply_certificate(
                domain=domain, target=target, async_mode=async_mode, actor=actor
            )
            self._send_op_result(res)
            return

        if route == "/api/network/proxy/disable":
            self.auth_store.audit_log("proxy_disable", actor, client_ip, "")
            res = self.deploy_ops.disable_proxy(async_mode=async_mode, actor=actor)
            self._send_op_result(res)
            return

        if route == "/api/network/panel/reset-2fa":
            self.auth_store.audit_log("panel_reset_2fa", actor, client_ip, "")
            res = self.deploy_ops.reset_panel_2fa(async_mode=async_mode, actor=actor)
            self._send_op_result(res)
            return

        if route == "/api/network/panel/credentials":
            uname = str(body.get("username", "")).strip()
            pw = str(body.get("password", ""))
            self.auth_store.audit_log("panel_reset_credentials", actor, client_ip, f"username={uname}")
            res = self.deploy_ops.reset_panel_credentials(
                uname, pw, async_mode=async_mode, actor=actor
            )
            self._send_op_result(res)
            return

        if route == "/api/network/dns-check":
            domain = str(body.get("domain", "")).strip()
            res = self.deploy_ops.check_domain_dns(domain)
            self._send_json(200 if res.get("ok") else 400, res)
            return

        if route == "/api/network/bbr":
            self.auth_store.audit_log("bbr_tuning", actor, client_ip, "")
            res = self.deploy_ops.apply_bbr_tuning(async_mode=async_mode, actor=actor)
            self._send_op_result(res)
            return

        if route == "/api/network/firewall":
            action = str(body.get("action", "")).strip()
            port = body.get("port")
            proto = str(body.get("proto", "tcp")).strip()
            self.auth_store.audit_log("firewall_action", actor, client_ip, f"action={action} port={port} proto={proto}")
            res = self.deploy_ops.run_firewall_action(
                action, port=port, proto=proto, async_mode=async_mode, actor=actor
            )
            self._send_op_result(res)
            return

        if route == "/api/audit":
            self.auth_store.audit_log("security_audit", actor, client_ip, "")
            res = self.deploy_ops.run_security_audit(async_mode=async_mode, actor=actor)
            if async_mode:
                self._send_op_result(res)
            else:
                self._send_json(200, res)
            return

        if route == "/api/backups":
            self.auth_store.audit_log("backup_create", actor, client_ip, "")
            res = self.deploy_ops.create_backup(async_mode=async_mode, actor=actor)
            self._send_op_result(res)
            return

        if route == "/api/backups/restore":
            name = str(body.get("name", "")).strip()
            self.auth_store.audit_log("backup_restore", actor, client_ip, f"name={name}")
            res = self.deploy_ops.restore_backup(name, async_mode=async_mode, actor=actor)
            self._send_op_result(res)
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
            res = self.deploy_ops.run_geo_update(scope, async_mode=async_mode, actor=actor)
            self._send_op_result(res)
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

        async_mode = bool(body.get("async", False))

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

        if route == "/api/network/proxy":
            self.auth_store.audit_log(
                "proxy_config_update",
                actor,
                client_ip,
                f"domain={body.get('domain')} port={body.get('port')} sub_mode={body.get('sub_mode')}",
            )
            res = self.deploy_ops.update_proxy_config(body, async_mode=async_mode, actor=actor)
            if not async_mode and res.get("ok"):
                self.server.sync_runtime_config()  # type: ignore[attr-defined]
            self._send_op_result(res)
            return

        if route == "/api/network/panel":
            self.auth_store.audit_log("panel_settings_update", actor, client_ip, "")
            res = self.deploy_ops.update_panel_settings(body, async_mode=async_mode, actor=actor)
            self._send_op_result(res)
            return

        if route == "/api/network/subscription":
            self.auth_store.audit_log(
                "sub_settings_update", actor, client_ip, f"enable={body.get('enable')}"
            )
            res = self.deploy_ops.update_subscription_settings(body, async_mode=async_mode, actor=actor)
            self._send_op_result(res)
            return

        if route == "/api/backups/cron":
            enabled = bool(body.get("enabled", False))
            try:
                hour = int(body.get("hour", 3))
                keep = int(body.get("keep", 7))
            except (TypeError, ValueError):
                self._send_json(400, {"error": "Invalid hour or retention count."})
                return
            self.auth_store.audit_log(
                "backup_cron_update", actor, client_ip, f"enabled={enabled} hour={hour} keep={keep}"
            )
            res = self.deploy_ops.update_backup_cron(enabled, hour=hour, keep=keep)
            self._send_json(200 if res.get("ok") else 400, res)
            return

        if route == "/api/webpanel/settings":
            try:
                idle_min = int(body.get("idle_minutes", 30))
            except (TypeError, ValueError):
                self._send_json(400, {"error": "Invalid idle timeout minutes."})
                return
            self.auth_store.audit_log("webpanel_settings_update", actor, client_ip, f"idle={idle_min}")
            res = self.deploy_ops.update_webpanel_settings(idle_min)
            if res.get("ok"):
                self.cfg.session_idle_minutes = self.auth_store.set_idle_minutes(idle_min)
            self._send_json(200 if res.get("ok") else 400, res)
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
