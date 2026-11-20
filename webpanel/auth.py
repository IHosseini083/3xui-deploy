"""Authentication, session management, CSRF protection, and audit logging."""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import json
import os
import re
import secrets
import sys
import tempfile
import threading
import time
from typing import Any

WEAK_PASSWORDS = frozenset(
    {
        "admin",
        "password",
        "123456",
        "12345678",
        "3x-ui",
        "root",
        "password1234",
        "123456789012",
    }
)

USERNAME_RE = re.compile(r"^[a-zA-Z0-9._-]{1,64}$")

REDACT_PATTERNS = (
    (re.compile(r"(XUI_DB_DSN=)[^\s'\"]+"), r"\1[REDACTED]"),
    (re.compile(r"(POSTGRES_PASSWORD=)[^\s'\"]+"), r"\1[REDACTED]"),
    (re.compile(r"(-password=)[^\s'\"]+"), r"\1[REDACTED]"),
    (re.compile(r"(SSH_PASS(?:_B64)?=)[^\s'\"]+"), r"\1[REDACTED]"),
    (re.compile(r"(Bearer\s+)[A-Za-z0-9._-]+", re.IGNORECASE), r"\1[REDACTED]"),
    (re.compile(r"(PG Pass\s*:\s*)\S+"), r"\1[REDACTED]"),
    (re.compile(r"(Generated password\s*:\s*)\S+"), r"\1[REDACTED]"),
    (re.compile(r"(WebPanel Auth\s*:\s*\S+\s*/\s*)\S+"), r"\1[REDACTED]"),
)


def sanitize_log_text(text: str) -> str:
    """Strip control characters and redact sensitive credential patterns."""
    cleaned = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or "")).strip()
    for pattern, replacement in REDACT_PATTERNS:
        cleaned = pattern.sub(replacement, cleaned)
    return cleaned


def has_control_chars(value: str) -> bool:
    """Return True if value contains ASCII control characters or NUL."""
    return any(ord(ch) < 32 or ord(ch) == 127 for ch in value)


def validate_username(username: str) -> tuple[bool, str]:
    """Validate an admin username."""
    if not username or not USERNAME_RE.fullmatch(username):
        return False, "Username must be 1-64 chars (letters, digits, '.', '_', '-')."
    if username.startswith("-"):
        return False, "Username cannot start with '-'."
    return True, ""


def validate_strong_password(password: str) -> tuple[bool, str]:
    """Enforce the same password complexity policy as manage.sh."""
    if not password:
        return False, "Password cannot be empty."
    if has_control_chars(password):
        return False, "Password cannot contain control characters."
    if len(password) < 12:
        return False, "Password must be at least 12 characters."
    if password.lower() in WEAK_PASSWORDS:
        return False, "Password is too common."
    classes = 0
    if re.search(r"[a-z]", password):
        classes += 1
    if re.search(r"[A-Z]", password):
        classes += 1
    if re.search(r"[0-9]", password):
        classes += 1
    if re.search(r"[^a-zA-Z0-9]", password):
        classes += 1
    if len(password) < 16 and classes < 2:
        return False, "Password must be >=16 chars or include >=2 character classes."
    return True, ""


def hash_password(password: str) -> str:
    """Derive a salted scrypt password hash string."""
    salt = secrets.token_bytes(16)
    dk = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=32)
    return "scrypt${}${}".format(
        base64.b64encode(salt).decode("ascii"),
        base64.b64encode(dk).decode("ascii"),
    )


def verify_password(password: str, stored_hash: str) -> bool:
    """Verify password against stored scrypt hash in constant time."""
    if not password or not stored_hash:
        return False
    parts = stored_hash.split("$")
    if len(parts) != 3 or parts[0] != "scrypt":
        return False
    try:
        salt = base64.b64decode(parts[1].encode("ascii"), validate=True)
        expected = base64.b64decode(parts[2].encode("ascii"), validate=True)
    except Exception:  # noqa: BLE001
        return False
    derived = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=len(expected))
    return hmac.compare_digest(derived, expected)


def _atomic_write_json(path: str, payload: dict[str, Any], mode: int = 0o600) -> None:
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


class AuthStore:
    """Thread-safe credential store, session manager, rate limiter, and audit logger."""

    RATE_WINDOW_SEC = 900
    MAX_FAILURES = 5

    def __init__(
        self,
        auth_file: str,
        audit_log_file: str,
        idle_minutes: int = 30,
        max_hours: int = 12,
    ) -> None:
        self.auth_file = auth_file
        self.audit_log_file = audit_log_file
        self.idle_seconds = max(5, int(idle_minutes)) * 60
        self.max_seconds = max(1, int(max_hours)) * 3600
        self._lock = threading.RLock()
        self._sessions: dict[str, dict[str, Any]] = {}
        self._failures: dict[str, list[float]] = {}
        self._dummy_hash = hash_password("DummyTimingProtection!2026")

    def _load_auth_data(self) -> dict[str, Any]:
        if not os.path.isfile(self.auth_file):
            return {"version": 1, "users": {}}
        try:
            with open(self.auth_file, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            if not isinstance(data, dict) or not isinstance(data.get("users"), dict):
                return {"version": 1, "users": {}}
            return data
        except Exception:  # noqa: BLE001
            return {"version": 1, "users": {}}

    def audit_log(self, event: str, actor: str, ip: str, detail: str = "") -> None:
        """Append a sanitized audit line to the webpanel audit log."""
        ts = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        line = "{} [AUDIT] event={} actor={} ip={} detail={}\n".format(
            ts,
            sanitize_log_text(event),
            sanitize_log_text(actor or "-"),
            sanitize_log_text(ip or "-"),
            sanitize_log_text(detail),
        )
        try:
            log_dir = os.path.dirname(os.path.abspath(self.audit_log_file))
            os.makedirs(log_dir, mode=0o700, exist_ok=True)
            fd = os.open(self.audit_log_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8", newline="\n") as fh:
                fh.write(line)
        except OSError:
            pass

    def has_users(self) -> bool:
        with self._lock:
            return bool(self._load_auth_data().get("users"))

    def set_user_password(self, username: str, password: str, overwrite: bool = True) -> tuple[bool, str]:
        """Create or update a user password in auth.json."""
        ok_u, msg_u = validate_username(username)
        if not ok_u:
            return False, msg_u
        ok_p, msg_p = validate_strong_password(password)
        if not ok_p:
            return False, msg_p

        with self._lock:
            data = self._load_auth_data()
            users = data.setdefault("users", {})
            if username in users and not overwrite:
                return True, "User already exists; preserved existing credentials."
            now_iso = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            users[username] = {
                "password_hash": hash_password(password),
                "updated_at": now_iso,
                "created_at": users.get(username, {}).get("created_at", now_iso),
            }
            _atomic_write_json(self.auth_file, data, mode=0o600)
            return True, "Credentials saved."

    def _prune_sessions_locked(self, now: float) -> None:
        expired = [
            key
            for key, s in self._sessions.items()
            if (now - s["last_seen"] > self.idle_seconds) or (now - s["created_at"] > self.max_seconds)
        ]
        for key in expired:
            self._sessions.pop(key, None)

    def _check_rate_limit_locked(self, client_ip: str, now: float) -> int:
        recent = [ts for ts in self._failures.get(client_ip, []) if now - ts <= self.RATE_WINDOW_SEC]
        if recent:
            self._failures[client_ip] = recent
        else:
            self._failures.pop(client_ip, None)
        if len(recent) >= self.MAX_FAILURES:
            oldest = recent[0]
            return max(1, int(self.RATE_WINDOW_SEC - (now - oldest)))
        return 0

    def _create_session_locked(self, username: str, client_ip: str, user_agent: str, now: float) -> dict[str, Any]:
        token = secrets.token_urlsafe(32)
        csrf = secrets.token_urlsafe(24)
        token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
        self._sessions[token_hash] = {
            "sid_id": token_hash[:12],
            "username": username,
            "csrf_token": csrf,
            "created_at": now,
            "last_seen": now,
            "ip": client_ip or "127.0.0.1",
            "user_agent": sanitize_log_text(user_agent)[:160],
        }
        return {
            "sid_id": token_hash[:12],
            "session_token": token,
            "csrf_token": csrf,
            "username": username,
            "expires_in": self.idle_seconds,
        }

    def authenticate(
        self, username: str, password: str, client_ip: str, user_agent: str = ""
    ) -> tuple[bool, dict[str, Any]]:
        """Authenticate credentials with rate limiting and session creation."""
        now = time.time()
        ip_key = client_ip or "unknown"
        with self._lock:
            self._prune_sessions_locked(now)
            retry_after = self._check_rate_limit_locked(ip_key, now)
            if retry_after > 0:
                self.audit_log("login_rate_limited", username, ip_key, f"retry_after={retry_after}s")
                return False, {
                    "status": 429,
                    "error": f"Too many failed login attempts. Retry in {retry_after}s.",
                    "retry_after": retry_after,
                }

            data = self._load_auth_data()
            users = data.get("users", {})
            user_rec = users.get(username)
            stored_hash = user_rec.get("password_hash", "") if isinstance(user_rec, dict) else ""

            if not stored_hash:
                verify_password(password, self._dummy_hash)
                valid = False
            else:
                valid = verify_password(password, stored_hash)

            if not valid:
                self._failures.setdefault(ip_key, []).append(now)
                self.audit_log("login_failed", username, ip_key, "invalid_credentials")
                return False, {"status": 401, "error": "Invalid username or password."}

            self._failures.pop(ip_key, None)
            session = self._create_session_locked(username, ip_key, user_agent, now)
            self.audit_log("login_success", username, ip_key, f"sid={session['sid_id']}")
            return True, session

    def validate_session(self, session_token: str | None, touch: bool = True) -> dict[str, Any] | None:
        """Return active session metadata for a cookie token, or None if invalid/expired."""
        if not session_token:
            return None
        token_hash = hashlib.sha256(session_token.encode("utf-8")).hexdigest()
        now = time.time()
        with self._lock:
            self._prune_sessions_locked(now)
            sess = self._sessions.get(token_hash)
            if not sess:
                return None
            if touch:
                sess["last_seen"] = now
            return dict(sess)

    @staticmethod
    def verify_csrf(session: dict[str, Any] | None, header_token: str | None) -> bool:
        """Constant-time CSRF header token check."""
        if not session or not header_token:
            return False
        expected = session.get("csrf_token", "")
        if not expected:
            return False
        return hmac.compare_digest(expected, header_token)

    def logout(self, session_token: str | None, client_ip: str = "") -> bool:
        """Invalidate the given session token."""
        if not session_token:
            return False
        token_hash = hashlib.sha256(session_token.encode("utf-8")).hexdigest()
        with self._lock:
            removed = self._sessions.pop(token_hash, None)
            if removed:
                self.audit_log("logout", removed.get("username", ""), client_ip, f"sid={removed.get('sid_id', '')}")
                return True
            return False

    def change_password(
        self,
        username: str,
        current_password: str,
        new_password: str,
        current_token: str,
        client_ip: str = "",
        user_agent: str = "",
    ) -> tuple[bool, str, dict[str, Any] | None]:
        """Verify current password, update hash, revoke all sessions, and issue rotated session."""
        ok_p, msg_p = validate_strong_password(new_password)
        if not ok_p:
            return False, msg_p, None

        now = time.time()
        with self._lock:
            data = self._load_auth_data()
            user_rec = data.get("users", {}).get(username)
            if not isinstance(user_rec, dict) or not verify_password(current_password, user_rec.get("password_hash", "")):
                self.audit_log("password_change_failed", username, client_ip, "bad_current_password")
                return False, "Current password is incorrect.", None

            user_rec["password_hash"] = hash_password(new_password)
            user_rec["updated_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            _atomic_write_json(self.auth_file, data, mode=0o600)

            # Rotate active session and drop all other active sessions for this user.
            for k in [k for k, v in self._sessions.items() if v.get("username") == username]:
                self._sessions.pop(k, None)
            rotated = self._create_session_locked(username, client_ip, user_agent, now)
            self.audit_log("password_changed", username, client_ip, "sessions_rotated")
            return True, "Password updated and sessions rotated.", rotated

    def list_sessions(self, current_token: str | None) -> list[dict[str, Any]]:
        """List active sessions without exposing secret tokens."""
        cur_hash = hashlib.sha256(current_token.encode("utf-8")).hexdigest() if current_token else ""
        now = time.time()
        with self._lock:
            self._prune_sessions_locked(now)
            out: list[dict[str, Any]] = []
            for th, s in self._sessions.items():
                out.append(
                    {
                        "sid": s["sid_id"],
                        "username": s["username"],
                        "ip": s["ip"],
                        "user_agent": s["user_agent"],
                        "created_at": dt.datetime.fromtimestamp(s["created_at"], dt.timezone.utc).strftime(
                            "%Y-%m-%dT%H:%M:%SZ"
                        ),
                        "last_seen": dt.datetime.fromtimestamp(s["last_seen"], dt.timezone.utc).strftime(
                            "%Y-%m-%dT%H:%M:%SZ"
                        ),
                        "current": hmac.compare_digest(th, cur_hash) if cur_hash else False,
                    }
                )
            out.sort(key=lambda item: (not item["current"], item["last_seen"]), reverse=False)
            return out

    def set_idle_minutes(self, idle_minutes: int) -> int:
        """Update idle session timeout dynamically without dropping active sessions."""
        clamped = max(5, min(1440, int(idle_minutes)))
        with self._lock:
            self.idle_seconds = clamped * 60
        return clamped

    def revoke_other_sessions(self, current_token: str, username: str, client_ip: str = "") -> int:
        """Revoke all sessions belonging to username except current_token."""
        cur_hash = hashlib.sha256(current_token.encode("utf-8")).hexdigest()
        with self._lock:
            to_drop = [
                k for k, s in self._sessions.items() if s.get("username") == username and not hmac.compare_digest(k, cur_hash)
            ]
            for k in to_drop:
                self._sessions.pop(k, None)
            self.audit_log("sessions_revoked_others", username, client_ip, f"count={len(to_drop)}")
            return len(to_drop)


def _cli_main(argv: list[str]) -> int:
    if len(argv) < 4 or argv[1] not in ("init-admin", "set-password"):
        print("Usage: python3 -m webpanel.auth <init-admin|set-password> <auth_file> <username>", file=sys.stderr)
        return 2
    action, auth_file, username = argv[1], argv[2], argv[3]
    pw_line = sys.stdin.readline().rstrip("\r\n")
    store = AuthStore(auth_file=auth_file, audit_log_file=os.path.join(os.path.dirname(auth_file), "audit.log"))
    overwrite = action == "set-password"
    ok, msg = store.set_user_password(username, pw_line, overwrite=overwrite)
    if not ok:
        print(f"ERROR: {msg}", file=sys.stderr)
        return 1
    print(msg)
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli_main(sys.argv))
