"""Unit and HTTP integration tests for the standalone Web Management Panel."""

from __future__ import annotations

import http.client
import json
import os
import re
import tempfile
import threading
import time
import unittest
from unittest import mock

from webpanel import auth, ops, probe, server


class AuthTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.auth_file = os.path.join(self.tmpdir.name, "auth.json")
        self.audit_file = os.path.join(self.tmpdir.name, "audit.log")
        self.store = auth.AuthStore(self.auth_file, self.audit_file, idle_minutes=30, max_hours=12)

    def tearDown(self) -> None:
        self.tmpdir.cleanup()

    def test_password_policy_and_hashing(self) -> None:
        ok, _ = auth.validate_strong_password("short")
        self.assertFalse(ok)
        ok, _ = auth.validate_strong_password("password1234")
        self.assertFalse(ok)
        ok, _ = auth.validate_strong_password("StrongPass!2026")
        self.assertTrue(ok)

        ok, msg = self.store.set_user_password("admin", "StrongPass!2026")
        self.assertTrue(ok, msg)
        self.assertTrue(self.store.has_users())

        with open(self.auth_file, "r", encoding="utf-8") as fh:
            raw = fh.read()
        self.assertNotIn("StrongPass!2026", raw)
        self.assertIn("scrypt$", raw)

    def test_session_csrf_rotation_and_rate_limit(self) -> None:
        self.store.set_user_password("admin", "StrongPass!2026")

        ok, res = self.store.authenticate("admin", "StrongPass!2026", "198.51.100.10", "Browser/1.0")
        self.assertTrue(ok)
        tok = res["session_token"]
        csrf = res["csrf_token"]

        sess = self.store.validate_session(tok)
        self.assertIsNotNone(sess)
        self.assertTrue(auth.AuthStore.verify_csrf(sess, csrf))
        self.assertFalse(auth.AuthStore.verify_csrf(sess, "wrong-csrf"))

        # Rotate via password change
        ok_cp, _, rotated = self.store.change_password(
            "admin", "StrongPass!2026", "NewStrongPass!2027", tok, "198.51.100.10", "Browser/1.0"
        )
        self.assertTrue(ok_cp)
        self.assertIsNotNone(rotated)
        self.assertIsNone(self.store.validate_session(tok))
        self.assertIsNotNone(self.store.validate_session(rotated["session_token"]))

        # Audit log never leaks CSRF or password
        with open(self.audit_file, "r", encoding="utf-8") as fh:
            audit_txt = fh.read()
        self.assertNotIn(csrf, audit_txt)
        self.assertNotIn("StrongPass!2026", audit_txt)

        # Rate limiting after 5 failures from another IP
        for _ in range(5):
            ok_f, res_f = self.store.authenticate("admin", "WrongPassword123", "198.51.100.99", "Scanner")
            self.assertFalse(ok_f)
            self.assertEqual(res_f["status"], 401)
        ok_lock, res_lock = self.store.authenticate("admin", "NewStrongPass!2027", "198.51.100.99", "Scanner")
        self.assertFalse(ok_lock)
        self.assertEqual(res_lock["status"], 429)


class ProbeTests(unittest.TestCase):
    def test_url_normalization_and_ssrf_validation(self) -> None:
        self.assertEqual(probe.normalize_redirect_url("www.cloudflare.com"), "https://www.cloudflare.com")
        self.assertTrue(probe.validate_redirect_url("https://www.cloudflare.com")[0])
        self.assertTrue(probe.validate_redirect_url("https://www.speedtest.net")[0])

        for bad in (
            "",
            "http://127.0.0.1/admin",
            "https://10.0.0.1",
            "https://192.168.1.5",
            "https://169.254.169.254/latest/meta-data/",
            "https://localhost:8080",
            "https://[::1]/",
            "https://www.cloudflare.com;redir",
            "javascript:alert(1)",
        ):
            self.assertFalse(probe.validate_redirect_url(bad)[0], f"Expected rejection for {bad}")

    def test_probe_conf_roundtrip_and_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            conf_path = os.path.join(td, "probe.conf")
            ok, cfg, err = probe.validate_probe_update(
                {
                    "PROBE_REDIRECT_ENABLED": True,
                    "PROBE_REDIRECT_TARGET": "www.cloudflare.com",
                    "PROBE_REDIRECT_STATUS": "307",
                    "PROBE_FALLBACK_MODE": "secondary_url",
                    "PROBE_FALLBACK_URL": "www.speedtest.net",
                    "PROBE_BLOCK_CIDRS": "203.0.113.0/24",
                    "PROBE_ALLOW_CIDRS": "198.51.100.1",
                }
            )
            self.assertTrue(ok, err)
            probe.save_probe_conf(conf_path, cfg)
            loaded = probe.load_probe_conf(conf_path)
            self.assertTrue(loaded["PROBE_REDIRECT_ENABLED"])
            self.assertEqual(loaded["PROBE_REDIRECT_TARGET"], "https://www.cloudflare.com")
            self.assertEqual(loaded["PROBE_REDIRECT_STATUS"], "307")
            self.assertEqual(loaded["PROBE_FALLBACK_URL"], "https://www.speedtest.net")

            eval_fb = probe.evaluate_effective_state(
                loaded,
                {"reachable": False, "error": "timeout"},
                {"reachable": True, "status_code": 200},
            )
            self.assertEqual(eval_fb["active_state"], "fallback_secondary")
            self.assertEqual(eval_fb["effective_target"], "https://www.speedtest.net")

            eval_decoy = probe.evaluate_effective_state(
                loaded,
                {"reachable": False, "error": "timeout"},
                {"reachable": False, "error": "timeout"},
            )
            self.assertEqual(eval_decoy["active_state"], "fallback_decoy")

    def test_simulator_preserves_legitimate_and_protected_traffic(self) -> None:
        cfg = dict(probe.DEFAULT_PROBE_CONFIG)
        cfg["PROBE_REDIRECT_ENABLED"] = True
        state = {"active_state": "primary"}
        protected = ["/secretPanel/", "/deploy/", "/sub/", "/json/", "/ws1/"]

        legit = probe.simulate_request(
            cfg,
            state,
            protected,
            method="GET",
            path="/services.html",
            user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0",
            client_ip="198.51.100.25",
        )
        self.assertEqual(legit["decision"], "decoy")

        panel_req = probe.simulate_request(
            cfg,
            state,
            protected,
            method="POST",
            path="/secretPanel/login",
            user_agent="curl/8.5.0",
            client_ip="198.51.100.25",
        )
        self.assertEqual(panel_req["decision"], "pass_to_service")

        scanner_req = probe.simulate_request(
            cfg,
            state,
            protected,
            method="GET",
            path="/",
            user_agent="Nuclei - Open-source project",
            client_ip="198.51.100.25",
        )
        self.assertEqual(scanner_req["decision"], "redirect")
        self.assertEqual(scanner_req["target"], "https://www.cloudflare.com")

        env_probe = probe.simulate_request(
            cfg,
            state,
            protected,
            method="GET",
            path="/.env",
            user_agent="Mozilla/5.0",
            client_ip="198.51.100.25",
        )
        self.assertEqual(env_probe["decision"], "redirect")


class ServerIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.install_dir = os.path.join(self.tmpdir.name, "opt-3x-ui")
        self.backup_dir = os.path.join(self.tmpdir.name, "backups")
        os.makedirs(os.path.join(self.install_dir, "webpanel"), exist_ok=True)
        os.makedirs(os.path.join(self.install_dir, "caddy"), exist_ok=True)
        os.makedirs(os.path.join(self.install_dir, "logs"), exist_ok=True)

        with open(os.path.join(self.install_dir, "caddy", "proxy.conf"), "w", encoding="utf-8") as fh:
            fh.write('PROXY_ENABLED="true"\nPROXY_DOMAIN="panel.example.com"\nPROXY_PORT="443"\n')
        with open(os.path.join(self.install_dir, "webpanel", "webpanel.conf"), "w", encoding="utf-8") as fh:
            fh.write(
                'WEBPANEL_ENABLED="true"\nWEBPANEL_BIND="127.0.0.1"\nWEBPANEL_PORT="2059"\n'
                'WEBPANEL_PATH="/deploy/"\nWEBPANEL_USER="admin"\nWEBPANEL_DOMAIN="panel.example.com"\n'
            )

        self.auth_store = auth.AuthStore(
            os.path.join(self.install_dir, "webpanel", "auth.json"),
            os.path.join(self.install_dir, "logs", "webpanel-audit.log"),
        )
        self.auth_store.set_user_password("admin", "PanelSecretPass!2026")

        self.cfg = server.WebPanelConfig.from_install_dir(self.install_dir, self.backup_dir)
        self.deploy_ops = ops.DeployOps(self.install_dir, self.backup_dir, "/nonexistent/manage.sh")
        self.httpd = server.DeployHTTPServer(
            ("127.0.0.1", 0),
            server.DeployRequestHandler,
            self.cfg,
            self.auth_store,
            self.deploy_ops,
        )
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.tmpdir.cleanup()

    def _request(
        self,
        method: str,
        path: str,
        headers: dict[str, str] | None = None,
        body: dict | None = None,
    ) -> tuple[int, http.client.HTTPMessage, str]:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        hdrs = dict(headers or {})
        raw_body = None
        if body is not None:
            raw_body = json.dumps(body).encode("utf-8")
            hdrs["Content-Type"] = "application/json"
            hdrs["Content-Length"] = str(len(raw_body))
        conn.request(method, path, body=raw_body, headers=hdrs)
        resp = conn.getresponse()
        text = resp.read().decode("utf-8", errors="replace")
        conn.close()
        return resp.status, resp.headers, text

    def test_domain_isolation_auth_csrf_and_logout(self) -> None:
        # 1. Wrong Host / raw IP rejected with 403
        st, _, _ = self._request("GET", "/", headers={"Host": "203.0.113.5"})
        self.assertEqual(st, 403)

        # 2. Unauthenticated API call fails closed with 401
        st, hdrs, _ = self._request("GET", "/api/overview", headers={"Host": "panel.example.com"})
        self.assertEqual(st, 401)
        self.assertEqual(hdrs.get("X-Frame-Options"), "DENY")
        self.assertEqual(hdrs.get("Cache-Control"), "no-store")
        self.assertIn("default-src 'self'", hdrs.get("Content-Security-Policy", ""))

        # 3. Login succeeds and sets hardened cookie
        st, hdrs, txt = self._request(
            "POST",
            "/api/auth/login",
            headers={"Host": "panel.example.com", "Origin": "https://panel.example.com", "X-Forwarded-Proto": "https"},
            body={"username": "admin", "password": "PanelSecretPass!2026"},
        )
        self.assertEqual(st, 200)
        login_data = json.loads(txt)
        csrf = login_data["csrf_token"]
        set_cookie = hdrs.get("Set-Cookie", "")
        self.assertIn("3xui_deploy_sid=", set_cookie)
        self.assertIn("Path=/deploy/", set_cookie)
        self.assertIn("HttpOnly", set_cookie)
        self.assertIn("Secure", set_cookie)
        self.assertIn("SameSite=Strict", set_cookie)
        cookie_kv = set_cookie.split(";", 1)[0]

        # 4. Authenticated GET /api/overview & /deploy/api/probe work
        st, _, ov_txt = self._request(
            "GET",
            "/api/overview",
            headers={"Host": "panel.example.com", "Cookie": cookie_kv},
        )
        self.assertEqual(st, 200)
        self.assertEqual(json.loads(ov_txt)["proxy"]["domain"], "panel.example.com")

        # 5. Mutating POST without CSRF is rejected (403)
        st, _, _ = self._request(
            "POST",
            "/api/probe/simulate",
            headers={"Host": "panel.example.com", "Cookie": cookie_kv},
            body={"path": "/.env", "user_agent": "Mozilla/5.0"},
        )
        self.assertEqual(st, 403)

        # 6. Mutating POST with CSRF works
        with mock.patch.object(self.deploy_ops, "get_protected_paths", return_value=["/sec/", "/deploy/"]):
            st, _, sim_txt = self._request(
                "POST",
                "/api/probe/simulate",
                headers={
                    "Host": "panel.example.com",
                    "Cookie": cookie_kv,
                    "X-CSRF-Token": csrf,
                    "Origin": "https://panel.example.com",
                },
                body={"method": "GET", "path": "/.env", "user_agent": "sqlmap/1.8"},
            )
        self.assertEqual(st, 200)
        self.assertEqual(json.loads(sim_txt)["matched_rule"], "redirect_disabled")

        # 7. Logout revokes session
        st, _, _ = self._request(
            "POST",
            "/api/auth/logout",
            headers={"Host": "panel.example.com", "Cookie": cookie_kv, "X-CSRF-Token": csrf},
            body={},
        )
        self.assertEqual(st, 200)
        st, _, _ = self._request(
            "GET",
            "/api/overview",
            headers={"Host": "panel.example.com", "Cookie": cookie_kv},
        )
        self.assertEqual(st, 401)

    def test_ops_run_manage_sets_home_and_path_under_minimal_env(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manage_path = os.path.join(tmp, "manage.sh")
            with open(manage_path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write("#!/usr/bin/env bash\nexit 0\n")
            deploy_ops = ops.DeployOps(tmp, os.path.join(tmp, "backups"), manage_path)
            fake_proc = mock.Mock(returncode=0, stdout="ok\n")
            with mock.patch.dict(os.environ, {}, clear=True), mock.patch(
                "subprocess.run", return_value=fake_proc
            ) as run_mock:
                rc, out = deploy_ops._run_manage(["proxy", "sync-caddy"])
            self.assertEqual(rc, 0)
            self.assertEqual(out, "ok\n")
            passed_env = run_mock.call_args.kwargs["env"]
            self.assertTrue(passed_env.get("HOME"))
            self.assertIn("/usr/local/sbin", passed_env.get("PATH", ""))
            self.assertEqual(passed_env.get("NO_COLOR"), "1")

    def _login_session(self) -> tuple[str, str]:
        st, hdrs, txt = self._request(
            "POST",
            "/api/auth/login",
            headers={
                "Host": "panel.example.com",
                "Origin": "https://panel.example.com",
                "X-Forwarded-Proto": "https",
            },
            body={"username": "admin", "password": "PanelSecretPass!2026"},
        )
        self.assertEqual(st, 200)
        csrf = json.loads(txt)["csrf_token"]
        cookie_kv = hdrs.get("Set-Cookie", "").split(";", 1)[0]
        return cookie_kv, csrf

    def test_jobs_sse_stream_and_history_redaction(self) -> None:
        cookie_kv, csrf = self._login_session()

        def _fake_stream(args, on_line=None, timeout=240, stdin_text=None):
            if on_line:
                on_line("[INFO] [update:pull] Pulling image")
                on_line("[OK] PG Pass : SuperSecretPG99!")
            return 0, "[OK] Done"

        with mock.patch.object(self.deploy_ops, "_run_manage_streaming", side_effect=_fake_stream):
            st, _, txt = self._request(
                "POST",
                "/api/lifecycle",
                headers={
                    "Host": "panel.example.com",
                    "Cookie": cookie_kv,
                    "X-CSRF-Token": csrf,
                    "Origin": "https://panel.example.com",
                },
                body={"action": "restart", "async": True},
            )
            self.assertEqual(st, 202)
            job = json.loads(txt)["job"]
            job_id = job["id"]

            # Wait briefly for daemon job thread to finish
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline:
                cur = self.deploy_ops.get_job(job_id)
                if cur and cur["status"] in ("succeeded", "failed"):
                    break
                time.sleep(0.05)

        st, _, list_txt = self._request(
            "GET",
            "/api/jobs",
            headers={"Host": "panel.example.com", "Cookie": cookie_kv},
        )
        self.assertEqual(st, 200)
        jobs = json.loads(list_txt)["jobs"]
        self.assertTrue(any(j["id"] == job_id and j["status"] == "succeeded" for j in jobs))

        # Incremental poll & SSE stream both expose redacted lines
        st, _, job_txt = self._request(
            "GET",
            f"/api/jobs/{job_id}?since=0",
            headers={"Host": "panel.example.com", "Cookie": cookie_kv},
        )
        self.assertEqual(st, 200)
        job_data = json.loads(job_txt)
        joined = "\n".join(job_data["lines"])
        self.assertNotIn("SuperSecretPG99!", joined)
        self.assertIn("[REDACTED]", joined)

        st, sse_hdrs, sse_body = self._request(
            "GET",
            f"/api/jobs/{job_id}/stream",
            headers={"Host": "panel.example.com", "Cookie": cookie_kv},
        )
        self.assertEqual(st, 200)
        self.assertIn("text/event-stream", sse_hdrs.get("Content-Type", ""))
        self.assertIn("event: done", sse_body)

        with open(self.deploy_ops.ops_history_path, "r", encoding="utf-8") as fh:
            hist_raw = fh.read()
        self.assertNotIn("SuperSecretPG99!", hist_raw)

    def test_certs_network_credentials_and_backup_safety(self) -> None:
        cookie_kv, csrf = self._login_session()
        auth_hdrs = {
            "Host": "panel.example.com",
            "Cookie": cookie_kv,
            "X-CSRF-Token": csrf,
            "Origin": "https://panel.example.com",
        }

        # Certificate discovery
        cert_dir = os.path.join(self.install_dir, "cert", "panel.example.com")
        os.makedirs(cert_dir, exist_ok=True)
        with open(os.path.join(cert_dir, "fullchain.pem"), "w", encoding="utf-8") as fh:
            fh.write("DUMMY CERT\n")
        with open(os.path.join(cert_dir, "privkey.pem"), "w", encoding="utf-8") as fh:
            fh.write("DUMMY KEY\n")

        st, _, certs_txt = self._request("GET", "/api/certs", headers={"Host": "panel.example.com", "Cookie": cookie_kv})
        self.assertEqual(st, 200)
        certs_data = json.loads(certs_txt)
        self.assertEqual(len(certs_data["certs"]), 1)
        self.assertEqual(certs_data["certs"][0]["domain"], "panel.example.com")

        # Reject invalid cert domain / revocation reason
        st, _, _ = self._request("POST", "/api/certs/issue", headers=auth_hdrs, body={"domain": "bad;domain"})
        self.assertEqual(st, 400)
        st, _, _ = self._request(
            "POST",
            "/api/certs/revoke",
            headers=auth_hdrs,
            body={"domain": "panel.example.com", "reason": "badreason"},
        )
        self.assertEqual(st, 400)

        # Valid cert revoke dispatches cleanly to manage.sh
        with mock.patch.object(self.deploy_ops, "_run_manage", return_value=(0, "[OK] Revoked")) as run_mock:
            st, _, _ = self._request(
                "POST",
                "/api/certs/revoke",
                headers=auth_hdrs,
                body={"domain": "panel.example.com", "reason": "superseded"},
            )
            self.assertEqual(st, 200)
            self.assertEqual(run_mock.call_args.args[0], ["certs", "revoke", "panel.example.com", "superseded"])

        # Panel credentials update transmits password via stdin only and never logs it
        with mock.patch.object(self.deploy_ops, "_run_manage", return_value=(0, "[OK] Updated")) as run_mock:
            st, _, _ = self._request(
                "POST",
                "/api/network/panel/credentials",
                headers=auth_hdrs,
                body={"username": "opsadmin", "password": "VeryStrongPanelPass!2026"},
            )
            self.assertEqual(st, 200)
            self.assertEqual(run_mock.call_args.args[0], ["settings", "reset-credentials"])
            self.assertEqual(run_mock.call_args.kwargs["stdin_text"], "opsadmin\nVeryStrongPanelPass!2026\n")

        audit_file = os.path.join(self.install_dir, "logs", "webpanel-audit.log")
        with open(audit_file, "r", encoding="utf-8") as fh:
            self.assertNotIn("VeryStrongPanelPass!2026", fh.read())

        # Backup restore path traversal rejection
        os.makedirs(self.backup_dir, exist_ok=True)
        st, _, _ = self._request(
            "POST",
            "/api/backups/restore",
            headers=auth_hdrs,
            body={"name": "../../etc/passwd.tar.gz"},
        )
        self.assertEqual(st, 400)

        # WebPanel idle timeout update syncs AuthStore dynamically
        with mock.patch.object(self.deploy_ops, "_run_manage", return_value=(0, "[OK] updated")):
            st, _, _ = self._request(
                "PUT",
                "/api/webpanel/settings",
                headers=auth_hdrs,
                body={"idle_minutes": 45},
            )
            self.assertEqual(st, 200)
            self.assertEqual(self.auth_store.idle_seconds, 2700)

    def test_static_assets_etag_gzip_and_csp_hygiene(self) -> None:
        st, hdrs, _ = self._request(
            "GET",
            "/assets/app.css",
            headers={"Host": "panel.example.com", "Accept-Encoding": "gzip"},
        )
        self.assertEqual(st, 200)
        self.assertEqual(hdrs.get("Content-Encoding"), "gzip")
        self.assertEqual(hdrs.get("Vary"), "Accept-Encoding")
        etag = hdrs.get("ETag", "")
        self.assertTrue(etag)
        st_304, _, _ = self._request(
            "GET",
            "/assets/app.css",
            headers={"Host": "panel.example.com", "If-None-Match": etag},
        )
        self.assertEqual(st_304, 304)

        static_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "webpanel", "static")
        with open(os.path.join(static_dir, "index.html"), "r", encoding="utf-8") as fh:
            html_txt = fh.read()
        with open(os.path.join(static_dir, "app.css"), "r", encoding="utf-8") as fh:
            css_txt = fh.read()
        with open(os.path.join(static_dir, "app.js"), "r", encoding="utf-8") as fh:
            js_txt = fh.read()

        # Strict CSP & XSS invariants
        self.assertIsNone(re.search(r"<script(?![^>]*\bsrc=)", html_txt, re.IGNORECASE))
        self.assertIsNone(re.search(r"\bon[a-z]+\s*=", html_txt, re.IGNORECASE))
        self.assertIsNone(re.search(r"\bstyle\s*=", html_txt, re.IGNORECASE))
        self.assertNotIn("innerHTML", js_txt)
        self.assertNotIn("outerHTML", js_txt)
        self.assertNotIn("insertAdjacentHTML", js_txt)
        self.assertIsNone(re.search(r"\.style\.", js_txt))
        self.assertIsNone(re.search(r'(?:src|href)\s*=\s*["\']https?://', html_txt, re.IGNORECASE))
        self.assertIsNone(re.search(r'https?://', css_txt, re.IGNORECASE))


if __name__ == "__main__":
    unittest.main()
