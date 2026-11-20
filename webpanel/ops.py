"""Operational bridge between the Web Management Panel and manage.sh / host inspection."""

from __future__ import annotations

import datetime as dt
import ipaddress
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from collections.abc import Callable
from typing import Any

from . import __version__ as WEBPANEL_VERSION
from . import auth, probe

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
TAG_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$")
DEPLOY_REF_RE = re.compile(r"^(?:main|v[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?)$")
SAFE_BACKUP_NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\.tar\.gz$")
WEBPATH_RE = re.compile(r"^/[a-zA-Z0-9/_-]{0,127}$")
PG_IDENT_RE = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_-]{0,62}$")
REVOCATION_REASONS = frozenset(
    {
        "unspecified",
        "keycompromise",
        "affiliationchanged",
        "superseded",
        "cessationofoperation",
    }
)
CERT_APPLY_MODES = frozenset({"none", "caddy", "panel"})
CERT_APPLY_TARGETS = frozenset({"caddy", "panel"})
FIREWALL_PROTOS = frozenset({"tcp", "udp", "both"})

LIFECYCLE_ACTIONS: dict[str, list[str]] = {
    "start": ["start"],
    "stop": ["stop"],
    "restart": ["restart"],
    "reload_caddy": ["proxy", "reload"],
    "verify_proxy": ["proxy", "verify"],
    "sync_inbounds_caddy": ["inbounds", "sync-proxy"],
    "verify_inbounds": ["inbounds", "verify"],
    "sync_firewall": ["inbounds", "sync-fw"],
    "self_update": ["self-update"],
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


def parse_kv_lines(text: str) -> dict[str, str]:
    """Parse KEY=VALUE stdout emitted by manage.sh CLI helpers."""
    out: dict[str, str] = {}
    for line in (text or "").splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        if re.fullmatch(r"[A-Z0-9_]+", k):
            out[k] = v.strip()
    return out


def read_script_version(manage_script: str) -> str:
    """Extract DEPLOY_VERSION from manage.sh header lines."""
    if not manage_script or not os.path.isfile(manage_script):
        return ""
    try:
        with open(manage_script, "r", encoding="utf-8", errors="replace") as fh:
            for idx, line in enumerate(fh):
                if idx > 80:
                    break
                m = re.match(r'^DEPLOY_VERSION="([^"]+)"', line.strip())
                if m:
                    return m.group(1).strip()
    except OSError:
        pass
    return ""


def validate_port_value(raw: Any) -> tuple[bool, int]:
    try:
        p = int(str(raw).strip())
    except (TypeError, ValueError):
        return False, 0
    if 1 <= p <= 65535:
        return True, p
    return False, 0


def validate_domain_name(domain: str) -> bool:
    d = (domain or "").strip()
    return bool(d and len(d) <= 253 and probe.DOMAIN_RE.fullmatch(d))


def validate_domain_or_ip(value: str) -> bool:
    v = (value or "").strip()
    if not v or "/" in v or ".." in v:
        return False
    try:
        ipaddress.ip_address(v)
        return True
    except ValueError:
        return validate_domain_name(v)


def validate_listen_ip_value(value: str) -> bool:
    v = (value or "").strip()
    if v in ("", "all", "none", "default", "0.0.0.0", "::", "127.0.0.1", "::1"):
        return True
    try:
        ipaddress.ip_address(v)
        return True
    except ValueError:
        return False


def normalize_webpath(path: str) -> str:
    p = (path or "").strip()
    if not p or p == "/":
        return "/"
    if not p.startswith("/"):
        p = "/" + p
    if not p.endswith("/"):
        p += "/"
    return p


def validate_webpath_value(path: str) -> bool:
    p = (path or "").strip()
    if not p or len(p) > 128 or ".." in p or "//" in p:
        return False
    return bool(WEBPATH_RE.fullmatch(p))


def _atomic_write_json_file(path: str, payload: Any, mode: int = 0o600) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, mode=0o700, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=parent)
    try:
        os.chmod(tmp_path, mode)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp_path, path)
        os.chmod(path, mode)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def _parse_openssl_date(raw: str) -> dt.datetime | None:
    clean = re.sub(r"\s+", " ", (raw or "").strip())
    for fmt in ("%b %d %H:%M:%S %Y %Z", "%b %d %H:%M:%S %Y"):
        try:
            parsed = dt.datetime.strptime(clean, fmt)
            return parsed.replace(tzinfo=dt.timezone.utc)
        except ValueError:
            continue
    return None


def _summarize_command_output(rc: int, lines: list[str], title: str) -> str:
    if rc == 0:
        for ln in reversed(lines):
            if "[OK]" in ln:
                return ln.replace("[OK]", "").strip()
        return f"{title} completed successfully."

    root_cause = ""
    resolution = ""
    last_err = ""
    for ln in lines:
        s = ln.strip()
        if s.startswith("Root Cause :"):
            root_cause = s.split(":", 1)[1].strip()
        elif s.startswith("Resolution :"):
            resolution = s.split(":", 1)[1].strip()
        elif "[ERROR]" in s or "[CRITICAL]" in s:
            last_err = re.sub(r"^\[(ERROR|CRITICAL)\]\s*", "", s)

    if root_cause and resolution:
        return f"{root_cause} — {resolution}"
    if root_cause:
        return root_cause
    if last_err:
        return last_err
    for ln in reversed(lines):
        if ln.strip():
            return ln.strip()
    return f"{title} failed (exit code {rc})."


class DeployOps:
    """Thread-safe controller for 3xui-deploy operational endpoints and background jobs."""

    MAX_HISTORY_ITEMS = 100
    MAX_JOB_LINES = 600

    def __init__(self, install_dir: str, backup_dir: str, manage_script: str) -> None:
        self.install_dir = install_dir
        self.backup_dir = backup_dir
        self.manage_script = manage_script
        self._op_lock = threading.Lock()
        self._probe_lock = threading.Lock()
        self._jobs_lock = threading.RLock()
        self._jobs: dict[str, dict[str, Any]] = {}
        self._job_conds: dict[str, threading.Condition] = {}
        self._pub_ip_cache: dict[str, Any] = {"ts": -1000.0, "v4": "", "v6": ""}
        self._load_history_from_disk()

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

    @property
    def ops_history_path(self) -> str:
        return os.path.join(self.install_dir, "logs", "webpanel-ops-history.json")

    def _load_history_from_disk(self) -> None:
        if not os.path.isfile(self.ops_history_path):
            return
        try:
            with open(self.ops_history_path, "r", encoding="utf-8") as fh:
                raw = json.load(fh)
            if not isinstance(raw, list):
                return
            with self._jobs_lock:
                for entry in raw[: self.MAX_HISTORY_ITEMS]:
                    if isinstance(entry, dict) and entry.get("id"):
                        entry.setdefault("lines", [])
                        self._jobs[str(entry["id"])] = entry
        except Exception:  # noqa: BLE001
            pass

    def _save_history_to_disk(self) -> None:
        with self._jobs_lock:
            items = sorted(
                self._jobs.values(),
                key=lambda j: str(j.get("started_at", "")),
                reverse=True,
            )[: self.MAX_HISTORY_ITEMS]
            # Keep compact persisted history (truncate stored output lines to last 120)
            serializable = []
            for item in items:
                copy_item = dict(item)
                lines = list(copy_item.get("lines") or [])
                if len(lines) > 120:
                    copy_item["lines"] = lines[-120:]
                serializable.append(copy_item)
        try:
            _atomic_write_json_file(self.ops_history_path, serializable, mode=0o600)
        except OSError:
            pass

    def _build_manage_env(self, extra_env: dict[str, str] | None = None) -> dict[str, str]:
        env = dict(os.environ)
        if not env.get("HOME"):
            home_dir = os.path.expanduser("~")
            if not home_dir or home_dir == "~":
                home_dir = "/root" if os.path.isdir("/root") else tempfile.gettempdir()
            env["HOME"] = home_dir
        std_bins = [
            "/usr/local/sbin",
            "/usr/local/bin",
            "/usr/sbin",
            "/usr/bin",
            "/sbin",
            "/bin",
        ]
        path_parts = [p for p in env.get("PATH", "").split(os.pathsep) if p]
        for sb in std_bins:
            if sb not in path_parts:
                path_parts.append(sb)
        env["PATH"] = os.pathsep.join(path_parts)
        env["NO_COLOR"] = "1"
        env["WEBPANEL_NO_SELF_RESTART"] = "1"
        env["XUI_INSTALL_DIR"] = self.install_dir
        env["XUI_BACKUP_DIR"] = self.backup_dir
        env["XUI_LOG_FILE"] = os.path.join(self.install_dir, "logs", "3xui-deploy.log")
        if extra_env:
            env.update(extra_env)
        return env

    def _run_manage(
        self,
        args: list[str],
        timeout: int = 180,
        stdin_text: str | None = None,
    ) -> tuple[int, str]:
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
        env = self._build_manage_env()
        try:
            proc = subprocess.run(
                cmd,
                check=False,
                input=stdin_text,
                stdin=None if stdin_text is not None else subprocess.DEVNULL,
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
        except Exception as exc:  # noqa: BLE001
            return 1, f"Operation error: {exc}"

    def _run_manage_streaming(
        self,
        args: list[str],
        on_line: Callable[[str], None] | None = None,
        timeout: int = 240,
        stdin_text: str | None = None,
    ) -> tuple[int, str]:
        if not os.path.isfile(self.manage_script):
            msg = f"Manager script not found at {self.manage_script}"
            if on_line:
                on_line(msg)
            return 127, msg
        cmd = [
            "bash",
            self.manage_script,
            "--local",
            "--yes",
            "--dir",
            self.install_dir,
            *args,
        ]
        env = self._build_manage_env()
        collected: list[str] = []
        timed_out = threading.Event()
        try:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env=env,
                shell=False,
            )
        except FileNotFoundError as exc:
            msg = f"Execution dependency missing: {exc}"
            if on_line:
                on_line(msg)
            return 127, msg
        except Exception as exc:  # noqa: BLE001
            msg = f"Operation error: {exc}"
            if on_line:
                on_line(msg)
            return 1, msg

        def _kill_on_timeout() -> None:
            timed_out.set()
            try:
                proc.kill()
            except OSError:
                pass

        timer = threading.Timer(timeout, _kill_on_timeout)
        timer.daemon = True
        timer.start()

        try:
            if stdin_text is not None and proc.stdin is not None:
                try:
                    proc.stdin.write(stdin_text)
                    proc.stdin.flush()
                    proc.stdin.close()
                except OSError:
                    pass

            if proc.stdout is not None:
                for raw_line in proc.stdout:
                    clean_line = auth.sanitize_log_text(strip_ansi(raw_line.rstrip("\r\n")))
                    collected.append(clean_line)
                    if on_line:
                        on_line(clean_line)
                proc.stdout.close()
            rc = proc.wait()
        finally:
            timer.cancel()

        if timed_out.is_set():
            msg = f"Operation timed out after {timeout}s."
            collected.append(msg)
            if on_line:
                on_line(msg)
            return 124, "\n".join(collected)
        return rc, "\n".join(collected)

    def _update_job(
        self,
        job_id: str,
        *,
        status: str | None = None,
        stage: str | None = None,
        progress: int | None = None,
        returncode: int | None = None,
        summary: str | None = None,
        append_line: str | None = None,
        meta_update: dict[str, Any] | None = None,
        finished: bool = False,
    ) -> None:
        with self._jobs_lock:
            job = self._jobs.get(job_id)
            if not job:
                return
            if status is not None:
                job["status"] = status
            if stage is not None:
                job["stage"] = stage
            if progress is not None:
                job["progress"] = max(0, min(100, int(progress)))
            if returncode is not None:
                job["returncode"] = returncode
            if summary is not None:
                job["summary"] = auth.sanitize_log_text(summary)
            if meta_update:
                job.setdefault("meta", {}).update(meta_update)
            if append_line is not None:
                clean = auth.sanitize_log_text(append_line)
                lines = job.setdefault("lines", [])
                lines.append(clean)
                if len(lines) > self.MAX_JOB_LINES:
                    del lines[: len(lines) - self.MAX_JOB_LINES]
                # Infer stage & smooth progress from structured manage.sh markers
                m_stage = re.search(r"\[([a-zA-Z0-9_-]+):([a-zA-Z0-9_-]+)\]", clean)
                if m_stage:
                    job["stage"] = f"{m_stage.group(1)}:{m_stage.group(2)}"
                    job["progress"] = min(92, max(int(job.get("progress", 15)), int(job.get("progress", 15)) + 12))
                elif "[INFO]" in clean:
                    job["progress"] = min(90, max(int(job.get("progress", 12)), int(job.get("progress", 12)) + 6))
                elif "[OK]" in clean:
                    job["progress"] = min(95, max(int(job.get("progress", 20)), int(job.get("progress", 20)) + 10))
            if finished:
                now_iso = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                job["finished_at"] = now_iso
                try:
                    t0 = float(job.get("_started_mono", 0.0))
                    if t0 > 0:
                        job["duration_ms"] = int((time.monotonic() - t0) * 1000)
                except Exception:
                    pass
                job.pop("_started_mono", None)
                self._save_history_to_disk()
            cond = self._job_conds.get(job_id)
            if cond:
                cond.notify_all()

    def _snapshot_job(self, job: dict[str, Any], since: int = 0) -> dict[str, Any]:
        lines = list(job.get("lines") or [])
        idx = max(0, min(len(lines), int(since)))
        return {
            "id": job["id"],
            "type": job["type"],
            "title": job["title"],
            "actor": job.get("actor", "admin"),
            "status": job["status"],
            "stage": job.get("stage", "queued"),
            "progress": int(job.get("progress", 0)),
            "started_at": job.get("started_at", ""),
            "finished_at": job.get("finished_at", ""),
            "duration_ms": int(job.get("duration_ms", 0)),
            "returncode": job.get("returncode"),
            "summary": job.get("summary", ""),
            "meta": dict(job.get("meta") or {}),
            "total_lines": len(lines),
            "next_index": len(lines),
            "lines": lines[idx:],
        }

    def list_jobs(self, limit: int = 50) -> list[dict[str, Any]]:
        with self._jobs_lock:
            ordered = sorted(
                self._jobs.values(),
                key=lambda j: str(j.get("started_at", "")),
                reverse=True,
            )[: max(1, min(100, int(limit)))]
            return [
                {
                    "id": j["id"],
                    "type": j["type"],
                    "title": j["title"],
                    "actor": j.get("actor", "admin"),
                    "status": j["status"],
                    "stage": j.get("stage", ""),
                    "progress": int(j.get("progress", 0)),
                    "started_at": j.get("started_at", ""),
                    "finished_at": j.get("finished_at", ""),
                    "duration_ms": int(j.get("duration_ms", 0)),
                    "returncode": j.get("returncode"),
                    "summary": j.get("summary", ""),
                    "line_count": len(j.get("lines") or []),
                    "meta": dict(j.get("meta") or {}),
                }
                for j in ordered
            ]

    def get_job(self, job_id: str, since: int = 0) -> dict[str, Any] | None:
        with self._jobs_lock:
            job = self._jobs.get(job_id)
            if not job:
                return None
            return self._snapshot_job(job, since=since)

    def wait_for_job_update(self, job_id: str, after_index: int, timeout: float = 10.0) -> dict[str, Any] | None:
        with self._jobs_lock:
            job = self._jobs.get(job_id)
            if not job:
                return None
            if len(job.get("lines") or []) > after_index or job.get("status") in ("succeeded", "failed"):
                return self._snapshot_job(job, since=after_index)
            cond = self._job_conds.get(job_id)
            if not cond:
                return self._snapshot_job(job, since=after_index)
            cond.wait(timeout=timeout)
            job = self._jobs.get(job_id)
            return self._snapshot_job(job, since=after_index) if job else None

    def start_job(
        self,
        job_type: str,
        title: str,
        actor: str,
        runner: Callable[[Callable[[str], None]], dict[str, Any]],
    ) -> dict[str, Any]:
        job_id = uuid.uuid4().hex[:12]
        now_iso = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        job_record: dict[str, Any] = {
            "id": job_id,
            "type": job_type,
            "title": title,
            "actor": actor or "admin",
            "status": "queued",
            "stage": "queued",
            "progress": 5,
            "started_at": now_iso,
            "finished_at": "",
            "duration_ms": 0,
            "returncode": None,
            "summary": "Queued for execution...",
            "lines": [],
            "meta": {},
            "_started_mono": time.monotonic(),
        }
        with self._jobs_lock:
            self._jobs[job_id] = job_record
            self._job_conds[job_id] = threading.Condition(self._jobs_lock)
            # Keep memory bounded
            if len(self._jobs) > self.MAX_HISTORY_ITEMS:
                done_keys = sorted(
                    [k for k, v in self._jobs.items() if v.get("status") in ("succeeded", "failed")],
                    key=lambda k: str(self._jobs[k].get("started_at", "")),
                )
                while len(self._jobs) > self.MAX_HISTORY_ITEMS and done_keys:
                    victim = done_keys.pop(0)
                    self._jobs.pop(victim, None)
                    self._job_conds.pop(victim, None)

        def _emit(line: str) -> None:
            self._update_job(job_id, append_line=line)

        def _worker() -> None:
            self._update_job(job_id, status="running", stage="running", progress=12, summary=f"Running {title}...")
            try:
                res = runner(_emit)
                ok = bool(res.get("ok", False))
                rc = int(res.get("returncode", 0 if ok else 1))
                with self._jobs_lock:
                    cur_lines = list(self._jobs.get(job_id, {}).get("lines") or [])
                if not cur_lines and res.get("output"):
                    for ln in str(res["output"]).splitlines():
                        _emit(ln)
                    with self._jobs_lock:
                        cur_lines = list(self._jobs.get(job_id, {}).get("lines") or [])
                summary = str(res.get("summary") or _summarize_command_output(rc, cur_lines, title))
                meta = dict(res.get("meta") or {})
                if res.get("new_webpanel_url"):
                    meta["new_webpanel_url"] = res["new_webpanel_url"]
                for mk in ("updated_from", "updated_to", "updated_ref", "restart_required"):
                    if mk in res and res[mk] not in (None, ""):
                        meta[mk] = res[mk]
                self._update_job(
                    job_id,
                    status="succeeded" if ok else "failed",
                    stage="completed" if ok else "failed",
                    progress=100,
                    returncode=rc,
                    summary=summary,
                    meta_update=meta,
                    finished=True,
                )
                if ok and meta.get("restart_required"):
                    self._schedule_webpanel_restart()
            except Exception as exc:  # noqa: BLE001
                _emit(f"[ERROR] {exc}")
                self._update_job(
                    job_id,
                    status="failed",
                    stage="failed",
                    progress=100,
                    returncode=1,
                    summary=str(exc),
                    finished=True,
                )

        t = threading.Thread(target=_worker, name=f"job-{job_id}", daemon=True)
        t.start()
        return self.get_job(job_id) or job_record

    def record_sync_job(
        self,
        job_type: str,
        title: str,
        actor: str,
        result: dict[str, Any],
        started_mono: float | None = None,
    ) -> dict[str, Any]:
        """Record a synchronous operation into history so Operation History is always complete."""
        job_id = uuid.uuid4().hex[:12]
        now_iso = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        ok = bool(result.get("ok", False))
        rc = int(result.get("returncode", 0 if ok else 1))
        raw_out = str(result.get("output") or result.get("error") or "")
        lines = [auth.sanitize_log_text(strip_ansi(ln)) for ln in raw_out.splitlines()][-120:]
        summary = str(result.get("summary") or _summarize_command_output(rc, lines, title))
        duration_ms = int((time.monotonic() - started_mono) * 1000) if started_mono else 0
        rec = {
            "id": job_id,
            "type": job_type,
            "title": title,
            "actor": actor or "admin",
            "status": "succeeded" if ok else "failed",
            "stage": "completed" if ok else "failed",
            "progress": 100,
            "started_at": now_iso,
            "finished_at": now_iso,
            "duration_ms": duration_ms,
            "returncode": rc,
            "summary": auth.sanitize_log_text(summary),
            "lines": lines,
            "meta": {},
        }
        with self._jobs_lock:
            self._jobs[job_id] = rec
        self._save_history_to_disk()
        return rec

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

    def _read_db_backend(self) -> str:
        compose_path = os.path.join(self.install_dir, "compose.yaml")
        if not os.path.isfile(compose_path):
            return "none"
        try:
            with open(compose_path, "r", encoding="utf-8") as fh:
                content = fh.read()
            if "3xui_postgres" in content or "postgres" in content:
                return "postgres"
            return "sqlite"
        except OSError:
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
            rows: list[dict[str, str]] = []
            running_names: list[str] = []
            for line in (proc.stdout or "").splitlines():
                parts = line.split("\t")
                if len(parts) >= 4:
                    row = {
                        "name": parts[0],
                        "state": parts[1],
                        "status": parts[2],
                        "image": parts[3],
                        "cpu_perc": "",
                        "mem_usage": "",
                        "net_io": "",
                    }
                    rows.append(row)
                    if parts[1] == "running":
                        running_names.append(parts[0])
            if running_names:
                try:
                    st = subprocess.run(
                        [
                            "docker",
                            "stats",
                            "--no-stream",
                            "--format",
                            "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}",
                            *running_names,
                        ],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        text=True,
                        timeout=3,
                        shell=False,
                    )
                    stats_map: dict[str, tuple[str, str, str]] = {}
                    for sl in (st.stdout or "").splitlines():
                        sp = sl.split("\t")
                        if len(sp) >= 4:
                            stats_map[sp[0]] = (sp[1], sp[2], sp[3])
                    for row in rows:
                        if row["name"] in stats_map:
                            cpu_p, mem_u, net_i = stats_map[row["name"]]
                            row["cpu_perc"] = cpu_p
                            row["mem_usage"] = mem_u
                            row["net_io"] = net_i
                except Exception:
                    pass
            return rows
        except Exception:
            return []

    def _get_public_ips_cached(self) -> tuple[str, str]:
        now = time.monotonic()
        if now - float(self._pub_ip_cache.get("ts", -1000.0)) < 300:
            return str(self._pub_ip_cache.get("v4", "")), str(self._pub_ip_cache.get("v6", ""))
        v4 = ""
        if shutil.which("curl"):
            try:
                p = subprocess.run(
                    ["curl", "-4fsS", "--proto", "=https", "--tlsv1.2", "--max-time", "2", "https://api.ipify.org"],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=3,
                    shell=False,
                )
                cand = (p.stdout or "").strip()
                if p.returncode == 0 and cand:
                    ipaddress.IPv4Address(cand)
                    v4 = cand
            except Exception:
                v4 = ""
        self._pub_ip_cache = {"ts": now, "v4": v4, "v6": ""}
        return v4, ""

    def _get_host_metrics(self) -> dict[str, Any]:
        metrics: dict[str, Any] = {
            "load_avg": "unavailable",
            "load_1m": 0.0,
            "load_5m": 0.0,
            "load_15m": 0.0,
            "cpu_cores": os.cpu_count() or 1,
            "uptime": "unavailable",
            "memory": "unavailable",
            "mem_used_mb": 0,
            "mem_total_mb": 0,
            "mem_percent": 0,
            "swap_used_mb": 0,
            "swap_total_mb": 0,
            "disk_root": "unavailable",
            "disk_used_gb": 0.0,
            "disk_total_gb": 0.0,
            "disk_percent": 0,
            "tcp_cc": "unknown",
            "qdisc": "unknown",
            "os_name": "",
            "kernel": "",
            "arch": "",
            "public_ipv4": "",
        }
        try:
            with open("/proc/loadavg", "r", encoding="utf-8") as fh:
                parts = fh.read().split()
                if len(parts) >= 3:
                    metrics["load_avg"] = " ".join(parts[:3])
                    metrics["load_1m"] = float(parts[0])
                    metrics["load_5m"] = float(parts[1])
                    metrics["load_15m"] = float(parts[2])
        except Exception:
            pass
        try:
            with open("/proc/uptime", "r", encoding="utf-8") as fh:
                sec = int(float(fh.read().split()[0]))
                days, rem = divmod(sec, 86400)
                hrs, rem = divmod(rem, 3600)
                mins, _ = divmod(rem, 60)
                metrics["uptime"] = f"{days}d {hrs}h {mins}m" if days else f"{hrs}h {mins}m"
        except Exception:
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
                total_mb = max(1, meminfo["MemTotal"] // 1024)
                used_mb = max(0, (meminfo["MemTotal"] - meminfo["MemAvailable"]) // 1024)
                metrics["mem_total_mb"] = total_mb
                metrics["mem_used_mb"] = used_mb
                metrics["mem_percent"] = min(100, int((used_mb / total_mb) * 100))
                metrics["memory"] = f"{used_mb} / {total_mb} MiB"
            if "SwapTotal" in meminfo and "SwapFree" in meminfo:
                metrics["swap_total_mb"] = meminfo["SwapTotal"] // 1024
                metrics["swap_used_mb"] = max(0, (meminfo["SwapTotal"] - meminfo["SwapFree"]) // 1024)
        except Exception:
            pass
        try:
            usage = shutil.disk_usage(self.install_dir if os.path.exists(self.install_dir) else "/")
            gb = 1024**3
            pct = int((usage.used / usage.total) * 100) if usage.total else 0
            metrics["disk_used_gb"] = round(usage.used / gb, 1)
            metrics["disk_total_gb"] = round(usage.total / gb, 1)
            metrics["disk_percent"] = min(100, pct)
            metrics["disk_root"] = f"{usage.used / gb:.1f} / {usage.total / gb:.1f} GiB ({pct}%)"
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
        try:
            u = os.uname()
            metrics["kernel"] = u.release
            metrics["arch"] = u.machine
        except Exception:
            pass
        try:
            if os.path.isfile("/etc/os-release"):
                with open("/etc/os-release", "r", encoding="utf-8") as fh:
                    for line in fh:
                        if line.startswith("PRETTY_NAME="):
                            metrics["os_name"] = line.split("=", 1)[1].strip().strip('"')
                            break
        except OSError:
            pass
        return metrics

    def _inspect_x509(self, cert_path: str) -> dict[str, Any]:
        info: dict[str, Any] = {
            "subject": "",
            "issuer": "",
            "not_before": "",
            "not_after": "",
            "days_remaining": None,
            "status": "unknown",
            "sans": [],
            "fingerprint_sha256": "",
            "key_type": "",
        }
        if not os.path.isfile(cert_path) or not shutil.which("openssl"):
            return info
        try:
            proc = subprocess.run(
                [
                    "openssl",
                    "x509",
                    "-noout",
                    "-subject",
                    "-issuer",
                    "-dates",
                    "-fingerprint",
                    "-sha256",
                    "-ext",
                    "subjectAltName",
                    "-in",
                    cert_path,
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=3,
                shell=False,
            )
            if proc.returncode != 0:
                proc = subprocess.run(
                    ["openssl", "x509", "-noout", "-subject", "-issuer", "-dates", "-fingerprint", "-sha256", "-in", cert_path],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=3,
                    shell=False,
                )
            raw = proc.stdout or ""
            for line in raw.splitlines():
                s = line.strip()
                if s.startswith("subject="):
                    info["subject"] = s.split("=", 1)[1].strip()
                elif s.startswith("issuer="):
                    info["issuer"] = s.split("=", 1)[1].strip()
                elif s.startswith("notBefore="):
                    info["not_before"] = s.split("=", 1)[1].strip()
                elif s.startswith("notAfter="):
                    info["not_after"] = s.split("=", 1)[1].strip()
                elif "Fingerprint=" in s:
                    info["fingerprint_sha256"] = s.split("=", 1)[1].strip()
                elif "DNS:" in s or "IP Address:" in s or "IP:" in s:
                    for part in s.split(","):
                        tok = part.strip()
                        if tok.startswith("DNS:"):
                            info["sans"].append(tok[4:])
                        elif tok.startswith("IP Address:"):
                            info["sans"].append(tok[len("IP Address:") :])
                        elif tok.startswith("IP:"):
                            info["sans"].append(tok[3:])

            if info["not_after"]:
                exp_dt = _parse_openssl_date(info["not_after"])
                if exp_dt is not None:
                    delta = exp_dt - dt.datetime.now(dt.timezone.utc)
                    days = int(delta.total_seconds() // 86400)
                    info["days_remaining"] = days
                    if delta.total_seconds() <= 0:
                        info["status"] = "expired"
                    elif days <= 14:
                        info["status"] = "expiring_soon"
                    else:
                        info["status"] = "valid"
        except Exception:
            pass
        return info

    def _discover_certificates_detailed(self) -> list[dict[str, Any]]:
        proxy_cfg = read_kv_conf(self.proxy_conf_path)
        panel_dom = proxy_cfg.get("PROXY_DOMAIN", "")
        sub_dom = proxy_cfg.get("SUB_DOMAIN", "") if proxy_cfg.get("SUB_MODE") == "dedicated" else ""
        caddyfile_path = os.path.join(self.install_dir, "caddy", "Caddyfile")
        caddyfile_txt = ""
        if os.path.isfile(caddyfile_path):
            try:
                with open(caddyfile_path, "r", encoding="utf-8", errors="replace") as fh:
                    caddyfile_txt = fh.read()
            except OSError:
                pass

        certs: list[dict[str, Any]] = []
        cert_root = os.path.join(self.install_dir, "cert")
        if os.path.isdir(cert_root):
            for name in sorted(os.listdir(cert_root)):
                fullchain = os.path.join(cert_root, name, "fullchain.pem")
                privkey = os.path.join(cert_root, name, "privkey.pem")
                if not os.path.isfile(fullchain):
                    continue
                xinfo = self._inspect_x509(fullchain)
                le_live = os.path.isfile(f"/etc/letsencrypt/live/{name}/fullchain.pem")
                if le_live or "Let's Encrypt" in xinfo.get("issuer", ""):
                    source = "letsencrypt"
                elif xinfo.get("subject") and xinfo.get("subject") == xinfo.get("issuer"):
                    source = "self_signed"
                else:
                    source = "custom"

                in_use: list[str] = []
                if f"tls /root/cert/{name}/" in caddyfile_txt:
                    in_use.append("caddy")
                if name == panel_dom and "caddy" in in_use:
                    in_use.append("panel_domain")
                if sub_dom and name == sub_dom and "caddy" in in_use:
                    in_use.append("sub_domain")

                certs.append(
                    {
                        "id": f"local:{name}",
                        "domain": name,
                        "domains": xinfo["sans"] or [name],
                        "issuer": xinfo["issuer"] or "unknown",
                        "subject": xinfo["subject"] or name,
                        "not_before": xinfo["not_before"] or "",
                        "not_after": xinfo["not_after"] or "unknown",
                        "expires": xinfo["not_after"] or "unknown",
                        "days_remaining": xinfo["days_remaining"],
                        "status": xinfo["status"],
                        "source": source,
                        "has_privkey": os.path.isfile(privkey),
                        "fingerprint": xinfo["fingerprint_sha256"],
                        "in_use_by": in_use,
                        "revocable": True,
                        "renewable": source == "letsencrypt",
                        "applicable_to_caddy": bool(
                            proxy_cfg.get("PROXY_ENABLED") == "true" and name in (panel_dom, sub_dom)
                        ),
                        "path": fullchain,
                    }
                )

        # Also inspect Caddy ACME managed certificates under caddy/data/caddy/certificates/
        caddy_cert_base = os.path.join(self.install_dir, "caddy", "data", "caddy", "certificates")
        if os.path.isdir(caddy_cert_base):
            for issuer_dir in sorted(os.listdir(caddy_cert_base)):
                issuer_path = os.path.join(caddy_cert_base, issuer_dir)
                if not os.path.isdir(issuer_path):
                    continue
                for dom_dir in sorted(os.listdir(issuer_path)):
                    dom_path = os.path.join(issuer_path, dom_dir)
                    crt_file = os.path.join(dom_path, f"{dom_dir}.crt")
                    if not os.path.isfile(crt_file):
                        continue
                    xinfo = self._inspect_x509(crt_file)
                    in_use = ["caddy_acme"]
                    if dom_dir == panel_dom:
                        in_use.append("panel_domain")
                    if sub_dom and dom_dir == sub_dom:
                        in_use.append("sub_domain")
                    certs.append(
                        {
                            "id": f"caddy:{issuer_dir}:{dom_dir}",
                            "domain": dom_dir,
                            "domains": xinfo["sans"] or [dom_dir],
                            "issuer": xinfo["issuer"] or issuer_dir,
                            "subject": xinfo["subject"] or dom_dir,
                            "not_before": xinfo["not_before"] or "",
                            "not_after": xinfo["not_after"] or "unknown",
                            "expires": xinfo["not_after"] or "unknown",
                            "days_remaining": xinfo["days_remaining"],
                            "status": xinfo["status"],
                            "source": "caddy_acme",
                            "has_privkey": os.path.isfile(os.path.join(dom_path, f"{dom_dir}.key")),
                            "fingerprint": xinfo["fingerprint_sha256"],
                            "in_use_by": in_use,
                            "revocable": False,
                            "renewable": False,
                            "applicable_to_caddy": False,
                            "path": crt_file,
                        }
                    )
        return certs

    def _get_cert_summaries(self) -> list[dict[str, Any]]:
        detailed = self._discover_certificates_detailed()
        out: list[dict[str, Any]] = []
        for c in detailed:
            # Backward-compatible status for overview summary
            legacy_status = "ok" if c["status"] == "valid" else c["status"]
            out.append(
                {
                    "domain": c["domain"],
                    "expires": c["expires"],
                    "status": legacy_status,
                    "source": c["source"],
                    "days_remaining": c["days_remaining"],
                }
            )
        return out

    def list_certificates(self) -> dict[str, Any]:
        proxy_cfg = read_kv_conf(self.proxy_conf_path)
        certs = self._discover_certificates_detailed()
        return {
            "certs": certs,
            "certbot_installed": bool(shutil.which("certbot")),
            "openssl_installed": bool(shutil.which("openssl")),
            "proxy_enabled": proxy_cfg.get("PROXY_ENABLED", "false") == "true",
            "panel_domain": proxy_cfg.get("PROXY_DOMAIN", ""),
            "sub_domain": proxy_cfg.get("SUB_DOMAIN", "") if proxy_cfg.get("SUB_MODE") == "dedicated" else "",
        }

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
        wp_path = normalize_webpath(wp_cfg.get("WEBPANEL_PATH", "/deploy/"))

        sub_mode = proxy_cfg.get("SUB_MODE", "none")
        sub_url = ""
        if domain and sub_mode == "dedicated" and proxy_cfg.get("SUB_DOMAIN"):
            sub_url = f"https://{proxy_cfg['SUB_DOMAIN']}{port_sfx}{proxy_cfg.get('SUB_PATH', '/sub/')}"
        elif domain and sub_mode == "same":
            sub_url = f"https://{domain}{port_sfx}{proxy_cfg.get('SUB_PATH', '/sub/')}"

        containers = self._get_docker_containers()
        metrics = self._get_host_metrics()
        certs_detailed = self._discover_certificates_detailed()
        certs = [
            {
                "domain": c["domain"],
                "expires": c["expires"],
                "status": "ok" if c["status"] == "valid" else c["status"],
                "source": c["source"],
                "days_remaining": c["days_remaining"],
            }
            for c in certs_detailed
        ]

        running_cnt = sum(1 for c in containers if c.get("state") == "running")
        caddy_running = any(c.get("name") == "3xui_caddy" and c.get("state") == "running" for c in containers)
        app_running = any(c.get("name") == "3xui_app" and c.get("state") == "running" for c in containers)
        expiring_cnt = sum(1 for c in certs_detailed if c.get("status") == "expiring_soon")
        expired_cnt = sum(1 for c in certs_detailed if c.get("status") == "expired")

        with self._jobs_lock:
            active_jobs = sum(1 for j in self._jobs.values() if j.get("status") in ("queued", "running"))

        deployed = os.path.isfile(os.path.join(self.install_dir, "compose.yaml"))
        if not deployed:
            health_status = "not_deployed"
        elif expired_cnt > 0 or (containers and running_cnt == 0) or not app_running:
            health_status = "degraded"
        elif expiring_cnt > 0 or (proxy_cfg.get("PROXY_ENABLED") == "true" and not caddy_running):
            health_status = "attention"
        else:
            health_status = "healthy"

        script_ver = read_script_version(self.manage_script)
        return {
            "install_dir": self.install_dir,
            "deployed": deployed,
            "xui_tag": self._read_compose_tag(),
            "version": {
                "deploy": script_ver or WEBPANEL_VERSION,
                "webpanel": WEBPANEL_VERSION,
                "in_sync": (not script_ver) or (script_ver == WEBPANEL_VERSION),
            },
            "containers": containers,
            "metrics": metrics,
            "summary": {
                "health_status": health_status,
                "running_containers": running_cnt,
                "total_containers": len(containers),
                "certs_total": len(certs_detailed),
                "certs_expiring": expiring_cnt,
                "certs_expired": expired_cnt,
                "db_backend": self._read_db_backend(),
                "active_jobs": active_jobs,
                "backup_count": len(self.list_backups()),
                "backup_cron_enabled": os.path.isfile("/etc/cron.d/3xui-backup"),
                "app_running": app_running,
                "caddy_running": caddy_running,
            },
            "proxy": {
                "enabled": proxy_cfg.get("PROXY_ENABLED", "false") == "true",
                "domain": domain,
                "port": port,
                "sub_mode": sub_mode,
                "sub_domain": proxy_cfg.get("SUB_DOMAIN", ""),
                "sub_url": sub_url,
                "decoy_url": f"https://{domain}{port_sfx}/" if domain else "",
                "webpanel_url": f"https://{domain}{port_sfx}{wp_path}" if domain else "",
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
            "certs": certs,
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

    def get_health_diagnostics(self) -> dict[str, Any]:
        rc, out = self._run_manage(["health"], timeout=30)
        return {"ok": rc == 0, "returncode": rc, "output": out}

    def get_xray_status(self) -> dict[str, Any]:
        rc, out = self._run_manage(["xray-status"], timeout=25)
        return {"ok": rc == 0, "returncode": rc, "output": out}

    def run_compat_test(
        self, tag: str, *, async_mode: bool = False, actor: str = "admin"
    ) -> dict[str, Any]:
        if not tag or not TAG_RE.fullmatch(tag):
            return {"ok": False, "returncode": 2, "output": "Invalid 3x-ui tag format."}

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(["compat", "test", tag], on_line=emit, timeout=120)
                else:
                    rc, out = self._run_manage(["compat", "test", tag], timeout=120)
            return {"ok": rc == 0, "returncode": rc, "tag": tag, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("compat_test", f"Pre-flight check {tag}", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("compat_test", f"Pre-flight check {tag}", actor, res, t0)
        return res

    def run_lifecycle(
        self, action: str, *, async_mode: bool = False, actor: str = "admin"
    ) -> dict[str, Any]:
        args = LIFECYCLE_ACTIONS.get(action)
        if not args:
            return {"ok": False, "returncode": 2, "output": f"Unsupported action: {action}"}

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(args, on_line=emit, timeout=120)
                else:
                    rc, out = self._run_manage(args, timeout=120)
            return {"ok": rc == 0, "returncode": rc, "action": action, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job(f"lifecycle_{action}", f"Stack action: {action}", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job(f"lifecycle_{action}", f"Stack action: {action}", actor, res, t0)
        return res

    def run_deploy(
        self,
        db_type: str = "sqlite",
        pg_user: str = "xui",
        *,
        async_mode: bool = False,
        actor: str = "admin",
    ) -> dict[str, Any]:
        db_clean = (db_type or "sqlite").strip().lower()
        if db_clean not in ("sqlite", "postgres"):
            return {"ok": False, "returncode": 2, "error": "Database backend must be 'sqlite' or 'postgres'."}
        user_clean = (pg_user or "xui").strip()
        if db_clean == "postgres" and not PG_IDENT_RE.fullmatch(user_clean):
            return {"ok": False, "returncode": 2, "error": "Invalid PostgreSQL username format."}

        args = ["deploy", db_clean]
        if db_clean == "postgres":
            args.append(user_clean)

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(args, on_line=emit, timeout=300)
                else:
                    rc, out = self._run_manage(args, timeout=300)
            return {"ok": rc == 0, "returncode": rc, "output": auth.sanitize_log_text(out)}

        if async_mode:
            return {"accepted": True, "job": self.start_job("deploy", f"Deploy 3X-UI ({db_clean})", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("deploy", f"Deploy 3X-UI ({db_clean})", actor, res, t0)
        return res

    def run_update(
        self,
        tag: str | None = None,
        force_compat: bool = False,
        *,
        async_mode: bool = False,
        actor: str = "admin",
    ) -> dict[str, Any]:
        args: list[str] = []
        if force_compat:
            args.append("--force-compat")
        args.append("update")
        clean_tag = (tag or "").strip()
        if clean_tag:
            if not TAG_RE.fullmatch(clean_tag):
                return {"ok": False, "returncode": 2, "output": "Invalid target version tag."}
            args.append(clean_tag)

        label = clean_tag or "latest"

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(args, on_line=emit, timeout=240)
                else:
                    rc, out = self._run_manage(args, timeout=240)
            return {"ok": rc == 0, "returncode": rc, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("xui_update", f"Update 3X-UI ({label})", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("xui_update", f"Update 3X-UI ({label})", actor, res, t0)
        return res

    def run_rollback(self, *, async_mode: bool = False, actor: str = "admin") -> dict[str, Any]:
        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(["rollback"], on_line=emit, timeout=180)
                else:
                    rc, out = self._run_manage(["rollback"], timeout=180)
            return {"ok": rc == 0, "returncode": rc, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("xui_rollback", "Rollback 3X-UI version", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("xui_rollback", "Rollback 3X-UI version", actor, res, t0)
        return res

    def get_version_info(self, check_remote: bool = False) -> dict[str, Any]:
        script_ver = read_script_version(self.manage_script)
        current_ver = script_ver or WEBPANEL_VERSION
        res: dict[str, Any] = {
            "ok": True,
            "current_version": current_ver,
            "webpanel_version": WEBPANEL_VERSION,
            "in_sync": (not script_ver) or (script_ver == WEBPANEL_VERSION),
        }
        if not check_remote:
            return res

        rc, out = self._run_manage(["self-update", "--check"], timeout=25)
        kv = parse_kv_lines(out)
        if kv.get("DEPLOY_CURRENT_VERSION"):
            res["current_version"] = kv["DEPLOY_CURRENT_VERSION"]
        avail_raw = kv.get("DEPLOY_UPDATE_AVAILABLE", "unknown").lower()
        avail: bool | None = True if avail_raw == "true" else (False if avail_raw == "false" else None)
        res.update(
            {
                "ok": rc == 0,
                "returncode": rc,
                "latest_version": kv.get("DEPLOY_LATEST_VERSION", "unknown"),
                "latest_ref": kv.get("DEPLOY_LATEST_REF", "main"),
                "channel": kv.get("DEPLOY_CHANNEL", "main"),
                "update_available": avail,
                "release_url": kv.get("DEPLOY_RELEASE_URL", ""),
                "output": out,
            }
        )
        return res

    def _schedule_webpanel_restart(self, delay: float = 1.8) -> None:
        if os.environ.get("XUI_TESTING") == "1" or not shutil.which("systemctl"):
            return

        def _do_restart() -> None:
            try:
                chk = subprocess.run(
                    ["systemctl", "is-active", "--quiet", "3xui-deploy-web"],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=3,
                    shell=False,
                )
                if chk.returncode == 0:
                    subprocess.run(
                        ["systemctl", "restart", "3xui-deploy-web"],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=15,
                        shell=False,
                    )
            except Exception:  # noqa: BLE001
                pass

        timer = threading.Timer(delay, _do_restart)
        timer.daemon = True
        timer.start()

    def run_self_update(
        self,
        target: str = "",
        force: bool = False,
        *,
        async_mode: bool = False,
        actor: str = "admin",
    ) -> dict[str, Any]:
        clean_target = (target or "").strip()
        if clean_target and not DEPLOY_REF_RE.fullmatch(clean_target):
            return {
                "ok": False,
                "returncode": 2,
                "error": "Invalid target version/ref (use vX.Y.Z or main).",
            }

        args = ["self-update"]
        if force:
            args.append("--force")
        if clean_target:
            args.append(clean_target)
        label = clean_target or "latest release"

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(args, on_line=emit, timeout=180)
                else:
                    rc, out = self._run_manage(args, timeout=180)
            kv = parse_kv_lines(out)
            res: dict[str, Any] = {
                "ok": rc == 0,
                "returncode": rc,
                "output": out,
            }
            if kv.get("UPDATED_FROM"):
                res["updated_from"] = kv["UPDATED_FROM"]
            if kv.get("UPDATED_TO"):
                res["updated_to"] = kv["UPDATED_TO"]
            if kv.get("UPDATED_REF"):
                res["updated_ref"] = kv["UPDATED_REF"]
            if kv.get("WEBPANEL_RESTART_REQUIRED", "").lower() == "true":
                res["restart_required"] = True
            return res

        if async_mode:
            return {"accepted": True, "job": self.start_job("self_update", f"Update 3xui-deploy ({label})", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("self_update", f"Update 3xui-deploy ({label})", actor, res, t0)
        if res.get("ok") and res.get("restart_required"):
            self._schedule_webpanel_restart()
        return res

    def issue_certificate(
        self,
        domain: str,
        email: str = "",
        apply_mode: str = "none",
        *,
        async_mode: bool = False,
        actor: str = "admin",
    ) -> dict[str, Any]:
        clean_dom = (domain or "").strip().lower()
        clean_email = (email or "").strip()
        clean_mode = (apply_mode or "none").strip().lower()
        if not validate_domain_name(clean_dom):
            return {"ok": False, "returncode": 2, "error": "Invalid certificate domain name."}
        if clean_email and not probe.EMAIL_RE.fullmatch(clean_email):
            return {"ok": False, "returncode": 2, "error": "Invalid email address."}
        if clean_mode not in CERT_APPLY_MODES:
            return {"ok": False, "returncode": 2, "error": "Invalid apply_mode (use none, caddy, or panel)."}

        args = ["certs", "issue", clean_dom, clean_email or "-", clean_mode]

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(args, on_line=emit, timeout=240)
                else:
                    rc, out = self._run_manage(args, timeout=240)
            return {"ok": rc == 0, "returncode": rc, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("cert_issue", f"Issue SSL cert ({clean_dom})", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("cert_issue", f"Issue SSL cert ({clean_dom})", actor, res, t0)
        return res

    def generate_self_signed_cert(
        self,
        host: str,
        days: int = 3650,
        apply_mode: str = "none",
        *,
        async_mode: bool = False,
        actor: str = "admin",
    ) -> dict[str, Any]:
        clean_host = (host or "").strip()
        clean_mode = (apply_mode or "none").strip().lower()
        if not validate_domain_or_ip(clean_host):
            return {"ok": False, "returncode": 2, "error": "Invalid domain or IP address."}
        try:
            d_int = int(days)
        except (TypeError, ValueError):
            return {"ok": False, "returncode": 2, "error": "Days must be an integer."}
        if d_int < 1 or d_int > 3650:
            return {"ok": False, "returncode": 2, "error": "Certificate validity must be between 1 and 3650 days."}
        if clean_mode not in CERT_APPLY_MODES:
            return {"ok": False, "returncode": 2, "error": "Invalid apply_mode (use none, caddy, or panel)."}

        args = ["certs", "self-signed", clean_host, str(d_int), clean_mode]

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(args, on_line=emit, timeout=60)
                else:
                    rc, out = self._run_manage(args, timeout=60)
            return {"ok": rc == 0, "returncode": rc, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("cert_self_signed", f"Self-signed cert ({clean_host})", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("cert_self_signed", f"Self-signed cert ({clean_host})", actor, res, t0)
        return res

    def renew_certificates(
        self,
        domain: str = "",
        force: bool = False,
        *,
        async_mode: bool = False,
        actor: str = "admin",
    ) -> dict[str, Any]:
        clean_dom = (domain or "").strip().lower()
        if clean_dom and clean_dom != "all" and not validate_domain_name(clean_dom):
            return {"ok": False, "returncode": 2, "error": "Invalid certificate domain."}

        args = ["certs", "renew", clean_dom or "all", "force" if force else "false"]
        label = clean_dom or "all"

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(args, on_line=emit, timeout=240)
                else:
                    rc, out = self._run_manage(args, timeout=240)
            return {"ok": rc == 0, "returncode": rc, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("cert_renew", f"Renew SSL cert ({label})", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("cert_renew", f"Renew SSL cert ({label})", actor, res, t0)
        return res

    def revoke_certificate(
        self,
        domain: str,
        reason: str = "unspecified",
        *,
        async_mode: bool = False,
        actor: str = "admin",
    ) -> dict[str, Any]:
        clean_dom = (domain or "").strip()
        clean_reason = (reason or "unspecified").strip().lower()
        if not validate_domain_or_ip(clean_dom):
            return {"ok": False, "returncode": 2, "error": "Invalid certificate domain or IP."}
        if clean_reason not in REVOCATION_REASONS:
            return {"ok": False, "returncode": 2, "error": "Invalid revocation reason."}

        args = ["certs", "revoke", clean_dom, clean_reason]

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(args, on_line=emit, timeout=180)
                else:
                    rc, out = self._run_manage(args, timeout=180)
            return {"ok": rc == 0, "returncode": rc, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("cert_revoke", f"Revoke cert ({clean_dom})", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("cert_revoke", f"Revoke cert ({clean_dom})", actor, res, t0)
        return res

    def apply_certificate(
        self,
        domain: str,
        target: str = "caddy",
        *,
        async_mode: bool = False,
        actor: str = "admin",
    ) -> dict[str, Any]:
        clean_dom = (domain or "").strip()
        clean_target = (target or "caddy").strip().lower()
        if not validate_domain_or_ip(clean_dom):
            return {"ok": False, "returncode": 2, "error": "Invalid certificate domain or IP."}
        if clean_target not in CERT_APPLY_TARGETS:
            return {"ok": False, "returncode": 2, "error": "Target must be 'caddy' or 'panel'."}

        args = ["certs", "apply", clean_dom, clean_target]

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(args, on_line=emit, timeout=90)
                else:
                    rc, out = self._run_manage(args, timeout=90)
            return {"ok": rc == 0, "returncode": rc, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("cert_apply", f"Apply cert {clean_dom} ({clean_target})", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("cert_apply", f"Apply cert {clean_dom} ({clean_target})", actor, res, t0)
        return res

    def get_network_config(self) -> dict[str, Any]:
        proxy_cfg = read_kv_conf(self.proxy_conf_path)
        wp_cfg = read_kv_conf(self.webpanel_conf_path)
        settings_kv: dict[str, str] = {}
        if os.path.isfile(self.manage_script):
            rc, out = self._run_manage(["settings", "show"], timeout=20)
            if rc == 0:
                settings_kv = parse_kv_lines(out)

        nameservers: list[str] = []
        if os.path.isfile("/etc/resolv.conf"):
            try:
                with open("/etc/resolv.conf", "r", encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        s = line.strip()
                        if s.startswith("nameserver "):
                            parts = s.split()
                            if len(parts) >= 2:
                                nameservers.append(parts[1])
            except OSError:
                pass

        interfaces: list[str] = []
        if shutil.which("ip"):
            try:
                proc = subprocess.run(
                    ["ip", "-o", "addr", "show"],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=3,
                    shell=False,
                )
                for line in (proc.stdout or "").splitlines():
                    parts = line.split()
                    if len(parts) >= 4:
                        interfaces.append(f"{parts[1]} {parts[2]} {parts[3]}")
            except Exception:
                pass

        metrics = self._get_host_metrics()
        pub4, _ = self._get_public_ips_cached()
        metrics["public_ipv4"] = pub4

        return {
            "proxy": {
                "enabled": settings_kv.get("PROXY_ENABLED", proxy_cfg.get("PROXY_ENABLED", "false")) == "true",
                "domain": settings_kv.get("PROXY_DOMAIN", proxy_cfg.get("PROXY_DOMAIN", "")),
                "port": settings_kv.get("PROXY_PORT", proxy_cfg.get("PROXY_PORT", "443")),
                "email": settings_kv.get("PROXY_EMAIL", proxy_cfg.get("PROXY_EMAIL", "")),
                "sub_mode": settings_kv.get("SUB_MODE", proxy_cfg.get("SUB_MODE", "none")),
                "sub_domain": settings_kv.get("SUB_DOMAIN", proxy_cfg.get("SUB_DOMAIN", "")),
                "sub_port": settings_kv.get("SUB_PORT", proxy_cfg.get("SUB_PORT", "2096")),
                "sub_path": settings_kv.get("SUB_PATH", proxy_cfg.get("SUB_PATH", "/sub/")),
                "sub_json_path": settings_kv.get("SUB_JSON_PATH", proxy_cfg.get("SUB_JSON_PATH", "/json/")),
            },
            "panel": {
                "port": settings_kv.get("PANEL_PORT", "2053"),
                "path": settings_kv.get("PANEL_PATH", "/"),
                "user": settings_kv.get("PANEL_USER", "admin"),
                "listen_ip": settings_kv.get("PANEL_LISTEN", ""),
                "web_domain": settings_kv.get("PANEL_DOMAIN", ""),
                "proto": settings_kv.get("PANEL_PROTO", "http"),
                "two_factor": settings_kv.get("PANEL_2FA", "false") == "true",
                "session_max_age": settings_kv.get("PANEL_SESSION_AGE", "60"),
                "has_default_creds": settings_kv.get("PANEL_HAS_DEFAULT", "") == "true",
            },
            "subscription": {
                "enable": settings_kv.get("SUB_ENABLE_DB", "false") == "true",
                "listen_ip": settings_kv.get("SUB_LISTEN_DB", ""),
                "domain": settings_kv.get("SUB_DOMAIN_DB", ""),
                "port": settings_kv.get("SUB_PORT_DB", "2096"),
                "path": settings_kv.get("SUB_PATH_DB", "/sub/"),
                "json_enable": settings_kv.get("SUB_JSON_ENABLE_DB", "false") == "true",
                "json_path": settings_kv.get("SUB_JSON_PATH_DB", "/json/"),
                "encrypt": settings_kv.get("SUB_ENCRYPT_DB", "true") == "true",
                "uri": settings_kv.get("SUB_URI_DB", ""),
                "json_uri": settings_kv.get("SUB_JSON_URI_DB", ""),
            },
            "webpanel": {
                "path": wp_cfg.get("WEBPANEL_PATH", "/deploy/"),
                "port": wp_cfg.get("WEBPANEL_PORT", "2059"),
                "domain": wp_cfg.get("WEBPANEL_DOMAIN", proxy_cfg.get("PROXY_DOMAIN", "")),
                "idle_minutes": wp_cfg.get("WEBPANEL_SESSION_IDLE", "30"),
            },
            "network": {
                "nameservers": nameservers,
                "interfaces": interfaces,
                "tcp_cc": metrics["tcp_cc"],
                "qdisc": metrics["qdisc"],
                "public_ipv4": pub4,
            },
        }

    def update_proxy_config(
        self, payload: dict[str, Any], *, async_mode: bool = False, actor: str = "admin"
    ) -> dict[str, Any]:
        domain = str(payload.get("domain", "")).strip().lower()
        ok_p, port = validate_port_value(payload.get("port", 443))
        email = str(payload.get("email", "")).strip()
        sub_mode = str(payload.get("sub_mode", "none")).strip().lower()
        sub_domain = str(payload.get("sub_domain", "")).strip().lower()
        ok_sp, sub_port = validate_port_value(payload.get("sub_port", 2096))
        sub_path = normalize_webpath(str(payload.get("sub_path", "/sub/")))
        sub_json_path = normalize_webpath(str(payload.get("sub_json_path", "/json/")))
        use_panel_cert = bool(payload.get("use_panel_cert", False))
        use_sub_cert = bool(payload.get("use_sub_cert", False))

        if not validate_domain_name(domain):
            return {"ok": False, "returncode": 2, "error": "Invalid panel domain name."}
        if not ok_p:
            return {"ok": False, "returncode": 2, "error": "Invalid HTTPS port (1-65535)."}
        if email and not probe.EMAIL_RE.fullmatch(email):
            return {"ok": False, "returncode": 2, "error": "Invalid ACME email address."}
        if sub_mode not in ("none", "same", "dedicated"):
            return {"ok": False, "returncode": 2, "error": "Subscription mode must be none, same, or dedicated."}
        if sub_mode != "none":
            if not ok_sp:
                return {"ok": False, "returncode": 2, "error": "Invalid internal subscription port."}
            if sub_path == "/" or not validate_webpath_value(sub_path):
                return {"ok": False, "returncode": 2, "error": "Invalid subscription path."}
            if sub_json_path == "/" or not validate_webpath_value(sub_json_path) or probe.paths_overlap(sub_path, sub_json_path):
                return {"ok": False, "returncode": 2, "error": "Invalid or overlapping JSON subscription path."}
            if sub_mode == "dedicated" and (not validate_domain_name(sub_domain) or sub_domain == domain):
                return {"ok": False, "returncode": 2, "error": "Dedicated subscription domain must be a valid domain different from panel domain."}

        args = [
            "proxy",
            "configure",
            f"domain={domain}",
            f"port={port}",
            f"email={email}",
            f"sub_mode={sub_mode}",
            f"sub_domain={sub_domain if sub_mode == 'dedicated' else ''}",
            f"sub_port={sub_port}",
            f"sub_path={sub_path}",
            f"sub_json_path={sub_json_path}",
            f"use_panel_cert={'true' if use_panel_cert else 'false'}",
            f"use_sub_cert={'true' if use_sub_cert else 'false'}",
        ]

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(args, on_line=emit, timeout=180)
                else:
                    rc, out = self._run_manage(args, timeout=180)
            kv = parse_kv_lines(out)
            res: dict[str, Any] = {"ok": rc == 0, "returncode": rc, "output": out}
            if kv.get("WEBPANEL_NEW_URL"):
                res["new_webpanel_url"] = kv["WEBPANEL_NEW_URL"]
            return res

        if async_mode:
            return {"accepted": True, "job": self.start_job("proxy_configure", f"Configure reverse proxy ({domain})", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("proxy_configure", f"Configure reverse proxy ({domain})", actor, res, t0)
        return res

    def disable_proxy(self, *, async_mode: bool = False, actor: str = "admin") -> dict[str, Any]:
        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(["proxy", "disable"], on_line=emit, timeout=150)
                else:
                    rc, out = self._run_manage(["proxy", "disable"], timeout=150)
            return {"ok": rc == 0, "returncode": rc, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("proxy_disable", "Disable Caddy reverse proxy", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("proxy_disable", "Disable Caddy reverse proxy", actor, res, t0)
        return res

    def update_panel_settings(
        self, payload: dict[str, Any], *, async_mode: bool = False, actor: str = "admin"
    ) -> dict[str, Any]:
        commands: list[list[str]] = []

        if payload.get("port") is not None and str(payload.get("port")).strip() != "":
            ok_p, p_int = validate_port_value(payload.get("port"))
            if not ok_p:
                return {"ok": False, "returncode": 2, "error": "Invalid panel port (1-65535)."}
            commands.append(["settings", "set-port", str(p_int)])

        if "listen_ip" in payload and payload.get("listen_ip") is not None:
            lip = str(payload.get("listen_ip")).strip()
            if not validate_listen_ip_value(lip):
                return {"ok": False, "returncode": 2, "error": "Invalid listen IP address."}
            commands.append(["settings", "set-listen", lip or "all"])

        if payload.get("randomize_path"):
            commands.append(["settings", "set-webpath", "random"])
        elif payload.get("web_path") is not None and str(payload.get("web_path")).strip() != "":
            wp = normalize_webpath(str(payload.get("web_path")))
            if not validate_webpath_value(wp):
                return {"ok": False, "returncode": 2, "error": "Invalid Web Base Path."}
            commands.append(["settings", "set-webpath", wp])

        age_arg = "keep"
        dom_arg = "keep"
        if payload.get("session_max_age") is not None and str(payload.get("session_max_age")).strip() != "":
            try:
                age_val = int(str(payload.get("session_max_age")).strip())
            except (TypeError, ValueError):
                return {"ok": False, "returncode": 2, "error": "Session timeout must be an integer."}
            if age_val < 5 or age_val > 10080:
                return {"ok": False, "returncode": 2, "error": "Session timeout must be between 5 and 10080 minutes."}
            age_arg = str(age_val)

        if "web_domain" in payload and payload.get("web_domain") is not None:
            wd = str(payload.get("web_domain")).strip()
            if wd in ("", "none", "-"):
                dom_arg = "none"
            elif validate_domain_name(wd):
                dom_arg = wd
            else:
                return {"ok": False, "returncode": 2, "error": "Invalid panel webDomain."}

        if age_arg != "keep" or dom_arg != "keep":
            commands.append(["settings", "set-security", age_arg, dom_arg])

        if not commands:
            return {"ok": False, "returncode": 2, "error": "No panel settings specified."}

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            outputs: list[str] = []
            final_rc = 0
            with self._op_lock:
                for cmd_args in commands:
                    if emit:
                        rc, out = self._run_manage_streaming(cmd_args, on_line=emit, timeout=120)
                    else:
                        rc, out = self._run_manage(cmd_args, timeout=120)
                    outputs.append(out)
                    if rc != 0:
                        final_rc = rc
                        break
            return {"ok": final_rc == 0, "returncode": final_rc, "output": "\n".join(outputs)}

        if async_mode:
            return {"accepted": True, "job": self.start_job("panel_settings", "Update 3X-UI panel settings", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("panel_settings", "Update 3X-UI panel settings", actor, res, t0)
        return res

    def update_subscription_settings(
        self, payload: dict[str, Any], *, async_mode: bool = False, actor: str = "admin"
    ) -> dict[str, Any]:
        enable = bool(payload.get("enable", True))
        if not enable:
            args = ["settings", "set-sub", "enable=false"]
        else:
            mode = str(payload.get("mode", "dedicated")).strip().lower()
            if mode not in ("dedicated", "same", "direct"):
                mode = "dedicated"
            dom = str(payload.get("domain", "")).strip().lower()
            listen_ip = str(payload.get("listen_ip", "")).strip()
            ok_p, port = validate_port_value(payload.get("port", 2096))
            path = normalize_webpath(str(payload.get("path", "/sub/")))
            json_en = bool(payload.get("json_enable", True))
            json_path = normalize_webpath(str(payload.get("json_path", "/json/")))
            encrypt = bool(payload.get("encrypt", True))

            if dom and dom not in ("none", "-") and not validate_domain_name(dom):
                return {"ok": False, "returncode": 2, "error": "Invalid subscription domain."}
            if not validate_listen_ip_value(listen_ip):
                return {"ok": False, "returncode": 2, "error": "Invalid subscription listen IP."}
            if not ok_p:
                return {"ok": False, "returncode": 2, "error": "Invalid subscription port."}
            if path == "/" or not validate_webpath_value(path):
                return {"ok": False, "returncode": 2, "error": "Invalid subscription path."}
            if json_path == "/" or not validate_webpath_value(json_path) or probe.paths_overlap(path, json_path):
                return {"ok": False, "returncode": 2, "error": "Invalid or overlapping JSON subscription path."}

            args = [
                "settings",
                "set-sub",
                "enable=true",
                f"mode={mode}",
                f"domain={dom or 'none'}",
                f"listen={listen_ip or 'all'}",
                f"port={port}",
                f"path={path}",
                f"json_enable={'true' if json_en else 'false'}",
                f"json_path={json_path}",
                f"encrypt={'true' if encrypt else 'false'}",
            ]

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(args, on_line=emit, timeout=150)
                else:
                    rc, out = self._run_manage(args, timeout=150)
            return {"ok": rc == 0, "returncode": rc, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("sub_settings", "Update subscription configuration", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("sub_settings", "Update subscription configuration", actor, res, t0)
        return res

    def reset_panel_2fa(self, *, async_mode: bool = False, actor: str = "admin") -> dict[str, Any]:
        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(["settings", "reset-2fa"], on_line=emit, timeout=90)
                else:
                    rc, out = self._run_manage(["settings", "reset-2fa"], timeout=90)
            return {"ok": rc == 0, "returncode": rc, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("reset_2fa", "Reset 3X-UI panel 2FA", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("reset_2fa", "Reset 3X-UI panel 2FA", actor, res, t0)
        return res

    def reset_panel_credentials(
        self, username: str, password: str, *, async_mode: bool = False, actor: str = "admin"
    ) -> dict[str, Any]:
        clean_user = (username or "").strip()
        ok_u, err_u = auth.validate_username(clean_user)
        if not ok_u:
            return {"ok": False, "returncode": 2, "error": err_u}
        ok_p, err_p = auth.validate_strong_password(password)
        if not ok_p:
            return {"ok": False, "returncode": 2, "error": err_p}

        stdin_payload = f"{clean_user}\n{password}\n"

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(
                        ["settings", "reset-credentials"],
                        on_line=emit,
                        timeout=90,
                        stdin_text=stdin_payload,
                    )
                else:
                    rc, out = self._run_manage(
                        ["settings", "reset-credentials"],
                        timeout=90,
                        stdin_text=stdin_payload,
                    )
            return {"ok": rc == 0, "returncode": rc, "output": auth.sanitize_log_text(out)}

        if async_mode:
            return {"accepted": True, "job": self.start_job("reset_panel_creds", f"Update 3X-UI panel credentials ({clean_user})", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("reset_panel_creds", f"Update 3X-UI panel credentials ({clean_user})", actor, res, t0)
        return res

    def check_domain_dns(self, domain: str) -> dict[str, Any]:
        clean_dom = (domain or "").strip().lower()
        if not validate_domain_name(clean_dom):
            return {"ok": False, "returncode": 2, "error": "Invalid domain name."}
        rc, out = self._run_manage(["dns", "check", clean_dom], timeout=25)
        kv = parse_kv_lines(out)
        records = [r for r in kv.get("DNS_RECORDS", "").split(",") if r]
        return {
            "ok": rc == 0,
            "returncode": rc,
            "domain": clean_dom,
            "records": records,
            "server_ipv4": kv.get("SERVER_IPV4", ""),
            "server_ipv6": kv.get("SERVER_IPV6", ""),
            "matched": kv.get("DNS_MATCH", "false") == "true",
            "output": out,
        }

    def apply_bbr_tuning(self, *, async_mode: bool = False, actor: str = "admin") -> dict[str, Any]:
        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(["bbr"], on_line=emit, timeout=60)
                else:
                    rc, out = self._run_manage(["bbr"], timeout=60)
            return {"ok": rc == 0, "returncode": rc, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("bbr_tuning", "Apply TCP BBR & sysctl tuning", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("bbr_tuning", "Apply TCP BBR & sysctl tuning", actor, res, t0)
        return res

    def get_firewall_status(self) -> dict[str, Any]:
        rc, out = self._run_manage(["firewall", "status"], timeout=20)
        kv = parse_kv_lines(out)
        return {
            "ok": rc == 0,
            "returncode": rc,
            "backend": kv.get("FIREWALL_BACKEND", "none"),
            "output": out,
        }

    def run_firewall_action(
        self,
        action: str,
        port: Any = None,
        proto: str = "tcp",
        *,
        async_mode: bool = False,
        actor: str = "admin",
    ) -> dict[str, Any]:
        clean_act = (action or "").strip().lower()
        clean_proto = (proto or "tcp").strip().lower()
        if clean_act not in ("sync", "open", "close"):
            return {"ok": False, "returncode": 2, "error": "Firewall action must be sync, open, or close."}
        args = ["firewall", clean_act]
        title = "Sync inbound firewall rules"
        if clean_act in ("open", "close"):
            ok_p, p_int = validate_port_value(port)
            if not ok_p:
                return {"ok": False, "returncode": 2, "error": "Valid port (1-65535) required."}
            if clean_proto not in FIREWALL_PROTOS:
                return {"ok": False, "returncode": 2, "error": "Protocol must be tcp, udp, or both."}
            args.extend([str(p_int), clean_proto])
            title = f"Firewall {clean_act} {p_int}/{clean_proto}"

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(args, on_line=emit, timeout=60)
                else:
                    rc, out = self._run_manage(args, timeout=60)
            return {"ok": rc == 0, "returncode": rc, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job(f"firewall_{clean_act}", title, actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job(f"firewall_{clean_act}", title, actor, res, t0)
        return res

    def get_inbounds(self) -> dict[str, Any]:
        rc, out = self._run_manage(["inbounds", "list"], timeout=30)
        parsed_rows: list[dict[str, str]] = []
        for line in out.splitlines():
            s = line.strip()
            # Table row: starts with integer ID
            m = re.match(
                r"^(\d+)\s+(ON|OFF)\s+(\S+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(tcp|udp|both)\s+(\S+)\s+(\S+)\s*(.*)$",
                s,
            )
            if m:
                parsed_rows.append(
                    {
                        "id": m.group(1),
                        "enabled": m.group(2) == "ON",
                        "protocol": m.group(3),
                        "listen": m.group(4),
                        "port": m.group(5),
                        "net_sec": m.group(6),
                        "fw_proto": m.group(7),
                        "live": m.group(8),
                        "route": m.group(9),
                        "remark": m.group(10).strip(),
                    }
                )
        return {"ok": rc == 0, "returncode": rc, "rows": parsed_rows, "output": out}

    def run_security_audit(self, *, async_mode: bool = False, actor: str = "admin") -> dict[str, Any]:
        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            if emit:
                rc, out = self._run_manage_streaming(["audit"], on_line=emit, timeout=45)
            else:
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

        if async_mode:
            return {"accepted": True, "job": self.start_job("security_audit", "Security & compliance audit", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("security_audit", "Security & compliance audit", actor, res, t0)
        return res

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
                    "modified_at": dt.datetime.fromtimestamp(st.st_mtime, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "_mtime": st.st_mtime,
                }
            )
        entries.sort(key=lambda item: item["_mtime"], reverse=True)
        for e in entries:
            e.pop("_mtime", None)
        return entries

    def create_backup(self, *, async_mode: bool = False, actor: str = "admin") -> dict[str, Any]:
        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(["backup"], on_line=emit, timeout=180)
                else:
                    rc, out = self._run_manage(["backup"], timeout=180)
            return {"ok": rc == 0, "returncode": rc, "output": out, "backups": self.list_backups()}

        if async_mode:
            return {"accepted": True, "job": self.start_job("backup_create", "Create backup archive", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("backup_create", "Create backup archive", actor, res, t0)
        return res

    def restore_backup(
        self, name: str, *, async_mode: bool = False, actor: str = "admin"
    ) -> dict[str, Any]:
        clean = (name or "").strip()
        if not clean or "/" in clean or "\\" in clean or ".." in clean or not SAFE_BACKUP_NAME_RE.fullmatch(clean):
            return {"ok": False, "returncode": 2, "error": "Invalid backup archive filename."}
        base_real = os.path.realpath(self.backup_dir)
        candidate = os.path.join(self.backup_dir, clean)
        if os.path.islink(candidate):
            return {"ok": False, "returncode": 2, "error": "Refusing symlink backup file."}
        real_target = os.path.realpath(candidate)
        if os.path.dirname(real_target) != base_real or not os.path.isfile(real_target):
            return {"ok": False, "returncode": 4, "error": "Backup archive not found."}

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(["restore", real_target], on_line=emit, timeout=240)
                else:
                    rc, out = self._run_manage(["restore", real_target], timeout=240)
            return {"ok": rc == 0, "returncode": rc, "output": out, "backups": self.list_backups()}

        if async_mode:
            return {"accepted": True, "job": self.start_job("backup_restore", f"Restore backup {clean}", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("backup_restore", f"Restore backup {clean}", actor, res, t0)
        return res

    def prune_backups(self, keep: int) -> dict[str, Any]:
        if keep < 1 or keep > 100:
            return {"ok": False, "error": "Keep count must be between 1 and 100."}
        backups = self.list_backups()
        removed: list[str] = []
        base_real = os.path.realpath(self.backup_dir)
        for item in backups[keep:]:
            target = os.path.realpath(os.path.join(self.backup_dir, item["name"]))
            if os.path.dirname(target) == base_real and os.path.isfile(target) and not os.path.islink(target):
                os.unlink(target)
                removed.append(item["name"])
        return {"ok": True, "removed": removed, "backups": self.list_backups()}

    def get_backup_cron(self) -> dict[str, Any]:
        rc, out = self._run_manage(["backup", "cron-status"], timeout=15)
        kv = parse_kv_lines(out)
        return {
            "ok": rc == 0,
            "enabled": kv.get("CRON_ENABLED", "false") == "true",
            "hour": int(kv["CRON_HOUR"]) if kv.get("CRON_HOUR", "").isdigit() else 3,
            "keep": int(kv["CRON_KEEP"]) if kv.get("CRON_KEEP", "").isdigit() else 7,
            "line": kv.get("CRON_LINE", ""),
        }

    def update_backup_cron(self, enabled: bool, hour: int = 3, keep: int = 7) -> dict[str, Any]:
        if not enabled:
            with self._op_lock:
                rc, out = self._run_manage(["backup", "cron-disable"], timeout=20)
            return {"ok": rc == 0, "returncode": rc, "output": out, "cron": self.get_backup_cron()}
        if hour < 0 or hour > 23:
            return {"ok": False, "returncode": 2, "error": "Cron hour must be between 0 and 23."}
        if keep < 1 or keep > 365:
            return {"ok": False, "returncode": 2, "error": "Retention count must be between 1 and 365."}
        with self._op_lock:
            rc, out = self._run_manage(["backup", "cron-set", str(hour), str(keep)], timeout=20)
        return {"ok": rc == 0, "returncode": rc, "output": out, "cron": self.get_backup_cron()}

    def update_webpanel_settings(self, idle_minutes: int) -> dict[str, Any]:
        if idle_minutes < 5 or idle_minutes > 1440:
            return {"ok": False, "returncode": 2, "error": "Idle timeout must be between 5 and 1440 minutes."}
        with self._op_lock:
            rc, out = self._run_manage(["webpanel", "update-settings", f"idle={idle_minutes}"], timeout=20)
        return {"ok": rc == 0, "returncode": rc, "idle_minutes": idle_minutes, "output": out}

    def get_logs(
        self, source: str, lines: int = 150, level: str = "ALL", query: str = ""
    ) -> dict[str, Any]:
        n = max(10, min(500, int(lines)))
        lvl = (level or "ALL").strip().upper()
        q_low = (query or "").strip().lower()

        def _filter_lines(raw_list: list[str], use_bracket_level: bool = True) -> list[str]:
            out = raw_list[-n:]
            if use_bracket_level and lvl in ("INFO", "OK", "WARN", "ERROR", "CRITICAL", "DEBUG", "AUDIT"):
                out = [ln for ln in out if f"[{lvl}]" in ln]
            elif not use_bracket_level and lvl in ("INFO", "WARN", "ERROR", "DEBUG"):
                out = [ln for ln in out if lvl.lower() in ln.lower()]
            if q_low:
                out = [ln for ln in out if q_low in ln.lower()]
            return [auth.sanitize_log_text(ln) for ln in out]

        if source in ("deploy", "audit", "backup"):
            if source == "deploy":
                path = self.deploy_log_path
            elif source == "audit":
                path = self.audit_log_path
            else:
                path = "/var/log/3xui-backup.log"

            if not os.path.isfile(path):
                return {"ok": True, "source": source, "lines": [], "note": f"Log file does not exist yet: {path}"}
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    all_lines = fh.read().splitlines()
                return {"ok": True, "source": source, "lines": _filter_lines(all_lines, use_bracket_level=(source != "backup"))}
            except OSError as exc:
                return {"ok": False, "source": source, "lines": [], "error": str(exc)}

        if source in ("xui", "caddy", "postgres"):
            container = {"xui": "3xui_app", "caddy": "3xui_caddy", "postgres": "3xui_postgres"}[source]
            if not shutil.which("docker"):
                return {"ok": False, "source": source, "lines": [], "error": "Docker binary unavailable."}
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
                return {
                    "ok": proc.returncode == 0,
                    "source": source,
                    "lines": _filter_lines(raw_lines, use_bracket_level=False),
                }
            except Exception as exc:  # noqa: BLE001
                return {"ok": False, "source": source, "lines": [], "error": str(exc)}

        return {
            "ok": False,
            "source": source,
            "lines": [],
            "error": "Unknown log source (use deploy, audit, xui, caddy, postgres, or backup).",
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

    def check_and_update_probe_state(self, sync_caddy_on_change: bool = True) -> dict[str, Any]:
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
                    "last_checked": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                }
                probe.save_probe_state(self.probe_state_path, new_state)
                return {"changed": prev_active != "disabled", "state": new_state, "sync_output": ""}

            primary_probe = probe.check_target_reachability(str(cfg.get("PROBE_REDIRECT_TARGET") or ""))
            secondary_probe = None
            if cfg.get("PROBE_FALLBACK_MODE") == "secondary_url" and cfg.get("PROBE_FALLBACK_URL"):
                secondary_probe = probe.check_target_reachability(str(cfg.get("PROBE_FALLBACK_URL")))

            eval_res = probe.evaluate_effective_state(cfg, primary_probe, secondary_probe)
            failures = 0 if primary_probe.get("reachable") else int(prev_state.get("consecutive_failures", 0)) + 1

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
                "secondary_ok": bool(secondary_probe.get("reachable")) if secondary_probe else False,
                "secondary_error": str(secondary_probe.get("error", "")) if secondary_probe else "",
            }
            probe.save_probe_state(self.probe_state_path, new_state)

            changed = prev_active != new_state["active_state"]
            sync_out = ""
            if changed and sync_caddy_on_change and os.path.isfile(self.proxy_conf_path):
                with self._op_lock:
                    _, sync_out = self._run_manage(["proxy", "sync-caddy"], timeout=45)
            return {
                "changed": changed,
                "state": new_state,
                "primary": primary_probe,
                "secondary": secondary_probe,
                "sync_output": sync_out,
            }

    def update_probe_config(self, payload: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
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
                    with self._probe_lock:
                        probe.save_probe_conf(self.probe_conf_path, current)
                    self._run_manage(["proxy", "sync-caddy"], timeout=60)
                    return False, {"error": f"Caddy rejected updated configuration (rolled back): {sync_out}"}

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
            "tagline": cfg.get("DECOY_SITE_TAGLINE", "Managed Edge Infrastructure & Reliability Engineering"),
            "contact_email": cfg.get("DECOY_CONTACT_EMAIL", "hello@meridiancloud.example"),
            "custom_html_active": custom_active,
            "themes": [
                {"id": "cloud", "label": "Meridian Cloud Systems (Infrastructure / Edge)"},
                {"id": "studio", "label": "Northstar Digital Studio (Product & Design)"},
                {"id": "docs", "label": "Atlas Engineering Docs (Technical Portal)"},
            ],
        }

    def update_decoy_config(self, payload: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
        current = probe.load_probe_conf(self.probe_conf_path)
        theme = str(payload.get("theme", current["DECOY_THEME"])).strip()
        site_name = str(payload.get("site_name", current["DECOY_SITE_NAME"])).strip()
        tagline = str(payload.get("tagline", current["DECOY_SITE_TAGLINE"])).strip()
        email = str(payload.get("contact_email", current["DECOY_CONTACT_EMAIL"])).strip()
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
            fd, tmp_path = tempfile.mkstemp(prefix=".index-", suffix=".html", dir=site_dir)
            try:
                os.chmod(tmp_path, 0o644)
                with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(custom_html)
                os.replace(tmp_path, os.path.join(site_dir, "index.html"))
                os.chmod(os.path.join(site_dir, "index.html"), 0o644)
            except Exception as exc:  # noqa: BLE001
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
                return False, {"error": f"Failed to write custom decoy HTML: {exc}"}
            return True, {"decoy": self.get_decoy_config(), "output": "Applied custom decoy index.html."}

        with self._op_lock:
            rc, out = self._run_manage(["proxy", "decoy-apply"], timeout=45)
        if rc != 0:
            return False, {"error": out or "Failed to regenerate decoy website."}
        return True, {"decoy": self.get_decoy_config(), "output": out}

    def run_geo_update(
        self, scope: str, *, async_mode: bool = False, actor: str = "admin"
    ) -> dict[str, Any]:
        if scope not in GEO_SCOPES:
            return {
                "ok": False,
                "returncode": 2,
                "output": "Invalid GeoIP scope (use std, ir, ru, or all).",
            }

        def _exec(emit: Callable[[str], None] | None = None) -> dict[str, Any]:
            with self._op_lock:
                if emit:
                    rc, out = self._run_manage_streaming(["geo-update", scope], on_line=emit, timeout=180)
                else:
                    rc, out = self._run_manage(["geo-update", scope], timeout=180)
            return {"ok": rc == 0, "returncode": rc, "scope": scope, "output": out}

        if async_mode:
            return {"accepted": True, "job": self.start_job("geo_update", f"Update GeoIP/GeoSite ({scope})", actor, _exec)}
        t0 = time.monotonic()
        res = _exec()
        self.record_sync_job("geo_update", f"Update GeoIP/GeoSite ({scope})", actor, res, t0)
        return res
