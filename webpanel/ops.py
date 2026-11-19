"""Operational bridge between the Web Management Panel and manage.sh / host inspection."""

from __future__ import annotations

import datetime as dt
import os
import re
import shutil
import subprocess
import tempfile
import threading
from typing import Any

from . import auth, probe

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
TAG_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$")

LIFECYCLE_ACTIONS: dict[str, list[str]] = {
    "start": ["start"],
    "stop": ["stop"],
    "restart": ["restart"],
    "reload_caddy": ["proxy", "reload"],
    "verify_proxy": ["proxy", "verify"],
    "sync_inbounds_caddy": ["inbounds", "sync-proxy"],
    "verify_inbounds": ["inbounds", "verify"],
}

GEO_SCOPES = frozenset({"std", "ir", "ru", "all"})


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text or "")


def read_kv_conf(path: str) -> dict[str, str]:
    """Read a KEY=\"VALUE\" config file without shell sourcing."""
    out: dict[str, str] = {}
    if not os.path.isfile(path):
        return out
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip()
                if len(v) >= 2 and (
                    (v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")
                ):
                    v = v[1:-1]
                out[k] = v
    except OSError:
        pass
    return out


class DeployOps:
    """Thread-safe controller for 3xui-deploy operational endpoints."""

    def __init__(self, install_dir: str, backup_dir: str, manage_script: str) -> None:
        self.install_dir = install_dir
        self.backup_dir = backup_dir
        self.manage_script = manage_script
        self._op_lock = threading.Lock()
        self._probe_lock = threading.Lock()

    @property
    def proxy_conf_path(self) -> str:
        return os.path.join(self.install_dir, "caddy", "proxy.conf")

    @property
    def probe_conf_path(self) -> str:
        return os.path.join(self.install_dir, "caddy", "probe.conf")

    @property
    def probe_state_path(self) -> str:
        return os.path.join(self.install_dir, "caddy", "probe-state.json")

    @property
    def webpanel_conf_path(self) -> str:
        return os.path.join(self.install_dir, "webpanel", "webpanel.conf")

    @property
    def deploy_log_path(self) -> str:
        candidate = os.path.join(self.install_dir, "logs", "3xui-deploy.log")
        if os.path.isfile(candidate):
            return candidate
        return os.path.expanduser("~/.3xui-deploy.log")

    @property
    def audit_log_path(self) -> str:
        return os.path.join(self.install_dir, "logs", "webpanel-audit.log")

    def _run_manage(self, args: list[str], timeout: int = 180) -> tuple[int, str]:
        if not os.path.isfile(self.manage_script):
            return 127, f"Manager script not found at {self.manage_script}"
        cmd = [
            "bash",
            self.manage_script,
            "--local",
            "--yes",
            "--dir",
            self.install_dir,
            *args,
        ]
        env = dict(os.environ)
        if not env.get("HOME"):
            home_dir = os.path.expanduser("~")
            if not home_dir or home_dir == "~":
                home_dir = "/root" if os.path.isdir("/root") else tempfile.gettempdir()
            env["HOME"] = home_dir
        std_bins = ["/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"]
        path_parts = [p for p in env.get("PATH", "").split(os.pathsep) if p]
        for sb in std_bins:
            if sb not in path_parts:
                path_parts.append(sb)
        env["PATH"] = os.pathsep.join(path_parts)
        env["NO_COLOR"] = "1"
        env["XUI_INSTALL_DIR"] = self.install_dir
        env["XUI_BACKUP_DIR"] = self.backup_dir
        env["XUI_LOG_FILE"] = os.path.join(self.install_dir, "logs", "3xui-deploy.log")
        try:
            proc = subprocess.run(
                cmd,
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=timeout,
                env=env,
                shell=False,
            )
            cleaned = strip_ansi(proc.stdout or "")
            return proc.returncode, cleaned
        except subprocess.TimeoutExpired:
            return 124, f"Operation timed out after {timeout}s."
        except FileNotFoundError as exc:
            return 127, f"Execution dependency missing: {exc}"
        except Exception as exc:
            return 1, f"Operation error: {exc}"

    def _read_compose_tag(self) -> str:
        compose_path = os.path.join(self.install_dir, "compose.yaml")
        if not os.path.isfile(compose_path):
            return "not-deployed"
        try:
            with open(compose_path, "r", encoding="utf-8") as fh:
                for line in fh:
                    m = re.search(r"image:\s*ghcr\.io/mhsanaei/3x-ui:([^\s#]+)", line)
                    if m:
                        return m.group(1)
        except OSError:
            pass
        return "unknown"

    def _get_docker_containers(self) -> list[dict[str, str]]:
        if not shutil.which("docker"):
            return []
        try:
            proc = subprocess.run(
                [
                    "docker",
                    "ps",
                    "-a",
                    "--filter",
                    "name=^3xui_",
                    "--format",
                    "{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Image}}",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=5,
                shell=False,
            )
            rows = []
            for line in (proc.stdout or "").splitlines():
                parts = line.split("\t")
                if len(parts) >= 4:
                    rows.append(
                        {
                            "name": parts[0],
                            "state": parts[1],
                            "status": parts[2],
                            "image": parts[3],
                        }
                    )
            return rows
        except Exception:
            return []

    def _get_host_metrics(self) -> dict[str, Any]:
        metrics: dict[str, Any] = {
            "load_avg": "unavailable",
            "uptime": "unavailable",
            "memory": "unavailable",
            "disk_root": "unavailable",
            "tcp_cc": "unknown",
            "qdisc": "unknown",
        }
        try:
            with open("/proc/loadavg", "r", encoding="utf-8") as fh:
                parts = fh.read().split()
                if len(parts) >= 3:
                    metrics["load_avg"] = " ".join(parts[:3])
        except OSError:
            pass
        try:
            with open("/proc/uptime", "r", encoding="utf-8") as fh:
                sec = int(float(fh.read().split()[0]))
                days, rem = divmod(sec, 86400)
                hrs, rem = divmod(rem, 3600)
                mins, _ = divmod(rem, 60)
                metrics["uptime"] = (
                    f"{days}d {hrs}h {mins}m" if days else f"{hrs}h {mins}m"
                )
        except OSError:
            pass
        try:
            meminfo: dict[str, int] = {}
            with open("/proc/meminfo", "r", encoding="utf-8") as fh:
                for line in fh:
                    if ":" in line:
                        k, rest = line.split(":", 1)
                        val = int(rest.strip().split()[0])
                        meminfo[k] = val
            if "MemTotal" in meminfo and "MemAvailable" in meminfo:
                total_mb = meminfo["MemTotal"] // 1024
                used_mb = (meminfo["MemTotal"] - meminfo["MemAvailable"]) // 1024
                metrics["memory"] = f"{used_mb} / {total_mb} MiB"
        except Exception:
            pass
        try:
            usage = shutil.disk_usage(
                self.install_dir if os.path.exists(self.install_dir) else "/"
            )
            gb = 1024**3
            pct = int((usage.used / usage.total) * 100) if usage.total else 0
            metrics["disk_root"] = (
                f"{usage.used / gb:.1f} / {usage.total / gb:.1f} GiB ({pct}%)"
            )
        except OSError:
            pass
        for key, proc_path in (
            ("tcp_cc", "/proc/sys/net/ipv4/tcp_congestion_control"),
            ("qdisc", "/proc/sys/net/core/default_qdisc"),
        ):
            try:
                with open(proc_path, "r", encoding="utf-8") as fh:
                    metrics[key] = fh.read().strip()
            except OSError:
                pass
        return metrics

    def _get_cert_summaries(self) -> list[dict[str, str]]:
        cert_root = os.path.join(self.install_dir, "cert")
        if not os.path.isdir(cert_root):
            return []
        certs: list[dict[str, str]] = []
        has_openssl = bool(shutil.which("openssl"))
        for name in sorted(os.listdir(cert_root)):
            fullchain = os.path.join(cert_root, name, "fullchain.pem")
            if not os.path.isfile(fullchain):
                continue
            expires = "unknown"
            status = "unknown"
            if has_openssl:
                try:
                    proc = subprocess.run(
                        ["openssl", "x509", "-enddate", "-noout", "-in", fullchain],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        text=True,
                        timeout=3,
                        shell=False,
                    )
                    if proc.returncode == 0 and "=" in proc.stdout:
                        expires = proc.stdout.strip().split("=", 1)[1]
                    chk = subprocess.run(
                        [
                            "openssl",
                            "x509",
                            "-checkend",
                            "1209600",
                            "-noout",
                            "-in",
                            fullchain,
                        ],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=3,
                        shell=False,
                    )
                    status = "ok" if chk.returncode == 0 else "expiring_soon"
                except Exception:
                    pass
            certs.append({"domain": name, "expires": expires, "status": status})
        return certs

    def get_protected_paths(self) -> list[str]:
        proxy_cfg = read_kv_conf(self.proxy_conf_path)
        wp_cfg = read_kv_conf(self.webpanel_conf_path)
        paths: list[str] = []
        for candidate in (
            proxy_cfg.get("SUB_PATH", "/sub/"),
            proxy_cfg.get("SUB_JSON_PATH", "/json/"),
            wp_cfg.get("WEBPANEL_PATH", "/deploy/"),
        ):
            if candidate and candidate != "/" and candidate not in paths:
                paths.append(candidate)

        # Query panel webBasePath & loopback inbound paths if manage.sh is available
        if os.path.isfile(self.manage_script):
            rc, out = self._run_manage(["proxy", "protected-paths"], timeout=15)
            if rc == 0:
                for line in out.splitlines():
                    p = line.strip()
                    if p.startswith("/") and p != "/" and p not in paths:
                        paths.append(p)
        return paths

    def get_overview(self) -> dict[str, Any]:
        proxy_cfg = read_kv_conf(self.proxy_conf_path)
        wp_cfg = read_kv_conf(self.webpanel_conf_path)
        probe_cfg = probe.load_probe_conf(self.probe_conf_path)
        probe_state = probe.load_probe_state(self.probe_state_path)

        domain = proxy_cfg.get("PROXY_DOMAIN", "")
        port = proxy_cfg.get("PROXY_PORT", "443")
        port_sfx = "" if port == "443" else f":{port}"
        wp_path = wp_cfg.get("WEBPANEL_PATH", "/deploy/")
        if not wp_path.startswith("/"):
            wp_path = "/" + wp_path
        if not wp_path.endswith("/"):
            wp_path += "/"

        sub_mode = proxy_cfg.get("SUB_MODE", "none")
        sub_url = ""
        if domain and sub_mode == "dedicated" and proxy_cfg.get("SUB_DOMAIN"):
            sub_url = f"https://{proxy_cfg['SUB_DOMAIN']}{port_sfx}{proxy_cfg.get('SUB_PATH', '/sub/')}"
        elif domain and sub_mode == "same":
            sub_url = f"https://{domain}{port_sfx}{proxy_cfg.get('SUB_PATH', '/sub/')}"

        return {
            "install_dir": self.install_dir,
            "deployed": os.path.isfile(os.path.join(self.install_dir, "compose.yaml")),
            "xui_tag": self._read_compose_tag(),
            "containers": self._get_docker_containers(),
            "metrics": self._get_host_metrics(),
            "proxy": {
                "enabled": proxy_cfg.get("PROXY_ENABLED", "false") == "true",
                "domain": domain,
                "port": port,
                "sub_mode": sub_mode,
                "sub_url": sub_url,
                "decoy_url": f"https://{domain}{port_sfx}/" if domain else "",
                "webpanel_url": f"https://{domain}{port_sfx}{wp_path}"
                if domain
                else "",
            },
            "webpanel": {
                "path": wp_path,
                "port": wp_cfg.get("WEBPANEL_PORT", "2059"),
                "idle_minutes": wp_cfg.get("WEBPANEL_SESSION_IDLE", "30"),
            },
            "probe": {
                "redirect_enabled": bool(probe_cfg.get("PROBE_REDIRECT_ENABLED")),
                "target": probe_cfg.get("PROBE_REDIRECT_TARGET", ""),
                "fallback_mode": probe_cfg.get("PROBE_FALLBACK_MODE", "decoy"),
                "active_state": probe_state.get("active_state", "primary"),
                "primary_ok": bool(probe_state.get("primary_ok", True)),
                "last_checked": probe_state.get("last_checked", ""),
            },
            "certs": self._get_cert_summaries(),
        }

    def get_compatibility(self) -> dict[str, Any]:
        rc, out = self._run_manage(["compat", "check"], timeout=30)
        parsed: dict[str, str] = {}
        for line in out.splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                key_norm = re.sub(r"[^a-z0-9]+", "_", k.strip().lower()).strip("_")
                if key_norm:
                    parsed[key_norm] = v.strip()
        return {"ok": rc == 0, "returncode": rc, "parsed": parsed, "output": out}

    def run_compat_test(self, tag: str) -> dict[str, Any]:
        if not tag or not TAG_RE.fullmatch(tag):
            return {"ok": False, "returncode": 2, "output": "Invalid 3x-ui tag format."}
        with self._op_lock:
            rc, out = self._run_manage(["compat", "test", tag], timeout=120)
        return {"ok": rc == 0, "returncode": rc, "tag": tag, "output": out}

    def run_lifecycle(self, action: str) -> dict[str, Any]:
        args = LIFECYCLE_ACTIONS.get(action)
        if not args:
            return {
                "ok": False,
                "returncode": 2,
                "output": f"Unsupported action: {action}",
            }
        with self._op_lock:
            rc, out = self._run_manage(args, timeout=120)
        return {"ok": rc == 0, "returncode": rc, "action": action, "output": out}

    def run_update(
        self, tag: str | None = None, force_compat: bool = False
    ) -> dict[str, Any]:
        args: list[str] = []
        if force_compat:
            args.append("--force-compat")
        args.append("update")
        if tag and tag.strip():
            clean_tag = tag.strip()
            if not TAG_RE.fullmatch(clean_tag):
                return {
                    "ok": False,
                    "returncode": 2,
                    "output": "Invalid target version tag.",
                }
            args.append(clean_tag)
        with self._op_lock:
            rc, out = self._run_manage(args, timeout=240)
        return {"ok": rc == 0, "returncode": rc, "output": out}

    def run_rollback(self) -> dict[str, Any]:
        with self._op_lock:
            rc, out = self._run_manage(["rollback"], timeout=180)
        return {"ok": rc == 0, "returncode": rc, "output": out}

    def get_inbounds(self) -> dict[str, Any]:
        rc, out = self._run_manage(["inbounds", "list"], timeout=30)
        return {"ok": rc == 0, "returncode": rc, "output": out}

    def run_security_audit(self) -> dict[str, Any]:
        rc, out = self._run_manage(["audit"], timeout=45)
        items = []
        for line in out.splitlines():
            m = re.match(r"^\s*\[(PASS|WARN|FAIL)\]\s*(.+)$", line)
            if m:
                items.append({"level": m.group(1), "message": m.group(2)})
        return {
            "ok": rc == 0,
            "returncode": rc,
            "items": items,
            "counts": {
                "pass": sum(1 for i in items if i["level"] == "PASS"),
                "warn": sum(1 for i in items if i["level"] == "WARN"),
                "fail": sum(1 for i in items if i["level"] == "FAIL"),
            },
            "output": out,
        }

    def list_backups(self) -> list[dict[str, Any]]:
        if not os.path.isdir(self.backup_dir):
            return []
        entries = []
        for name in os.listdir(self.backup_dir):
            if not name.endswith(".tar.gz"):
                continue
            full = os.path.join(self.backup_dir, name)
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            st = os.stat(full)
            entries.append(
                {
                    "name": name,
                    "size_bytes": st.st_size,
                    "modified_at": dt.datetime.fromtimestamp(
                        st.st_mtime, dt.timezone.utc
                    ).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "_mtime": st.st_mtime,
                }
            )
        entries.sort(key=lambda item: item["_mtime"], reverse=True)
        for e in entries:
            e.pop("_mtime", None)
        return entries

    def create_backup(self) -> dict[str, Any]:
        with self._op_lock:
            rc, out = self._run_manage(["backup"], timeout=180)
        return {
            "ok": rc == 0,
            "returncode": rc,
            "output": out,
            "backups": self.list_backups(),
        }

    def prune_backups(self, keep: int) -> dict[str, Any]:
        if keep < 1 or keep > 100:
            return {"ok": False, "error": "Keep count must be between 1 and 100."}
        backups = self.list_backups()
        removed: list[str] = []
        base_real = os.path.realpath(self.backup_dir)
        for item in backups[keep:]:
            target = os.path.realpath(os.path.join(self.backup_dir, item["name"]))
            if (
                os.path.dirname(target) == base_real
                and os.path.isfile(target)
                and not os.path.islink(target)
            ):
                os.unlink(target)
                removed.append(item["name"])
        return {"ok": True, "removed": removed, "backups": self.list_backups()}

    def get_logs(
        self, source: str, lines: int = 150, level: str = "ALL"
    ) -> dict[str, Any]:
        n = max(10, min(500, int(lines)))
        lvl = (level or "ALL").strip().upper()
        if source in ("deploy", "audit"):
            path = self.deploy_log_path if source == "deploy" else self.audit_log_path
            if not os.path.isfile(path):
                return {
                    "ok": True,
                    "source": source,
                    "lines": [],
                    "note": f"Log file does not exist yet: {path}",
                }
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    all_lines = fh.read().splitlines()
                tail = all_lines[-n:]
                if lvl in ("INFO", "OK", "WARN", "ERROR", "CRITICAL", "DEBUG", "AUDIT"):
                    tail = [ln for ln in tail if f"[{lvl}]" in ln]
                sanitized = [auth.sanitize_log_text(ln) for ln in tail]
                return {"ok": True, "source": source, "lines": sanitized}
            except OSError as exc:
                return {"ok": False, "source": source, "lines": [], "error": str(exc)}

        if source in ("xui", "caddy"):
            container = "3xui_app" if source == "xui" else "3xui_caddy"
            if not shutil.which("docker"):
                return {
                    "ok": False,
                    "source": source,
                    "lines": [],
                    "error": "Docker binary unavailable.",
                }
            try:
                proc = subprocess.run(
                    ["docker", "logs", f"--tail={n}", container],
                    check=False,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    timeout=10,
                    shell=False,
                )
                raw_lines = strip_ansi(proc.stdout or "").splitlines()
                if lvl in ("INFO", "WARN", "ERROR", "DEBUG"):
                    raw_lines = [ln for ln in raw_lines if lvl.lower() in ln.lower()]
                return {
                    "ok": proc.returncode == 0,
                    "source": source,
                    "lines": [auth.sanitize_log_text(x) for x in raw_lines],
                }
            except Exception as exc:
                return {"ok": False, "source": source, "lines": [], "error": str(exc)}

        return {
            "ok": False,
            "source": source,
            "lines": [],
            "error": "Unknown log source (use deploy, audit, xui, or caddy).",
        }

    def get_probe_bundle(self) -> dict[str, Any]:
        return {
            "config": probe.load_probe_conf(self.probe_conf_path),
            "state": probe.load_probe_state(self.probe_state_path),
            "protected_paths": self.get_protected_paths(),
            "presets": [
                {"label": "Cloudflare", "url": "https://www.cloudflare.com"},
                {"label": "Speedtest", "url": "https://www.speedtest.net"},
                {"label": "Nginx Welcome", "url": "https://nginx.org"},
            ],
        }

    def check_and_update_probe_state(
        self, sync_caddy_on_change: bool = True
    ) -> dict[str, Any]:
        """Probe primary & optional fallback targets, updating probe-state.json safely."""
        with self._probe_lock:
            cfg = probe.load_probe_conf(self.probe_conf_path)
            prev_state = probe.load_probe_state(self.probe_state_path)
            prev_active = prev_state.get("active_state", "primary")

            if not cfg.get("PROBE_REDIRECT_ENABLED"):
                new_state = {
                    **prev_state,
                    "active_state": "disabled",
                    "effective_target": "",
                    "reason": "Probe redirection is disabled.",
                    "consecutive_failures": 0,
                    "last_checked": dt.datetime.now(dt.timezone.utc).strftime(
                        "%Y-%m-%dT%H:%M:%SZ"
                    ),
                }
                probe.save_probe_state(self.probe_state_path, new_state)
                return {
                    "changed": prev_active != "disabled",
                    "state": new_state,
                    "sync_output": "",
                }

            primary_probe = probe.check_target_reachability(
                str(cfg.get("PROBE_REDIRECT_TARGET") or "")
            )
            secondary_probe = None
            if cfg.get("PROBE_FALLBACK_MODE") == "secondary_url" and cfg.get(
                "PROBE_FALLBACK_URL"
            ):
                secondary_probe = probe.check_target_reachability(
                    str(cfg.get("PROBE_FALLBACK_URL"))
                )

            eval_res = probe.evaluate_effective_state(
                cfg, primary_probe, secondary_probe
            )
            failures = (
                0
                if primary_probe.get("reachable")
                else int(prev_state.get("consecutive_failures", 0)) + 1
            )

            new_state = {
                "active_state": eval_res["active_state"],
                "effective_target": eval_res["effective_target"],
                "reason": eval_res["reason"],
                "consecutive_failures": failures,
                "last_checked": primary_probe.get("checked_at", ""),
                "primary_ok": bool(primary_probe.get("reachable")),
                "primary_status": int(primary_probe.get("status_code", 0)),
                "primary_latency_ms": int(primary_probe.get("latency_ms", 0)),
                "primary_error": str(primary_probe.get("error", "")),
                "secondary_ok": bool(secondary_probe.get("reachable"))
                if secondary_probe
                else False,
                "secondary_error": str(secondary_probe.get("error", ""))
                if secondary_probe
                else "",
            }
            probe.save_probe_state(self.probe_state_path, new_state)

            changed = prev_active != new_state["active_state"]
            sync_out = ""
            if (
                changed
                and sync_caddy_on_change
                and os.path.isfile(self.proxy_conf_path)
            ):
                with self._op_lock:
                    _, sync_out = self._run_manage(["proxy", "sync-caddy"], timeout=45)
            return {
                "changed": changed,
                "state": new_state,
                "primary": primary_probe,
                "secondary": secondary_probe,
                "sync_output": sync_out,
            }

    def update_probe_config(
        self, payload: dict[str, Any]
    ) -> tuple[bool, dict[str, Any]]:
        current = probe.load_probe_conf(self.probe_conf_path)
        merged = dict(current)
        merged.update(payload or {})
        ok, validated, err = probe.validate_probe_update(merged)
        if not ok:
            return False, {"error": err}

        with self._probe_lock:
            probe.save_probe_conf(self.probe_conf_path, validated)

        probe_res = self.check_and_update_probe_state(sync_caddy_on_change=False)
        proxy_cfg = read_kv_conf(self.proxy_conf_path)
        sync_ok = True
        sync_out = ""
        if proxy_cfg.get("PROXY_ENABLED") == "true":
            with self._op_lock:
                rc, sync_out = self._run_manage(["proxy", "sync-caddy"], timeout=60)
                sync_ok = rc == 0
                if not sync_ok:
                    # Rollback probe.conf to previous validated state if Caddy rejected config
                    with self._probe_lock:
                        probe.save_probe_conf(self.probe_conf_path, current)
                    self._run_manage(["proxy", "sync-caddy"], timeout=60)
                    return False, {
                        "error": f"Caddy rejected updated configuration (rolled back): {sync_out}"
                    }

        return True, {
            "config": validated,
            "state": probe_res["state"],
            "caddy_synced": sync_ok,
            "output": sync_out,
        }

    def get_decoy_config(self) -> dict[str, Any]:
        cfg = probe.load_probe_conf(self.probe_conf_path)
        index_path = os.path.join(self.install_dir, "caddy", "site", "index.html")
        custom_active = False
        if os.path.isfile(index_path):
            try:
                with open(index_path, "r", encoding="utf-8", errors="replace") as fh:
                    head = fh.read(1024)
                custom_active = "<!-- static-site-template:" not in head
            except OSError:
                pass
        return {
            "theme": cfg.get("DECOY_THEME", "cloud"),
            "site_name": cfg.get("DECOY_SITE_NAME", "Meridian Cloud Systems"),
            "tagline": cfg.get(
                "DECOY_SITE_TAGLINE",
                "Managed Edge Infrastructure & Reliability Engineering",
            ),
            "contact_email": cfg.get(
                "DECOY_CONTACT_EMAIL", "hello@meridiancloud.example"
            ),
            "custom_html_active": custom_active,
            "themes": [
                {
                    "id": "cloud",
                    "label": "Meridian Cloud Systems (Infrastructure / Edge)",
                },
                {
                    "id": "studio",
                    "label": "Northstar Digital Studio (Product & Design)",
                },
                {"id": "docs", "label": "Atlas Engineering Docs (Technical Portal)"},
            ],
        }

    def update_decoy_config(
        self, payload: dict[str, Any]
    ) -> tuple[bool, dict[str, Any]]:
        current = probe.load_probe_conf(self.probe_conf_path)
        theme = str(payload.get("theme", current["DECOY_THEME"])).strip()
        site_name = str(payload.get("site_name", current["DECOY_SITE_NAME"])).strip()
        tagline = str(payload.get("tagline", current["DECOY_SITE_TAGLINE"])).strip()
        email = str(
            payload.get("contact_email", current["DECOY_CONTACT_EMAIL"])
        ).strip()
        custom_html = payload.get("custom_html")

        ok_d, err_d = probe.validate_decoy_fields(theme, site_name, tagline, email)
        if not ok_d:
            return False, {"error": err_d}

        updated = dict(current)
        updated["DECOY_THEME"] = theme
        updated["DECOY_SITE_NAME"] = site_name
        updated["DECOY_SITE_TAGLINE"] = tagline
        updated["DECOY_CONTACT_EMAIL"] = email

        with self._probe_lock:
            probe.save_probe_conf(self.probe_conf_path, updated)

        if isinstance(custom_html, str) and custom_html.strip():
            if len(custom_html.encode("utf-8")) > 524288:
                return False, {"error": "Custom HTML exceeds 512 KB limit."}
            site_dir = os.path.join(self.install_dir, "caddy", "site")
            os.makedirs(site_dir, mode=0o755, exist_ok=True)
            fd, tmp_path = tempfile.mkstemp(
                prefix=".index-", suffix=".html", dir=site_dir
            )
            try:
                os.chmod(tmp_path, 0o644)
                with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(custom_html)
                os.replace(tmp_path, os.path.join(site_dir, "index.html"))
                os.chmod(os.path.join(site_dir, "index.html"), 0o644)
            except Exception as exc:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
                return False, {"error": f"Failed to write custom decoy HTML: {exc}"}
            return True, {
                "decoy": self.get_decoy_config(),
                "output": "Applied custom decoy index.html.",
            }

        with self._op_lock:
            rc, out = self._run_manage(["proxy", "decoy-apply"], timeout=45)
        if rc != 0:
            return False, {"error": out or "Failed to regenerate decoy website."}
        return True, {"decoy": self.get_decoy_config(), "output": out}

    def run_geo_update(self, scope: str) -> dict[str, Any]:
        if scope not in GEO_SCOPES:
            return {
                "ok": False,
                "returncode": 2,
                "output": "Invalid GeoIP scope (use std, ir, ru, or all).",
            }
        with self._op_lock:
            rc, out = self._run_manage(["geo-update", scope], timeout=180)
        return {"ok": rc == 0, "returncode": rc, "scope": scope, "output": out}
