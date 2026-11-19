#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/3xui-compat-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
mkdir -p "$HOME"
export XUI_INSTALL_DIR="$TEST_TMP/opt-3x-ui"
export XUI_BACKUP_DIR="$TEST_TMP/opt-3x-ui-backups"
export XUI_LOG_FILE="$TEST_TMP/deploy.log"
export XUI_SOURCE_ONLY=1

# shellcheck source=../manage.sh
source "$REPO_ROOT/manage.sh"
NO_COLOR=1
setup_terminal

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$(( PASS_COUNT + 1 )); }
fail() { FAIL_COUNT=$(( FAIL_COUNT + 1 )); printf 'FAIL: %s\n' "$1" >&2; }

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-values equal}"
    [[ "$expected" == "$actual" ]] && pass || fail "$msg (expected='$expected', actual='$actual')"
}

assert_ok() {
    local msg="$1"; shift
    "$@" && pass || fail "$msg (expected exit 0)"
}

assert_fail() {
    local msg="$1"; shift
    "$@" && fail "$msg (expected non-zero exit)" || pass
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-contains}"
    printf '%s' "$haystack" | grep -qF -- "$needle" && pass || fail "$msg (missing '$needle')"
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-not contains}"
    printf '%s' "$haystack" | grep -qF -- "$needle" && fail "$msg (unexpected '$needle')" || pass
}

# ─── 1. Semver Parsing & Classification ─────────────────────────────────────
test_version_classification() {
    assert_eq "2 5 3" "$(_semver_parse "v2.5.3")" "parse v2.5.3"
    assert_eq "3 1 0" "$(_semver_parse "3.1.0-beta.1")" "parse 3.1.0-beta.1"
    assert_fail "reject latest in semver_parse" _semver_parse "latest"

    assert_eq "-1" "$(_semver_compare "v2.4.0" "v2.5.0")" "compare 2.4 < 2.5"
    assert_eq "0"  "$(_semver_compare "v3.0.0" "3.0.0")"  "compare v3.0.0 == 3.0.0"
    assert_eq "1"  "$(_semver_compare "v3.1.0" "v2.9.9")" "compare 3.1 > 2.9.9"

    assert_eq "unsupported_legacy" "$(xui_classify_version "v1.9.5")" "v1.9.5 unsupported legacy"
    assert_eq "supported"          "$(xui_classify_version "v2.6.0" "v2.5.0")" "v2.6.0 supported"
    assert_eq "major_upgrade"      "$(xui_classify_version "v3.0.0" "v2.6.0")" "v2 -> v3 major upgrade"
    assert_eq "supported"          "$(xui_classify_version "v3.2.1" "v3.0.0")" "v3.2.1 supported"
    assert_eq "unsupported_major"  "$(xui_classify_version "v4.0.0" "v3.2.1")" "v4.0.0 unsupported major"
    assert_eq "unknown_tag"        "$(xui_classify_version "latest" "v2.6.0")" "latest unknown tag"
}

# ─── 2. Structured Logging, Redaction & Diagnostics ─────────────────────────
test_logging_and_diagnostics() {
    : > "$XUI_LOG_FILE"
    log_stage "update" "verify" "Starting verify with -password=SuperSecret99 XUI_DB_DSN=postgres://u:pw@127.0.0.1/db"
    warn "Non-fatal config warning"
    local diag_err
    diag_err=$(report_diagnostic "CRITICAL" "test_op" "schema mismatch" "inbounds table" "Run compat check" "col missing" 2>&1)

    local log_txt
    log_txt=$(< "$XUI_LOG_FILE")
    assert_contains "$log_txt" "[INFO] [op=update stage=verify]" "log stage & INFO level"
    assert_contains "$log_txt" "[WARN]" "log WARN level"
    assert_contains "$log_txt" "[CRITICAL]" "log CRITICAL level"
    assert_contains "$log_txt" "-password=[REDACTED]" "log redacts -password"
    assert_contains "$log_txt" "XUI_DB_DSN=[REDACTED]" "log redacts XUI_DB_DSN"
    assert_not_contains "$log_txt" "SuperSecret99" "secret password absent from log file"
    assert_contains "$diag_err" "Root Cause : schema mismatch" "diagnostic prints Root Cause"
    assert_contains "$diag_err" "Resolution : Run compat check" "diagnostic prints Resolution"
}

# ─── 3. Capability Probing & DB Schema Drift Detection ──────────────────────
test_capability_probing_and_schema_drift() {
    REMOTE=false
    is_running() { return 0; }
    _is_postgres_backend() { return 1; }
    invalidate_status

    # Case A: Compatible binary & intact schema
    run_out() {
        case "$1" in
            *"head -c 2"*) printf '/app/x-ui' ;;
            *"XUI_DB_FOLDER"*) printf '/etc/x-ui/x-ui.db' ;;
            *"XUI_BIN_FOLDER"*) printf '/app/bin' ;;
            *"setting -h"*) printf '  -show\n  -getListen\n  -getCert\n  -port\n  -listenIP\n  -webBasePath\n  -username\n  -password\n  -resetTwoFactor\n' ;;
            *"PRAGMA table_info(settings)"*) printf '0|id|INTEGER\n1|key|TEXT\n2|value|TEXT\n' ;;
            *"PRAGMA table_info(inbounds)"*) printf '0|id|INTEGER\n1|enable|INTEGER\n2|protocol|TEXT\n3|listen|TEXT\n4|port|INTEGER\n5|remark|TEXT\n6|stream_settings|TEXT\n' ;;
        esac
    }
    run_q() { return 0; }

    assert_ok "xui_probe_capabilities succeeds on valid layout" xui_probe_capabilities
    assert_eq "/app/x-ui" "$XUI_CAPS_BIN" "detected /app/x-ui binary"
    assert_eq "ok" "$XUI_CAPS_SCHEMA_OK" "schema marked ok"
    assert_contains "$XUI_CAPS_FLAGS" "show" "detected -show flag"
    assert_contains "$XUI_CAPS_FLAGS" "webBasePath" "detected -webBasePath flag"

    # Case B: Relocated binary (/app/3x-ui) & missing stream_settings column -> schema drift error
    invalidate_status
    run_out() {
        case "$1" in
            *"head -c 2"*) printf '/app/3x-ui' ;;
            *"XUI_DB_FOLDER"*) printf '/etc/x-ui/x-ui.db' ;;
            *"XUI_BIN_FOLDER"*) printf '/app/bin' ;;
            *"setting -h"*) printf '  -show\n  -port\n' ;;
            *"PRAGMA table_info(settings)"*) printf '0|id|INTEGER\n1|key|TEXT\n2|value|TEXT\n' ;;
            *"PRAGMA table_info(inbounds)"*) printf '0|id|INTEGER\n1|enable|INTEGER\n2|protocol|TEXT\n3|listen|TEXT\n4|port|INTEGER\n5|remark|TEXT\n' ;;
        esac
    }
    assert_fail "xui_probe_capabilities detects DB schema drift" xui_probe_capabilities >/dev/null 2>&1
    assert_eq "/app/3x-ui" "$XUI_CAPS_BIN" "detected fallback /app/3x-ui binary"
    assert_eq "drift" "$XUI_CAPS_SCHEMA_OK" "schema marked drift"

    # Case C: UDP v3.x protocols (amneziawg, masque)
    assert_eq "udp" "$(_inbound_fw_proto "amneziawg" "tcp")" "amneziawg maps to udp"
    assert_eq "udp" "$(_inbound_fw_proto "masque" "tcp")"    "masque maps to udp"
}

# ─── 4. Safe Update, Pull Failure & Automatic Rollback ──────────────────────
test_update_safety_and_rollback() {
    REMOTE=false
    INTERACTIVE=false
    AUTO_YES=true
    FORCE_COMPAT=false
    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/compose.yaml" <<'YAML'
services:
  3xui:
    image: ghcr.io/mhsanaei/3x-ui:v2.5.0
YAML
    rm -f "$INSTALL_DIR/compose.yaml.bak"

    is_deployed() { [[ -f "$INSTALL_DIR/compose.yaml" ]]; }
    detect_compose() { COMPOSE_CMD="docker compose"; return 0; }
    is_running() { return 0; }
    is_pg_running() { return 1; }
    _is_postgres_backend() { return 1; }
    _perform_backup() { return 0; }

    # Case 1: Unsupported major v4.0.0 refused before touching compose.yaml
    assert_fail "apply_version refuses unsupported v4.0.0" apply_version "v4.0.0" >/dev/null 2>&1
    assert_contains "$(< "$INSTALL_DIR/compose.yaml")" "3x-ui:v2.5.0" "compose.yaml untouched on v4 refusal"

    # Case 2: Failed image pull leaves compose.yaml untouched (no .bak mutation)
    run() {
        local cmd="$1"
        if [[ "$cmd" == *"docker pull"* ]]; then
            return 1
        fi
        bash -c "$cmd"
    }
    assert_fail "apply_version aborts when pull fails" apply_version "v2.6.0" >/dev/null 2>&1
    assert_contains "$(< "$INSTALL_DIR/compose.yaml")" "3x-ui:v2.5.0" "compose.yaml untouched after pull failure"
    assert_fail "compose.yaml.bak not created on pull failure" test -f "$INSTALL_DIR/compose.yaml.bak"

    # Case 3: Pull & preflight succeed, but post-update verify_panel_loaded fails -> automatic rollback!
    local compose_calls=0 verify_called=false
    run() {
        local cmd="$1"
        if [[ "$cmd" == *"docker pull"* ]]; then
            return 0
        fi
        bash -c "$cmd"
    }
    run_out() {
        case "$1" in
            *"awk -F:"*) awk -F: '/image:[[:space:]]*ghcr\.io\/mhsanaei\/3x-ui:/ {print $NF; exit}' "$INSTALL_DIR/compose.yaml" ;;
            *"docker inspect"*) printf 'v2.5.0\n' ;;
            *"docker run --rm"*) printf 'PREFLIGHT_BIN=/app/x-ui\nPREFLIGHT_OK=1\n' ;;
            *"head -c 2"*) printf '/app/x-ui' ;;
            *"XUI_DB_FOLDER"*) printf '/etc/x-ui/x-ui.db' ;;
            *"XUI_BIN_FOLDER"*) printf '/app/bin' ;;
            *"setting -h"*) printf '  -show\n  -port\n' ;;
            *"PRAGMA table_info(settings)"*) printf '0|id|INTEGER\n1|key|TEXT\n2|value|TEXT\n' ;;
            *"PRAGMA table_info(inbounds)"*) printf '0|id|INTEGER\n1|enable|INTEGER\n2|protocol|TEXT\n3|listen|TEXT\n4|port|INTEGER\n5|remark|TEXT\n6|stream_settings|TEXT\n' ;;
        esac
    }
    run_q() { bash -c "$1" &>/dev/null; }
    ensure_sqlite_in_container() { return 0; }
    compose() { compose_calls=$((compose_calls + 1)); return 0; }
    verify_panel_loaded() { verify_called=true; PANEL_LOAD_STATUS="backend_unreachable"; return 1; }
    SUB_MODE="none"; SUB_ENABLE_DB="false"

    assert_fail "apply_version fails and triggers auto-rollback on unhealthy UI" apply_version "v3.0.0" >/dev/null 2>&1
    assert_ok "compose.yaml.bak was created before update" test -f "$INSTALL_DIR/compose.yaml.bak"
    assert_eq "true" "$verify_called" "post-update verify_panel_loaded ran before rollback"
    assert_eq "2" "$compose_calls" "compose up -d called twice (apply + rollback)"
    assert_contains "$(< "$INSTALL_DIR/compose.yaml")" "3x-ui:v2.5.0" "compose.yaml automatically rolled back to v2.5.0"
}

test_version_classification
test_logging_and_diagnostics
test_capability_probing_and_schema_drift
test_update_safety_and_rollback

printf 'Compat tests complete: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
(( FAIL_COUNT == 0 ))
