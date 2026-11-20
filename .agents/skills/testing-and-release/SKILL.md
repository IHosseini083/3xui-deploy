---
name: testing-and-release
description: >-
  Runs full syntax, LF line-ending, Bash compatibility, Caddyfile, and Python WebPanel
  verification suites before committing or releasing changes to 3xui-deploy. Use after
  editing code, tests, CI workflows, or documentation.
---

# Testing & Release Verification

Follow this checklist before declaring any change to `3xui-deploy` complete.

## Checklist

1. **Version Consistency (SemVer)**:
   - Confirm `VERSION`, `DEPLOY_VERSION` in `manage.sh`, `__version__` in `webpanel/__init__.py`, and the top `## [vX.Y.Z]` heading in `CHANGELOG.md` match before tagging a release.

2. **Line Endings (LF Required)**:
   - Verify no `\r` (`CRLF`) bytes exist in `VERSION`, `CHANGELOG.md`, `manage.sh`, `tests/*.sh`, `tests/*.py`, `webpanel/**/*.py`, `webpanel/static/*`, `.github/workflows/*.yml`, or `.md` files.
   - Windows Git Bash / PowerShell edits can accidentally introduce CRLF unless checked.

3. **Bash Syntax & Unit Suites**:
   - Run `bash -n manage.sh tests/test_manage.sh tests/test_compat.sh`.
   - If `shellcheck` is installed, run `shellcheck -S warning manage.sh tests/test_manage.sh tests/test_compat.sh`.
   - Run `bash tests/test_manage.sh` — must exit `0` with `0 failed`.
   - Run `bash tests/test_compat.sh` — must exit `0` with `0 failed`.
   - Smoke test CLI help & version: `./manage.sh --help` and `./manage.sh --version`.

4. **Python WebPanel Suite**:
   - Run `python3 -m py_compile webpanel/__init__.py webpanel/auth.py webpanel/probe.py webpanel/ops.py webpanel/server.py tests/test_webpanel.py`.
   - Run `python3 -m unittest discover -s tests -p "test_*.py" -v`.
   - If running on a host without `python3` (such as a Windows workstation lacking Python), explicitly state that Python execution was skipped locally and rely on `.github/workflows/ci.yml` (`ubuntu-latest`) after manual code audit.

5. **Security & Hygiene Sanity**:
   - Ensure no secrets, `.env`, `.conf`, `auth.json`, or temporary artifacts exist in `git status`.
   - Confirm CI workflow `.github/workflows/ci.yml` exercises all test scripts and release workflow `.github/workflows/release.yml` matches tag conventions.
