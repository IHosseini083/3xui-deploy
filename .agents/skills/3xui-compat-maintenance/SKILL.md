---
name: 3xui-compat-maintenance
description: >-
  Maintains forward compatibility with mhsanaei/3x-ui releases, database schema drift,
  capability probing, structured diagnostics, and rollback-safe upgrades in manage.sh.
  Use when updating supported 3x-ui versions, adapting to upstream CLI/DB changes, or
  modifying upgrade/rollback/logging behavior.
---

# 3x-ui Forward Compatibility & Rollback Maintenance

Use this skill whenever `mhsanaei/3x-ui` introduces new versions, CLI flag changes, container layout changes, database schema changes, or new Xray transport/protocol types.

## Key Principles

1. **Treat `3xui_app` as an External Black-Box Dependency**:
   - Never patch files inside the upstream `3x-ui` container image or rely on `apk add` inside `3xui_app` when host tools (`sqlite3`, `curl`) can perform the operation cleanly.
   - Discover binary paths (`_xui_find_binary`), data directories (`_xui_detect_db_path`), and geo-asset directories (`_xui_detect_bin_dir`) dynamically via environment variables and probes rather than hardcoding a single path.
2. **Enforce Explicit Version & Schema Contracts**:
   - Reference [3x-ui Contract Reference](./references/3xui-contract.md) for current version boundaries (`XUI_COMPAT_MIN_VERSION`, `XUI_COMPAT_MAX_TESTED_MAJOR`), expected DB tables/columns, and CLI flags.
   - Report unsupported versions, missing binaries, or DB schema drift explicitly via `report_diagnostic` (never ignore silently). Allow explicit override only via `--force-compat`.
3. **Atomic & Rollback-Safe Operations**:
   - All `apply_version` updates must execute: `classify -> pull -> preflight -> snapshot (compose.yaml.bak + pre_update backup) -> apply -> verify -> auto-rollback on failure`.
   - Maintain structured stage tracking (`log_stage <op> <stage> <msg>`) and sanitize all secrets in `_sanitize_log_text` before writing logs.

## Workflow for Adding Support for a New 3x-ui Major Release

1. Pull or inspect the target `ghcr.io/mhsanaei/3x-ui:<tag>` image with `./manage.sh compat test <tag>` (or manually via `docker run --rm --entrypoint sh ...`).
2. Compare binary path, `setting -h` flags, `settings` keys, `inbounds` columns (e.g., `stream_settings` vs `streamSettings`), and Xray protocol names against [3x-ui Contract Reference](./references/3xui-contract.md).
3. Update adapter helpers in `manage.sh` (`_xui_find_binary`, `xui_probe_capabilities`, `_xui_check_db_schema`, `get_xui_inbounds`, `_inbound_fw_proto`, `_probe_panel_http`, `XUI_COMPAT_MAX_TESTED_MAJOR`) preserving backward compatibility with `v2.x` and `v3.x`.
4. Add mock regression tests in `tests/test_compat.sh` covering the new behavior and failure/rollback paths.

## Verification

1. Run `bash -n manage.sh tests/test_compat.sh`.
2. Run `bash tests/test_compat.sh` and `bash tests/test_manage.sh` and confirm 0 failures.
3. Verify `./manage.sh --help` documents any new flags or commands.
