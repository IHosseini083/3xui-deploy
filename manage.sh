#!/usr/bin/env bash
#
# 3X-UI Manager
# Deploy, harden, monitor, and manage the mhsanaei/3x-ui Xray panel via
# Docker Compose, locally or on a remote VPS over SSH.
#
# Notes:
#   * SSH_PASS is stored base64-ENCODED (obfuscation only, NOT encryption) in
#     a chmod-600 config file. Use the built-in SSH key installer to migrate to
#     key-based auth and clear any saved password.
#   * PostgreSQL support uses upstream XUI_DB_TYPE / XUI_DB_DSN with credentials
#     stored in $INSTALL_DIR/.env (chmod 600). Because 3xui runs with
#     network_mode: host, postgres binds 127.0.0.1:5432 and the DSN targets it.
#
set -uo pipefail

if [[ -z "${HOME:-}" ]]; then
    HOME=$(getent passwd "$(id -u 2>/dev/null || echo 0)" 2>/dev/null | cut -d: -f6 || true)
    if [[ -z "$HOME" && "$(id -u 2>/dev/null || echo 1)" == "0" && -d /root ]]; then
        HOME="/root"
    fi
    [[ -n "$HOME" ]] || HOME="${TMPDIR:-/tmp}"
    export HOME
fi
if [[ -z "${PATH:-}" ]]; then
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export PATH
fi

# ─── Globals & Defaults ─────────────────────────────────────────────────────
DEPLOY_VERSION="2.0.0"
REPO_SLUG="IHosseini083/3xui-deploy"
REPO_URL="https://github.com/${REPO_SLUG}"
REPO_RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}/main"
REPO_RAW_URL="${REPO_RAW_BASE}/manage.sh"
BIN_INSTALL_PATH="/usr/local/bin/3xui-deploy"

INSTALL_DIR="${XUI_INSTALL_DIR:-/opt/3x-ui}"
BACKUP_DIR="${XUI_BACKUP_DIR:-/opt/3x-ui-backups}"
CONFIG_FILE="${HOME:-/tmp}/.3xui-manager.conf"
COMPOSE_CMD=""

XUI_LOG_FILE="${XUI_LOG_FILE:-}"
XUI_DEBUG="${XUI_DEBUG:-0}"
FORCE_COMPAT=false
CURRENT_OP="init"
CURRENT_STAGE="startup"

XUI_COMPAT_MIN_VERSION="2.0.0"
XUI_COMPAT_SUPPORTED_MAJORS="2 3"
XUI_COMPAT_MAX_TESTED_MAJOR="3"
XUI_DETECTED_VERSION=""
XUI_COMPAT_STATUS=""
XUI_CAPS_BIN=""
XUI_CAPS_BIN_DIR=""
XUI_CAPS_DB_PATH=""
XUI_CAPS_SCHEMA_OK="unknown"
XUI_CAPS_FLAGS=""

_STATUS=""          # "not_deployed" | "stopped" | "running"
_SKIP_PAUSE=false
INTERACTIVE=true
AUTO_YES=false
FORCE_LOCAL=false
TUI_RESULT=-1

SSH_HOST=""
SSH_PORT="22"
SSH_USER="root"
SSH_PASS=""
SSH_KEY=""
REMOTE=false
SSH_OPTS=()
SCP_OPTS=()

PANEL_PORT="2053"
PANEL_PATH="/"
PANEL_USER="admin"
PANEL_PROTO="http"
PANEL_LISTEN=""
PANEL_DOMAIN=""
PANEL_2FA=""
PANEL_SESSION_AGE=""
PANEL_HAS_DEFAULT=""
PANEL_LOAD_STATUS=""

PROXY_ENABLED=false
PROXY_DOMAIN=""
PROXY_PORT="443"
PROXY_EMAIL=""
SUB_MODE="none"     # "none" | "same" | "dedicated"
SUB_DOMAIN=""
SUB_PORT="2096"
SUB_PATH="/sub/"
SUB_JSON_PATH="/json/"
PROXY_SUB_URL=""

DECOY_THEME="cloud"
DECOY_SITE_NAME="Meridian Cloud Systems"
DECOY_SITE_TAGLINE="Managed Edge Infrastructure & Reliability Engineering"
DECOY_CONTACT_EMAIL="hello@meridiancloud.example"

PROBE_REDIRECT_ENABLED=false
PROBE_REDIRECT_TARGET="https://www.cloudflare.com"
PROBE_REDIRECT_STATUS="302"
PROBE_FALLBACK_MODE="decoy"
PROBE_FALLBACK_URL=""
PROBE_CHECK_INTERVAL="60"
PROBE_ACTIVE_STATE="primary"
PROBE_DETECT_SCANNERS=true
PROBE_DETECT_CRAWLERS=false
PROBE_DETECT_CLI=true
PROBE_DETECT_EMPTY_UA=true
PROBE_DETECT_BAD_METHODS=true
PROBE_DETECT_PATHS=true
PROBE_CUSTOM_UA=""
PROBE_CUSTOM_PATHS=""
PROBE_BLOCK_CIDRS=""
PROBE_ALLOW_CIDRS=""

WEBPANEL_ENABLED=false
WEBPANEL_PORT="2059"
WEBPANEL_PATH="/deploy/"
WEBPANEL_USER="admin"
WEBPANEL_SESSION_IDLE="30"
WEBPANEL_BIND="127.0.0.1"
WEBPANEL_DOMAIN=""

SUB_ENABLE_DB=""
SUB_LISTEN_DB=""
SUB_DOMAIN_DB=""
SUB_PORT_DB=""
SUB_PATH_DB=""
SUB_JSON_ENABLE_DB=""
SUB_JSON_PATH_DB=""
SUB_URI_DB=""
SUB_JSON_URI_DB=""
SUB_ENCRYPT_DB=""
SUB_CERT_DB=""
SUB_KEY_DB=""
SUB_VERIFY_STATUS=""

_LEGACY_SAVED_PASS=false

# ─── Terminal Capability Detection ──────────────────────────────────────────
setup_terminal() {
    HAS_COLOR=false
    HAS_UNICODE=false

    if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 1 ]]; then
        HAS_COLOR=true
    fi

    if [[ "${LANG:-}" == *UTF-8* || "${LC_ALL:-}" == *UTF-8* || "${LC_CTYPE:-}" == *UTF-8* || "${TERM:-}" == *256color* || "${TERM:-}" == *xterm* ]]; then
        HAS_UNICODE=true
    fi

    if $HAS_COLOR; then
        RED=$'\033[0;31m'
        GREEN=$'\033[0;32m'
        YELLOW=$'\033[1;33m'
        BLUE=$'\033[0;34m'
        CYAN=$'\033[0;36m'
        MAGENTA=$'\033[0;35m'
        BOLD=$'\033[1m'
        DIM=$'\033[2m'
        REV=$'\033[7m'
        NC=$'\033[0m'
    else
        RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' REV='' NC=''
    fi

    if $HAS_UNICODE; then
        TL="╭" TR="╮" BL="╰" BR="╯" H="─" V="│"
        DOT="●"
        ARROW="→"
        MARKER="▸"
        UP="↑" DN="↓"
        BANNER_LINES=11
    else
        TL="+" TR="+" BL="+" BR="+" H="-" V="|"
        DOT="*"
        ARROW="->"
        MARKER=">"
        UP="^" DN="v"
        BANNER_LINES=6
    fi

    export RED GREEN YELLOW BLUE CYAN MAGENTA BOLD DIM REV NC
    export TL TR BL BR H V DOT ARROW MARKER UP DN
    export HAS_COLOR HAS_UNICODE BANNER_LINES
}

# ─── Logging, Quoting & Input Validation ────────────────────────────────────
_resolve_log_file() {
    if [[ -n "${XUI_LOG_FILE:-}" ]]; then
        printf '%s' "$XUI_LOG_FILE"
        return 0
    fi
    if [[ -d "${INSTALL_DIR:-/opt/3x-ui}" && -w "${INSTALL_DIR:-/opt/3x-ui}" ]]; then
        printf '%s/logs/3xui-deploy.log' "$INSTALL_DIR"
        return 0
    fi
    printf '%s/.3xui-deploy.log' "${HOME:-/tmp}"
}

_sanitize_log_text() {
    local txt="${1-}"
    txt=$(printf '%s' "$txt" | tr '\r\n\t' '   ')
    printf '%s' "$txt" | sed -E \
        -e 's/(XUI_DB_DSN=)[^[:space:]'\''"]+/\1[REDACTED]/g' \
        -e 's/(POSTGRES_PASSWORD=)[^[:space:]'\''"]+/\1[REDACTED]/g' \
        -e 's/(-password=)[^[:space:]'\''"]+/\1[REDACTED]/g' \
        -e 's/(SSH_PASS(_B64)?=)[^[:space:]'\''"]+/\1[REDACTED]/g' \
        -e 's/(SSHPASS=)[^[:space:]'\''"]+/\1[REDACTED]/g' \
        -e 's/(PG Pass[[:space:]]*:[[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
        -e 's/(Generated password[[:space:]]*:[[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
        -e 's/(WebPanel Auth[[:space:]]*:[[:space:]]*[^[:space:]]+[[:space:]]*\/[[:space:]]*)[^[:space:]]+/\1[REDACTED]/g'
}

_log_write() {
    local level="$1"
    shift
    local raw_msg="$*"
    local log_path log_dir ts safe_msg
    log_path=$(_resolve_log_file) || return 0
    [[ -n "$log_path" ]] || return 0
    log_dir=$(dirname "$log_path")
    mkdir -p "$log_dir" 2>/dev/null || return 0
    chmod 700 "$log_dir" 2>/dev/null || true

    if [[ -f "$log_path" ]]; then
        local sz=0
        sz=$(wc -c < "$log_path" 2>/dev/null || echo 0)
        if [[ "$sz" =~ ^[0-9]+$ ]] && (( sz > 5242880 )); then
            mv -f "$log_path" "${log_path}.1" 2>/dev/null || true
        fi
    fi

    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
    safe_msg=$(_sanitize_log_text "$raw_msg")
    (
        umask 077
        printf '%s [%s] [op=%s stage=%s] %s\n' \
            "$ts" "$level" "${CURRENT_OP:-init}" "${CURRENT_STAGE:-run}" "$safe_msg" >> "$log_path" 2>/dev/null || true
    )
    chmod 600 "$log_path" 2>/dev/null || true
}

log_debug() {
    _log_write "DEBUG" "$*"
    if [[ "${XUI_DEBUG:-0}" == "1" ]]; then
        echo -e "${DIM}[DEBUG]${NC} $*" >&2
    fi
}
info()     { _log_write "INFO" "$*"; echo -e "${BLUE}[INFO]${NC} $*"; }
success()  { _log_write "OK" "$*"; echo -e "${GREEN}[OK]${NC} $*"; }
warn()     { _log_write "WARN" "$*"; echo -e "${YELLOW}[WARN]${NC} $*"; }
error()    { _log_write "ERROR" "$*"; echo -e "${RED}[ERROR]${NC} $*" >&2; }
critical() { _log_write "CRITICAL" "$*"; echo -e "${RED}${BOLD}[CRITICAL]${NC} $*" >&2; }

log_stage() {
    CURRENT_OP="${1:-op}"
    CURRENT_STAGE="${2:-stage}"
    shift 2 || true
    info "[${CURRENT_OP}:${CURRENT_STAGE}] $*"
}

report_diagnostic() {
    local severity="${1:-ERROR}"
    local operation="${2:-unknown}"
    local root_cause="${3:-unspecified}"
    local components="${4:-unknown}"
    local resolution="${5:-Check logs for details}"
    local detail="${6:-}"

    case "$severity" in
        CRITICAL|critical) critical "${operation} failed" ;;
        WARN|warn)         warn "${operation} warning" ;;
        *)                 error "${operation} failed" ;;
    esac

    local out_fd=2
    [[ "$severity" == "WARN" || "$severity" == "warn" ]] && out_fd=1

    {
        printf '  Operation  : %s\n' "$operation"
        printf '  Root Cause : %s\n' "$root_cause"
        printf '  Components : %s\n' "$components"
        printf '  Resolution : %s\n' "$resolution"
        [[ -n "$detail" ]] && printf '  Details    : %s\n' "$detail"
    } >&"$out_fd"

    _log_write "$severity" "DIAG op=${operation} cause=${root_cause} components=${components} resolution=${resolution}${detail:+ detail=$detail}"
}

# Safely single-quote a string for POSIX sh / bash remote or local execution.
quote_sh() {
    local s="${1-}"
    printf "'%s'" "${s//\'/\'\\\'\'}"
}

# URL-encode bytes (RFC 3986 unreserved set preserved).
urlencode() {
    local LC_ALL=C
    local string="${1-}" out="" c i hex
    for (( i=0; i<${#string}; i++ )); do
        c="${string:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

validate_port() {
    local port="${1-}"
    [[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
}

validate_ipv4() {
    local ip="${1-}"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    (( 10#$o1 <= 255 && 10#$o2 <= 255 && 10#$o3 <= 255 && 10#$o4 <= 255 ))
}

validate_ipv6() {
    local ip="${1-}"
    [[ -n "$ip" && "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || return 1
    [[ "$ip" == *:::* ]] && return 1

    local has_dc=false left="" right=""
    if [[ "$ip" == *::* ]]; then
        has_dc=true
        left="${ip%%::*}"
        right="${ip#*::}"
        [[ "$right" == *::* ]] && return 1
        [[ "$left" == :* || "$left" == *: || "$right" == :* || "$right" == *: ]] && return 1
    else
        [[ "$ip" == :* || "$ip" == *: ]] && return 1
        left="$ip"
    fi

    local parts=() g count=0 i
    if [[ -n "$left" ]]; then
        IFS=':' read -ra parts <<< "$left"
        for (( i=0; i<${#parts[@]}; i++ )); do
            g="${parts[$i]}"
            if [[ "$g" == *.* ]]; then
                # IPv4-mapped suffix only allowed as the final segment when no right-hand side exists.
                [[ -z "$right" && $i -eq $(( ${#parts[@]} - 1 )) ]] || return 1
                validate_ipv4 "$g" || return 1
                count=$(( count + 2 ))
            else
                [[ "$g" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
                count=$(( count + 1 ))
            fi
        done
    fi

    if [[ -n "$right" ]]; then
        IFS=':' read -ra parts <<< "$right"
        for (( i=0; i<${#parts[@]}; i++ )); do
            g="${parts[$i]}"
            if [[ "$g" == *.* ]]; then
                [[ $i -eq $(( ${#parts[@]} - 1 )) ]] || return 1
                validate_ipv4 "$g" || return 1
                count=$(( count + 2 ))
            else
                [[ "$g" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
                count=$(( count + 1 ))
            fi
        done
    fi

    if $has_dc; then
        (( count <= 7 ))
    else
        (( count == 8 ))
    fi
}

validate_listen_ip() {
    local ip="${1-}"
    case "$ip" in
        ""|"0.0.0.0"|"::"|"127.0.0.1"|"::1") return 0 ;;
        *) validate_ipv4 "$ip" || validate_ipv6 "$ip" ;;
    esac
}

_format_host_port() {
    local host="${1-}" port="${2-}"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]:%s' "$host" "$port"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

validate_domain() {
    local d="${1-}"
    [[ ${#d} -le 253 && "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

validate_domain_or_ip() {
    local v="${1-}"
    validate_ipv4 "$v" || validate_ipv6 "$v" || validate_domain "$v"
}

_normalize_redirect_url() {
    local u="${1-}"
    u=$(printf '%s' "$u" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -z "$u" ]] && return 0
    if [[ "$u" != *"://"* ]]; then
        u="https://${u}"
    fi
    printf '%s' "$u"
}

validate_redirect_url() {
    local url="${1-}"
    [[ -n "$url" && ${#url} -le 512 ]] || return 1
    has_control_chars "$url" && return 1
    [[ "$url" =~ [[:space:]\"\'\{\}\;\<\>\\\`\#] ]] && return 1
    [[ "$url" =~ ^https?:// ]] || return 1

    local rest="${url#*://}"
    local authority="${rest%%/*}"
    authority="${authority%%\?*}"
    [[ -n "$authority" && "$authority" != *@* ]] || return 1

    local host="" port=""
    if [[ "$authority" =~ ^\[([0-9a-fA-F:]+)\](:([0-9]+))?$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[3]}"
        validate_ipv6 "$host" || return 1
        local hlow
        hlow=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
        [[ "$hlow" == "::" || "$hlow" == "::1" || "$hlow" == fe80:* || "$hlow" == fc* || "$hlow" == fd* ]] && return 1
    else
        host="${authority%%:*}"
        [[ "$authority" == *:* ]] && port="${authority#*:}"
        [[ -n "$host" ]] || return 1
        local hlow
        hlow=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
        case "$hlow" in
            localhost|*.localhost|*.local|*.internal) return 1 ;;
        esac
        if validate_ipv4 "$host"; then
            _is_private_ipv4 "$host" && return 1
            [[ "$host" == 0.* ]] && return 1
        elif ! validate_domain "$host"; then
            return 1
        fi
    fi

    if [[ -n "$port" ]]; then
        validate_port "$port" || return 1
    fi
    return 0
}

validate_cidr_entry() {
    local item="${1-}"
    [[ -n "$item" ]] || return 1
    local addr="$item" prefix=""
    if [[ "$item" == */* ]]; then
        addr="${item%%/*}"
        prefix="${item#*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    fi
    if validate_ipv4 "$addr"; then
        [[ -z "$prefix" ]] || (( 10#$prefix >= 0 && 10#$prefix <= 32 ))
    elif validate_ipv6 "$addr"; then
        [[ -z "$prefix" ]] || (( 10#$prefix >= 0 && 10#$prefix <= 128 ))
    else
        return 1
    fi
}

validate_cidr_csv() {
    local csv="${1-}"
    [[ -z "$csv" ]] && return 0
    local part trimmed
    local IFS=','
    for part in $csv; do
        trimmed=$(printf '%s' "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ -z "$trimmed" ]] && continue
        validate_cidr_entry "$trimmed" || return 1
    done
    return 0
}

validate_email() {
    local e="${1-}"
    [[ ${#e} -le 254 && "$e" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

validate_tag() {
    local t="${1-}"
    [[ "$t" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]
}

validate_webpath() {
    local p="${1-}"
    [[ -n "$p" && ${#p} -le 128 ]] || return 1
    [[ "$p" == *".."* || "$p" == *"//"* ]] && return 1
    [[ "$p" =~ ^/[a-zA-Z0-9/_-]*$ ]]
}

validate_pg_ident() {
    local id="${1-}"
    [[ "$id" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,62}$ ]]
}

validate_ssh_host() {
    local h="${1-}"
    [[ -n "$h" && "$h" =~ ^[a-zA-Z0-9._:-]+$ ]]
}

validate_ssh_user() {
    local u="${1-}"
    [[ -n "$u" && "$u" =~ ^[a-zA-Z0-9._-]+$ ]]
}

validate_abs_path() {
    local p="${1-}"
    [[ -n "$p" && "$p" == /* ]] || return 1
    has_control_chars "$p" && return 1
    [[ ! "$p" =~ (^|/)\.\.(/|$) ]]
}

validate_safe_dir() {
    local p="${1-}"
    validate_abs_path "$p" || return 1
    local norm="$p"
    while [[ "$norm" == */ && "$norm" != "/" ]]; do
        norm="${norm%/}"
    done
    case "$norm" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            return 1 ;;
    esac
    return 0
}

validate_strong_password() {
    local pw="${1-}"
    [[ -n "$pw" ]] || return 1
    has_control_chars "$pw" && return 1
    (( ${#pw} >= 12 )) || return 1
    local lower
    lower=$(printf '%s' "$pw" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        admin|password|123456|12345678|3x-ui|root|password1234|123456789012)
            return 1 ;;
    esac
    local classes=0
    [[ "$pw" =~ [a-z] ]] && classes=$(( classes + 1 ))
    [[ "$pw" =~ [A-Z] ]] && classes=$(( classes + 1 ))
    [[ "$pw" =~ [0-9] ]] && classes=$(( classes + 1 ))
    [[ "$pw" =~ [^a-zA-Z0-9] ]] && classes=$(( classes + 1 ))
    (( ${#pw} >= 16 || classes >= 2 ))
}

has_control_chars() {
    local s="${1-}"
    # Note: do NOT match $'\0' directly in bash (expands to empty string and makes *""* match everything).
    [[ "$s" == *[$'\x01'-$'\x1f'$'\x7f']* ]]
}

generate_random_string() {
    local length="${1:-16}"
    [[ "$length" =~ ^[0-9]+$ ]] && (( length > 0 )) || length=16
    local out="" chunk="" iter=0
    # Use dd + tr (never head) so tr never trips SIGPIPE under set -o pipefail.
    while (( ${#out} < length && iter < 8 )); do
        chunk=$(dd if=/dev/urandom bs=2048 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' || true)
        out+="$chunk"
        iter=$(( iter + 1 ))
    done
    printf '%s' "${out:0:$length}"
}

get_ip() {
    local ip=""
    if command -v hostname &>/dev/null; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    if [[ -z "$ip" ]] && command -v ip &>/dev/null; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
    fi
    printf '%s' "${ip:-127.0.0.1}"
}

_is_private_ipv4() {
    local ip="${1-}"
    [[ "$ip" =~ ^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.) ]]
}

get_target_ip() {
    if $REMOTE; then
        printf '%s' "$SSH_HOST"
        return 0
    fi
    local ip=""
    ip=$(get_ip)
    if { [[ -z "$ip" ]] || _is_private_ipv4 "$ip"; } && command -v curl &>/dev/null; then
        local pub
        pub=$(curl -4fsS --proto '=https' --tlsv1.2 --max-time 2 https://api.ipify.org 2>/dev/null || true)
        validate_ipv4 "$pub" && ip="$pub"
    fi
    printf '%s' "${ip:-127.0.0.1}"
}

clear_screen() {
    if [[ -t 1 ]]; then
        command -v clear &>/dev/null && clear || printf '\033[2J\033[H'
    else
        echo ""
    fi
}

hide_cursor() { [[ -t 1 ]] && printf '\e[?25l'; }
show_cursor() { [[ -t 1 ]] && printf '\e[?25h'; }

cleanup() { show_cursor; }
trap cleanup EXIT

# ─── TUI Engine ─────────────────────────────────────────────────────────────
print_banner() {
    [[ -z "$_STATUS" ]] && refresh_status

    local status_text
    case "$_STATUS" in
        running)      status_text="${GREEN}${DOT} running${NC}" ;;
        stopped)      status_text="${YELLOW}${DOT} stopped${NC}" ;;
        not_deployed) status_text="${DIM}${DOT} not deployed${NC}" ;;
        *)            status_text="${DIM}${DOT} unknown${NC}" ;;
    esac

    local conn_label="local"
    $REMOTE && conn_label="${SSH_USER}@${SSH_HOST}:${SSH_PORT}"

    if $HAS_UNICODE; then
        printf '%b' "${CYAN}${BOLD}"
        cat <<'EOF'
  ██████╗ ██╗  ██╗       ██╗   ██╗██╗
  ╚════██╗╚██╗██╔╝       ██║   ██║██║
   █████╔╝ ╚███╔╝  █████╗██║   ██║██║
   ╚═══██╗ ██╔██╗  ╚════╝██║   ██║██║
  ██████╔╝██╔╝ ██╗       ╚██████╔╝██║
  ╚═════╝ ╚═╝  ╚═╝        ╚═════╝ ╚═╝
EOF
        echo -e "${NC}${DIM}  Xray panel · Docker deployment manager · v${DEPLOY_VERSION}${NC}"
    else
        echo -e "${CYAN}${BOLD}  3X-UI MANAGER${NC}"
        echo -e "${DIM}  Xray panel · Docker deployment manager · v${DEPLOY_VERSION}${NC}"
    fi

    echo ""
    printf "  ${DIM}%-8s${NC}${BOLD}%s${NC}\n" "target" "$conn_label"
    printf "  ${DIM}%-8s${NC}%b\n" "status" "$status_text"
    echo ""
}

# Helper: find the Nth (1-based) selectable option index (skipping "--- " headers).
_tui_nth_selectable() {
    local target_n="$1"
    shift
    local count=0 i=0 opt
    for opt in "$@"; do
        if [[ "$opt" != "--- "* ]]; then
            count=$(( count + 1 ))
            if (( count == target_n )); then
                echo "$i"
                return 0
            fi
        fi
        i=$(( i + 1 ))
    done
    return 1
}

# Generic arrow-key TUI select.
# Usage: tui_select "Title" "Header Text" "Opt1" "Opt2" "--- HEADER ---" "Opt3"
# Sets TUI_RESULT (0-based index, or -1 on quit/back) and returns index (or 255).
tui_select() {
    local title="$1"
    local header_text="$2"
    shift 2
    local options=("$@")
    local count=${#options[@]}
    local selected=0
    local window_start=0

    TUI_RESULT=-1
    (( count == 0 )) && return 255

    while [[ "${options[$selected]:-}" == "--- "* ]]; do
        selected=$(( selected + 1 ))
        if (( selected >= count )); then
            selected=0
            break
        fi
    done

    hide_cursor
    trap 'TUI_RESULT=-1; show_cursor; trap - INT TERM; return 255' INT TERM

    while true; do
        clear_screen
        print_banner

        local term_h
        term_h=$(tput lines 2>/dev/null || { stty size 2>/dev/null | awk '{print $1}'; } || echo 24)
        [[ "$term_h" =~ ^[0-9]+$ ]] || term_h=24

        local header_lines=0
        if [[ -n "$header_text" ]]; then
            header_lines=$(printf '%b\n' "$header_text" | wc -l)
            header_lines=$(( header_lines + 1 )) # trailing blank line
        fi
        local title_lines=0
        [[ -n "$title" ]] && title_lines=2

        local fixed_lines=$(( BANNER_LINES + title_lines + header_lines + 3 ))
        local max_opts=$(( term_h - fixed_lines - 1 ))
        (( max_opts < 4 )) && max_opts=4
        (( max_opts > count )) && max_opts=$count

        if (( selected < window_start )); then
            window_start=$selected
        elif (( selected >= window_start + max_opts )); then
            window_start=$(( selected - max_opts + 1 ))
        fi

        if [[ -n "$title" ]]; then
            echo -e "  ${BOLD}${MAGENTA}${title}${NC}"
            echo -e "  ${DIM}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${NC}"
        fi

        if [[ -n "$header_text" ]]; then
            echo -e "$header_text\n"
        fi

        local i idx opt
        for (( i=0; i<max_opts; i++ )); do
            idx=$(( window_start + i ))
            if (( idx < count )); then
                opt="${options[$idx]}"
                if [[ "$opt" == "--- "* ]]; then
                    local header_label="${opt//--- /}"
                    header_label="${header_label// ---/}"
                    echo -e "  ${DIM}${BOLD}${header_label}${NC}"
                elif (( idx == selected )); then
                    echo -e "  ${CYAN}${BOLD}${MARKER} ${opt}${NC}"
                else
                    echo -e "    ${opt}"
                fi
            else
                echo ""
            fi
        done

        local more_above="" more_below=""
        (( window_start > 0 )) && more_above="${DIM}${UP} more${NC}"
        (( window_start + max_opts < count )) && more_below="${DIM}${DN} more${NC}"

        echo ""
        printf "  ${DIM}%s${NC}  ${DIM}%s${NC}\n" "$more_above" "$more_below"
        echo -e "  ${DIM}${UP}/${DN}/j/k move · 1-9 jump · Enter select · q/Esc back${NC}"

        local key="" c="" seq="" direction=0 page_step=0
        if ! IFS= read -rsn1 key 2>/dev/null; then
            TUI_RESULT=-1
            show_cursor; trap - INT TERM; return 255
        fi

        if [[ "$key" == $'\e' ]]; then
            if ! IFS= read -rsn1 -t 0.05 c 2>/dev/null; then
                TUI_RESULT=-1
                show_cursor; trap - INT TERM; return 255
            fi
            seq="$c"
            if [[ "$c" == "[" || "$c" == "O" ]]; then
                local k=0
                while (( k < 6 )); do
                    IFS= read -rsn1 -t 0.02 c 2>/dev/null || break
                    seq+="$c"
                    [[ "$c" =~ [A-Za-z~] ]] && break
                    k=$(( k + 1 ))
                done
            fi
            case "$seq" in
                "[A"|"OA") direction=-1 ;;
                "[B"|"OB") direction=1 ;;
                "[5~")     page_step=$(( -max_opts )) ;;
                "[6~")     page_step=$max_opts ;;
                "[H"|"OH"|"[1~")
                    selected=0
                    while [[ "${options[$selected]:-}" == "--- "* ]] && (( selected + 1 < count )); do
                        selected=$(( selected + 1 ))
                    done
                    ;;
                "[F"|"OF"|"[4~")
                    selected=$(( count - 1 ))
                    while [[ "${options[$selected]:-}" == "--- "* ]] && (( selected > 0 )); do
                        selected=$(( selected - 1 ))
                    done
                    ;;
            esac
        elif [[ "$key" == "k" ]]; then
            direction=-1
        elif [[ "$key" == "j" ]]; then
            direction=1
        elif [[ "$key" == "g" ]]; then
            selected=0
            while [[ "${options[$selected]:-}" == "--- "* ]] && (( selected + 1 < count )); do
                selected=$(( selected + 1 ))
            done
        elif [[ "$key" == "G" ]]; then
            selected=$(( count - 1 ))
            while [[ "${options[$selected]:-}" == "--- "* ]] && (( selected > 0 )); do
                selected=$(( selected - 1 ))
            done
        elif [[ "$key" =~ ^[1-9]$ ]]; then
            local jump_idx
            if jump_idx=$(_tui_nth_selectable "$key" "${options[@]}"); then
                selected=$jump_idx
            fi
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then
            TUI_RESULT=-1
            show_cursor; trap - INT TERM; return 255
        elif [[ -z "$key" ]]; then
            TUI_RESULT=$selected
            show_cursor; trap - INT TERM
            (( selected < 255 )) && return "$selected" || return 254
        fi

        if (( page_step != 0 )); then
            selected=$(( selected + page_step ))
            (( selected < 0 )) && selected=0
            (( selected >= count )) && selected=$(( count - 1 ))
            local step_dir=1
            (( page_step < 0 )) && step_dir=-1
            while [[ "${options[$selected]:-}" == "--- "* ]]; do
                selected=$(( selected + step_dir ))
                if (( selected < 0 )); then selected=0; step_dir=1; fi
                if (( selected >= count )); then selected=$(( count - 1 )); step_dir=-1; fi
            done
        elif (( direction != 0 )); then
            selected=$(( selected + direction ))
            local guard=0
            while (( guard < count + 2 )); do
                if (( selected < 0 )); then
                    selected=$(( count - 1 ))
                elif (( selected >= count )); then
                    selected=0
                fi
                if [[ "${options[$selected]}" == "--- "* ]]; then
                    selected=$(( selected + direction ))
                    guard=$(( guard + 1 ))
                else
                    break
                fi
            done
        fi
    done
}

confirm() {
    local prompt="${1:-Are you sure?}"
    $AUTO_YES && return 0
    echo ""
    local choice=""
    read -rp "  ${prompt} [y/N]: " choice
    [[ "$choice" =~ ^[Yy]$ ]]
}

# ─── SSH Multiplexing & Execution Helpers ───────────────────────────────────
get_mux_dir() {
    local base="${XDG_RUNTIME_DIR:-$HOME/.ssh}"
    local mux_dir="${base}/3xui_mux"
    mkdir -p "$mux_dir" 2>/dev/null || true
    chmod 700 "$mux_dir" 2>/dev/null || true
    printf '%s' "$mux_dir"
}

get_mux_path() {
    printf '%s/mux-%%C' "$(get_mux_dir)"
}

get_ssh_opts() {
    SSH_OPTS=(
        -o ControlMaster=auto
        -o "ControlPath=$(get_mux_path)"
        -o ControlPersist=15m
        -o ConnectTimeout=10
        -o ServerAliveInterval=30
        -o ServerAliveCountMax=3
        -o StrictHostKeyChecking=accept-new
        -o ForwardAgent=no
        -o ForwardX11=no
        -o ClearAllForwardings=yes
    )
    if [[ -n "${SSH_KEY:-}" && -f "${SSH_KEY:-}" ]]; then
        SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
    fi
    [[ "${SSH_PORT:-22}" != "22" ]] && SSH_OPTS+=(-p "$SSH_PORT")
}

get_scp_opts() {
    SCP_OPTS=(
        -o ControlMaster=auto
        -o "ControlPath=$(get_mux_path)"
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new
        -o ForwardAgent=no
        -o ForwardX11=no
        -o ClearAllForwardings=yes
    )
    if [[ -n "${SSH_KEY:-}" && -f "${SSH_KEY:-}" ]]; then
        SCP_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
    fi
    [[ "${SSH_PORT:-22}" != "22" ]] && SCP_OPTS+=(-P "$SSH_PORT")
}

ssh_cmd() {
    get_ssh_opts
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$@"
}

ssh_cmd_interactive() {
    get_ssh_opts
    ssh "${SSH_OPTS[@]}" -t "${SSH_USER}@${SSH_HOST}" "$@"
}

_scp_host() {
    if [[ "$SSH_HOST" == *:* ]]; then
        printf '[%s]' "$SSH_HOST"
    else
        printf '%s' "$SSH_HOST"
    fi
}

ssh_copy() {
    local src="$1" dst="$2"
    get_scp_opts
    scp "${SCP_OPTS[@]}" "$src" "${SSH_USER}@$(_scp_host):${dst}"
}

ssh_download() {
    local remote_src="$1" local_dst="$2"
    get_scp_opts
    scp "${SCP_OPTS[@]}" "${SSH_USER}@$(_scp_host):${remote_src}" "$local_dst"
}

run() {
    if $REMOTE; then
        ssh_cmd "$@" || { error "Remote command failed: $1"; return 1; }
    else
        bash -c "$1" || { error "Command failed: $1"; return 1; }
    fi
}

# Run command without echoing the command text on failure (safe for secrets).
run_masked() {
    local desc="$1"
    shift
    if $REMOTE; then
        ssh_cmd "$@" || { error "$desc failed"; return 1; }
    else
        bash -c "$1" || { error "$desc failed"; return 1; }
    fi
}

run_out() {
    if $REMOTE; then
        ssh_cmd "$@" 2>/dev/null
    else
        bash -c "$1" 2>/dev/null
    fi
}

run_it() {
    if $REMOTE; then
        ssh_cmd_interactive "$@" || true
    else
        bash -c "$1" || true
    fi
}

run_q() {
    if $REMOTE; then
        ssh_cmd "$@" &>/dev/null
    else
        bash -c "$1" &>/dev/null
    fi
}

invalidate_status() {
    _STATUS=""
    XUI_DETECTED_VERSION=""
    XUI_CAPS_BIN=""
    XUI_CAPS_BIN_DIR=""
    XUI_CAPS_DB_PATH=""
    XUI_CAPS_SCHEMA_OK="unknown"
    XUI_CAPS_FLAGS=""
}

refresh_status() {
    if is_deployed; then
        is_running && _STATUS="running" || _STATUS="stopped"
    else
        _STATUS="not_deployed"
    fi
}

# ─── Config Persistence (No shell sourcing) ─────────────────────────────────
_file_mode_uid() {
    local f="$1"
    stat -c '%a %u' "$f" 2>/dev/null || stat -f '%Lp %u' "$f" 2>/dev/null || true
}

load_config() {
    _LEGACY_SAVED_PASS=false
    [[ -f "$CONFIG_FILE" ]] || return 0
    if [[ -L "$CONFIG_FILE" ]]; then
        warn "Refusing to load symlinked config file: $CONFIG_FILE"
        return 0
    fi

    local meta f_mode="" f_uid="" my_uid=""
    meta=$(_file_mode_uid "$CONFIG_FILE")
    if [[ -n "$meta" ]]; then
        read -r f_mode f_uid <<< "$meta"
        my_uid=$(id -u 2>/dev/null || printf '%s' "${EUID:-0}")
        if [[ "$f_uid" =~ ^[0-9]+$ && "$my_uid" =~ ^[0-9]+$ ]] && (( f_uid != my_uid )); then
            warn "Refusing to load $CONFIG_FILE (not owned by current user)"
            return 0
        fi
        if [[ "$f_mode" =~ ^[0-7]+$ ]]; then
            local oct_mode=$(( 8#$f_mode ))
            if (( (oct_mode & 0002) != 0 )); then
                warn "Refusing to load world-writable $CONFIG_FILE (run: chmod 600 $CONFIG_FILE)"
                return 0
            fi
            if (( (oct_mode & 0077) != 0 )); then
                chmod 600 "$CONFIG_FILE" 2>/dev/null || true
            fi
        fi
    fi

    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            if [[ "$val" =~ ^\"(.*)\"$ ]]; then
                val="${BASH_REMATCH[1]}"
            elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            case "$key" in
                SSH_HOST) validate_ssh_host "$val" && SSH_HOST="$val" ;;
                SSH_PORT) validate_port "$val" && SSH_PORT="$val" ;;
                SSH_USER) validate_ssh_user "$val" && SSH_USER="$val" ;;
                SSH_KEY)
                    ! has_control_chars "$val" && SSH_KEY="$val"
                    ;;
                SSH_PASS_B64)
                    if [[ -n "$val" ]]; then
                        _LEGACY_SAVED_PASS=true
                        SSH_PASS=$(printf '%s' "$val" | base64 -d 2>/dev/null \
                            || printf '%s' "$val" | base64 --decode 2>/dev/null \
                            || printf '%s' "$val" | base64 -D 2>/dev/null || true)
                    fi
                    ;;
            esac
        fi
    done < "$CONFIG_FILE"
}

save_config() {
    local persist_pass="${1:-false}"
    local enc_pass=""
    if [[ "$persist_pass" == "true" && -n "${SSH_PASS:-}" ]]; then
        enc_pass=$(printf '%s' "$SSH_PASS" | base64 | tr -d '\n\r')
    fi

    (
        umask 077
        printf 'SSH_HOST="%s"\nSSH_PORT="%s"\nSSH_USER="%s"\nSSH_KEY="%s"\nSSH_PASS_B64="%s"\n' \
            "${SSH_HOST//\"/}" "${SSH_PORT//\"/}" "${SSH_USER//\"/}" "${SSH_KEY//\"/}" "$enc_pass" > "$CONFIG_FILE"
    )
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    [[ -z "$enc_pass" ]] && _LEGACY_SAVED_PASS=false
    success "Saved connection configuration to $CONFIG_FILE"
}

check_sshpass() {
    command -v sshpass &>/dev/null && return 0
    info "Installing sshpass for automated password logins..."
    if [[ $EUID -eq 0 ]] && command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq sshpass 2>/dev/null
    elif command -v brew &>/dev/null; then
        brew install sshpass 2>/dev/null
    elif [[ $EUID -eq 0 ]] && command -v apk &>/dev/null; then
        apk add --no-cache sshpass 2>/dev/null
    elif [[ $EUID -eq 0 ]] && command -v dnf &>/dev/null; then
        dnf install -y sshpass 2>/dev/null
    elif [[ $EUID -eq 0 ]] && command -v yum &>/dev/null; then
        yum install -y sshpass 2>/dev/null
    elif [[ $EUID -eq 0 ]] && command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm sshpass 2>/dev/null
    fi
    command -v sshpass &>/dev/null
}

is_ssh_mux_active() {
    [[ -n "${SSH_HOST:-}" && -n "${SSH_USER:-}" ]] || return 1
    get_ssh_opts
    ssh -O check "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" &>/dev/null
}

close_ssh_mux() {
    if [[ -n "${SSH_HOST:-}" && -n "${SSH_USER:-}" ]]; then
        get_ssh_opts
        ssh -O exit "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" &>/dev/null || true
    fi
}

init_master_connection() {
    validate_ssh_host "${SSH_HOST:-}" || { error "Invalid SSH host"; return 1; }
    validate_ssh_user "${SSH_USER:-}" || { error "Invalid SSH user"; return 1; }
    validate_port "${SSH_PORT:-22}"   || { error "Invalid SSH port"; return 1; }

    if is_ssh_mux_active; then
        return 0
    fi

    info "Establishing persistent SSH connection to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}..."
    get_ssh_opts

    # 1. Try SSH key auth (BatchMode prevents hanging on prompts).
    if ssh -fNM "${SSH_OPTS[@]}" -o BatchMode=yes "${SSH_USER}@${SSH_HOST}" 2>/dev/null; then
        success "Connected via SSH keys."
        return 0
    fi

    # 2. Try saved password via SSHPASS env var (never expose password in argv).
    if [[ -n "${SSH_PASS:-}" ]]; then
        if check_sshpass; then
            if SSHPASS="$SSH_PASS" sshpass -e ssh -fNM "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" 2>/dev/null; then
                success "Connected using saved password."
                return 0
            else
                warn "Authentication with saved password failed."
                SSH_PASS=""
            fi
        else
            warn "sshpass unavailable; falling back to native SSH prompt."
        fi
    fi

    # 3. Interactive password auth (prefer sshpass -e if available, else native ssh).
    if command -v sshpass &>/dev/null || check_sshpass; then
        echo ""
        read -rs -p "  VPS password for ${SSH_USER}@${SSH_HOST}: " SSH_PASS
        echo ""
        if [[ -n "$SSH_PASS" ]] && SSHPASS="$SSH_PASS" sshpass -e ssh -fNM "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" 2>/dev/null; then
            success "Connected successfully."
            return 0
        fi
    else
        info "Enter password for ${SSH_USER}@${SSH_HOST}:"
        if ssh -fNM "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}"; then
            success "Connected successfully."
            return 0
        fi
    fi

    error "Failed to connect to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
    return 1
}

setup_ssh() {
    clear_screen
    print_banner
    echo -e "  ${BOLD}Connect to Remote VPS${NC}\n"

    if [[ -n "${SSH_HOST:-}" && -n "${SSH_USER:-}" ]]; then
        echo -e "  Saved connection: ${BOLD}${SSH_USER}@${SSH_HOST}:${SSH_PORT}${NC}"
        if confirm "Reuse this connection?"; then
            if init_master_connection; then
                REMOTE=true
                save_config
                invalidate_status
                return 0
            fi
            warn "Saved connection failed. Configure a new target."
        fi
    fi

    echo ""
    local input_host input_user input_port input_key
    read -rp "  VPS IP / hostname: " input_host
    [[ -n "$input_host" ]] && SSH_HOST="$input_host"
    if ! validate_ssh_host "${SSH_HOST:-}"; then
        error "Valid host required"
        return 1
    fi

    read -rp "  SSH user [${SSH_USER:-root}]: " input_user
    [[ -n "$input_user" ]] && SSH_USER="$input_user"
    SSH_USER="${SSH_USER:-root}"
    if ! validate_ssh_user "$SSH_USER"; then
        error "Invalid SSH user: $SSH_USER"
        return 1
    fi

    read -rp "  SSH port [${SSH_PORT:-22}]: " input_port
    [[ -n "$input_port" ]] && SSH_PORT="$input_port"
    SSH_PORT="${SSH_PORT:-22}"
    if ! validate_port "$SSH_PORT"; then
        error "Invalid SSH port: $SSH_PORT"
        return 1
    fi

    read -rp "  SSH private key path (optional) [${SSH_KEY:-none}]: " input_key
    if [[ -n "$input_key" ]]; then
        input_key="${input_key/#\~/$HOME}"
        if [[ -f "$input_key" ]]; then
            SSH_KEY="$input_key"
        else
            warn "Key file not found ($input_key); continuing without custom key."
        fi
    fi

    SSH_PASS=""
    close_ssh_mux

    if init_master_connection; then
        REMOTE=true
        save_config
        [[ -n "${SSH_PASS:-}" ]] && info "SSH password is kept in memory for this session only (not saved to $CONFIG_FILE)."
        invalidate_status
        return 0
    fi

    return 1
}

install_ssh_key() {
    if ! $REMOTE; then
        warn "Connect to a remote VPS first."
        return 1
    fi

    local pubkey="" candidate
    for candidate in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
        if [[ -f "$candidate" ]]; then
            pubkey="$candidate"
            break
        fi
    done

    if [[ -z "$pubkey" ]]; then
        info "No local SSH public key found in ~/.ssh/"
        confirm "Generate a new Ed25519 SSH key pair?" || return 0
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        if confirm "Protect new SSH private key with a passphrase? (recommended)"; then
            ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" || { error "ssh-keygen failed"; return 1; }
        else
            ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" || { error "ssh-keygen failed"; return 1; }
        fi
        chmod 600 "$HOME/.ssh/id_ed25519" 2>/dev/null || true
        pubkey="$HOME/.ssh/id_ed25519.pub"
    fi

    info "Installing public key $(basename "$pubkey") to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}..."
    local pub_content
    pub_content=$(< "$pubkey")
    [[ -z "$pub_content" ]] && { error "Public key file is empty"; return 1; }

    run "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF $(quote_sh "$pub_content") ~/.ssh/authorized_keys || printf '%s\n' $(quote_sh "$pub_content") >> ~/.ssh/authorized_keys" \
        || { error "Failed to install public key"; return 1; }

    # Verify key-only login works cleanly before removing stored password.
    local test_opts=(
        -o BatchMode=yes
        -o ControlMaster=no
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new
        -i "${pubkey%.pub}"
    )
    [[ "$SSH_PORT" != "22" ]] && test_opts+=(-p "$SSH_PORT")

    if ssh "${test_opts[@]}" "${SSH_USER}@${SSH_HOST}" "true" 2>/dev/null; then
        SSH_KEY="${pubkey%.pub}"
        SSH_PASS=""
        close_ssh_mux
        save_config
        init_master_connection || true
        success "SSH key authentication verified and saved password cleared!"
    else
        warn "Public key installed, but BatchMode verification failed (check remote sshd_config PubkeyAuthentication)."
    fi
}

manage_ssh() {
    while true; do
        local mux_state="disconnected"
        is_ssh_mux_active && mux_state="${GREEN}connected${NC}" || mux_state="${DIM}disconnected${NC}"
        local auth_mode="none"
        [[ -n "${SSH_KEY:-}" ]] && auth_mode="key (${SSH_KEY})"
        if $_LEGACY_SAVED_PASS; then
            auth_mode="${auth_mode}, legacy saved password"
        elif [[ -n "${SSH_PASS:-}" ]]; then
            auth_mode="${auth_mode}, session password (memory only)"
        fi

        local header_text
        if $REMOTE; then
            header_text="  Mode      : ${BOLD}Remote${NC} (${SSH_USER}@${SSH_HOST}:${SSH_PORT})\n  Master Mux: ${mux_state}\n  Auth      : ${auth_mode}"
        else
            header_text="  Mode      : ${BOLD}Local${NC} (this machine)\n  Saved VPS : ${SSH_USER:-none}@${SSH_HOST:-none}:${SSH_PORT:-22}"
        fi
        if $_LEGACY_SAVED_PASS; then
            header_text+="\n  ${YELLOW}! Legacy SSH_PASS_B64 found in config — migrate to SSH keys to clear it!${NC}"
        fi

        local opts=(
            "Connect / Switch Remote VPS"
            "Switch to Local mode"
            "Install SSH public key & clear saved password"
            "Close active SSH master connection"
            "Clear saved SSH config & credentials"
            "Back"
        )

        tui_select "Target & SSH Manager" "$header_text" "${opts[@]}"
        local sub=$?
        clear_screen
        case "$sub" in
            0)
                setup_ssh || true
                ;;
            1)
                close_ssh_mux
                REMOTE=false
                COMPOSE_CMD=""
                invalidate_status
                success "Switched to local execution mode"
                ;;
            2)
                install_ssh_key || true
                ;;
            3)
                close_ssh_mux
                success "SSH master connection closed"
                ;;
            4)
                if confirm "Delete $CONFIG_FILE and clear saved SSH credentials?"; then
                    close_ssh_mux
                    rm -f "$CONFIG_FILE"
                    SSH_HOST="" SSH_PORT="22" SSH_USER="root" SSH_PASS="" SSH_KEY=""
                    REMOTE=false
                    COMPOSE_CMD=""
                    invalidate_status
                    success "Saved SSH config cleared"
                fi
                ;;
            5|255)
                _SKIP_PAUSE=true
                return
                ;;
        esac
        echo ""
        read -rp "  Press Enter..."
    done
}

# ─── Prerequisites & Docker Compose Helpers ─────────────────────────────────
is_deployed()   { run_q "test -f $(quote_sh "$INSTALL_DIR/compose.yaml")"; }
is_running()    { run_q "docker ps --format '{{.Names}}' | grep -q '^3xui_app$'"; }
is_pg_running() { run_q "docker ps --format '{{.Names}}' | grep -q '^3xui_postgres$'"; }
is_caddy_running() { run_q "docker ps --format '{{.Names}}' | grep -q '^3xui_caddy$'"; }

detect_compose() {
    [[ -n "$COMPOSE_CMD" ]] && return 0
    if run_q "docker compose version"; then
        COMPOSE_CMD="docker compose"
    elif run_q "command -v docker-compose"; then
        COMPOSE_CMD="docker-compose"
    else
        return 1
    fi
}

compose() {
    if [[ -z "$COMPOSE_CMD" ]]; then
        detect_compose || { error "Docker Compose not found"; return 1; }
    fi
    local args="" a
    for a in "$@"; do
        args+=" $(quote_sh "$a")"
    done
    run "cd $(quote_sh "$INSTALL_DIR") && $COMPOSE_CMD$args"
}

ensure_docker() {
    if run_q "command -v docker"; then
        success "Docker already installed"
    else
        if $INTERACTIVE && ! $AUTO_YES; then
            confirm "Docker not found. Download and run official installer (https://get.docker.com)?" || return 1
        fi
        info "Installing Docker via get.docker.com..."
        run "s=\$(mktemp /tmp/get-docker.XXXXXX.sh) && chmod 700 \"\$s\" && curl -fsSL --proto '=https' --tlsv1.2 https://get.docker.com -o \"\$s\" && [ -s \"\$s\" ] && sh \"\$s\"; rc=\$?; rm -f \"\$s\"; exit \$rc" \
            || { error "Docker installation failed"; return 1; }
        run_q "command -v systemctl" && run "systemctl enable --now docker" || true
        success "Docker installed"
    fi

    if ! run_q "docker compose version" && ! run_q "command -v docker-compose"; then
        info "Installing Docker Compose plugin..."
        if run_q "command -v apt-get"; then
            run "apt-get update -qq && apt-get install -y -qq docker-compose-plugin" || warn "Could not install compose plugin via apt-get"
        elif run_q "command -v dnf"; then
            run "dnf install -y docker-compose-plugin" || warn "Could not install compose plugin via dnf"
        elif run_q "command -v apk"; then
            run "apk add --no-cache docker-cli-compose" || warn "Could not install compose plugin via apk"
        else
            warn "Automatic Compose plugin install is only supported on apt/dnf/apk systems."
        fi
    fi

    detect_compose || { error "Docker Compose not available after install"; return 1; }
}

require_deployed() {
    is_deployed || { error "Not deployed. Run deploy first."; return 1; }
    run_q "command -v docker" || { error "Docker not installed. Run deploy first."; return 1; }
    detect_compose || { error "Docker Compose not found"; return 1; }
}

require_running() {
    is_running || { error "Container 3xui_app is not running."; return 1; }
}

# Read Postgres user/db from $INSTALL_DIR/.env or compose.yaml (defaults: xui / xui).
get_pg_env() {
    PG_USER="xui"
    PG_DB="xui"
    local env_raw
    env_raw=$(run_out "cat $(quote_sh "$INSTALL_DIR/.env")" || true)
    if [[ -n "$env_raw" ]]; then
        local u d
        u=$(printf '%s\n' "$env_raw" | awk -F= '/^POSTGRES_USER=/{print $2; exit}' | tr -d '"'\''\r')
        d=$(printf '%s\n' "$env_raw" | awk -F= '/^POSTGRES_DB=/{print $2; exit}' | tr -d '"'\''\r')
        validate_pg_ident "$u" && PG_USER="$u"
        validate_pg_ident "$d" && PG_DB="$d"
    fi
}

_is_postgres_backend() {
    is_pg_running || run_q "grep -q 'XUI_DB_TYPE:[[:space:]]*\"postgres\"' $(quote_sh "$INSTALL_DIR/compose.yaml")"
}

ensure_sqlite_in_container() {
    run_q "docker exec 3xui_app sh -c 'command -v sqlite3 >/dev/null 2>&1'" && return 0
    info "Installing sqlite3 in container for database configuration..."
    run_q "docker exec 3xui_app sh -c 'if command -v apk >/dev/null 2>&1; then apk update >/dev/null 2>&1 && apk add --no-cache sqlite >/dev/null 2>&1; elif command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq sqlite3 >/dev/null 2>&1; else exit 1; fi'" \
        || return 1
}

_xui_detect_db_path() {
    if [[ -n "${XUI_CAPS_DB_PATH:-}" ]]; then
        printf '%s' "$XUI_CAPS_DB_PATH"
        return 0
    fi
    local detected=""
    if is_running; then
        detected=$(run_out "docker exec 3xui_app sh -c 'd=\${XUI_DB_FOLDER:-/etc/x-ui}; if [ -f \"\$d/x-ui.db\" ]; then printf \"%s\" \"\$d/x-ui.db\"; else ls \"\$d\"/*.db 2>/dev/null | head -n 1; fi'" || true)
    fi
    XUI_CAPS_DB_PATH="${detected:-/etc/x-ui/x-ui.db}"
    printf '%s' "$XUI_CAPS_DB_PATH"
}

_xui_host_db_path() {
    local cdb base
    cdb=$(_xui_detect_db_path)
    base=$(basename "$cdb")
    if [[ -n "$base" && "$base" != "." && "$base" != "/" ]]; then
        printf '%s/db/%s' "$INSTALL_DIR" "$base"
    else
        printf '%s/db/x-ui.db' "$INSTALL_DIR"
    fi
}

_xui_detect_bin_dir() {
    if [[ -n "${XUI_CAPS_BIN_DIR:-}" ]]; then
        printf '%s' "$XUI_CAPS_BIN_DIR"
        return 0
    fi
    local detected=""
    if is_running; then
        detected=$(run_out "docker exec 3xui_app sh -c 'if [ -n \"\${XUI_BIN_FOLDER:-}\" ] && [ -d \"\$XUI_BIN_FOLDER\" ]; then printf \"%s\" \"\$XUI_BIN_FOLDER\"; elif [ -d /app/bin ]; then printf /app/bin; elif [ -d /usr/local/x-ui/bin ]; then printf /usr/local/x-ui/bin; fi'" || true)
    fi
    XUI_CAPS_BIN_DIR="${detected:-/app/bin}"
    printf '%s' "$XUI_CAPS_BIN_DIR"
}

_xui_sqlite_query() {
    local sql="$1"
    local sep="${2:-}"
    local host_db container_db sep_flag=""
    [[ -n "$sep" ]] && sep_flag="-separator $(quote_sh "$sep") "
    host_db=$(_xui_host_db_path)
    container_db=$(_xui_detect_db_path)

    # Prefer host sqlite3 when available to avoid mutating 3x-ui container internals.
    if run_q "command -v sqlite3 && test -f $(quote_sh "$host_db")"; then
        run_out "sqlite3 -cmd '.timeout 5000' ${sep_flag}$(quote_sh "$host_db") $(quote_sh "$sql")" || true
    elif is_running && ensure_sqlite_in_container; then
        run_out "docker exec 3xui_app sqlite3 -cmd '.timeout 5000' ${sep_flag}$(quote_sh "$container_db") $(quote_sh "$sql")" || true
    fi
}

xui_db_get() {
    local key="$1"
    [[ "$key" =~ ^[a-zA-Z0-9_]+$ ]] || return 1

    if _is_postgres_backend; then
        is_pg_running || return 1
        get_pg_env
        run_out "docker exec 3xui_postgres psql -U $(quote_sh "$PG_USER") -d $(quote_sh "$PG_DB") -tAc $(quote_sh "SELECT value FROM settings WHERE key='${key}' LIMIT 1;")" || true
    else
        local sql="SELECT value FROM settings WHERE key='${key}' LIMIT 1;"
        _xui_sqlite_query "$sql"
    fi
}

xui_db_get_many() {
    local keys_in=("$@")
    if (( ${#keys_in[@]} == 0 )); then
        keys_in=(
            webDomain webListen webPort webBasePath webCertFile
            twoFactorEnable sessionMaxAge
            subEnable subListen subDomain subPort subPath
            subJsonEnable subJsonPath subURI subJsonURI
            subEncrypt subCertFile subKeyFile
        )
    fi

    local sql_list="" k
    for k in "${keys_in[@]}"; do
        [[ "$k" =~ ^[a-zA-Z0-9_]+$ ]] || return 1
        sql_list+="${sql_list:+, }'${k}'"
    done

    if _is_postgres_backend; then
        is_pg_running || return 1
        get_pg_env
        local sql="SELECT key, regexp_replace(COALESCE(value,''), E'[\\r\\n\\t]+', ' ', 'g') FROM settings WHERE key IN (${sql_list});"
        run_out "docker exec 3xui_postgres psql -U $(quote_sh "$PG_USER") -d $(quote_sh "$PG_DB") -F \$'\t' -tA -c $(quote_sh "$sql")" || true
    else
        local sql="SELECT key, replace(replace(replace(COALESCE(value,''), char(10), ' '), char(13), ''), char(9), ' ') FROM settings WHERE key IN (${sql_list});"
        _xui_sqlite_query "$sql" $'\t'
    fi
}

xui_db_set() {
    local key="$1" val="$2"
    [[ "$key" =~ ^[a-zA-Z0-9_]+$ ]] || return 1
    has_control_chars "$val" && return 1
    local val_sql="${val//\'/\'\'}"

    if _is_postgres_backend; then
        is_pg_running || { error "PostgreSQL container is not running"; return 1; }
        get_pg_env
        local sql="WITH upd AS (UPDATE settings SET value='${val_sql}' WHERE key='${key}' RETURNING id) INSERT INTO settings (key, value) SELECT '${key}', '${val_sql}' WHERE NOT EXISTS (SELECT 1 FROM upd);"
        run_masked "Update 3X-UI setting ($key)" "docker exec 3xui_postgres psql -v ON_ERROR_STOP=1 -U $(quote_sh "$PG_USER") -d $(quote_sh "$PG_DB") -c $(quote_sh "$sql") >/dev/null"
    else
        local sql="UPDATE settings SET value='${val_sql}' WHERE key='${key}'; INSERT INTO settings (key, value) SELECT '${key}', '${val_sql}' WHERE (SELECT changes()) = 0;"
        local host_db container_db
        host_db=$(_xui_host_db_path)
        container_db=$(_xui_detect_db_path)
        if run_q "command -v sqlite3 && test -f $(quote_sh "$host_db")"; then
            run_masked "Update 3X-UI setting ($key)" "sqlite3 -cmd '.timeout 5000' $(quote_sh "$host_db") $(quote_sh "$sql")"
        elif is_running && ensure_sqlite_in_container; then
            run_masked "Update 3X-UI setting ($key)" "docker exec 3xui_app sqlite3 -cmd '.timeout 5000' $(quote_sh "$container_db") $(quote_sh "$sql")"
        else
            report_diagnostic "ERROR" "xui_db_set" \
                "sqlite3 unavailable on host and inside container" \
                "3xui database ($host_db)" \
                "Install sqlite3 on the host (apt install sqlite3) and retry."
            return 1
        fi
    fi
}

load_proxy_conf() {
    PROXY_ENABLED=false
    PROXY_DOMAIN=""
    PROXY_PORT="443"
    PROXY_EMAIL=""
    SUB_MODE="none"
    SUB_DOMAIN=""
    SUB_PORT="2096"
    SUB_PATH="/sub/"
    SUB_JSON_PATH="/json/"
    PROXY_SUB_URL=""

    local conf_raw
    conf_raw=$(run_out "cat $(quote_sh "$INSTALL_DIR/caddy/proxy.conf")" || true)
    [[ -z "$conf_raw" ]] && return 0

    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            if [[ "$val" =~ ^\"(.*)\"$ ]]; then
                val="${BASH_REMATCH[1]}"
            elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            case "$key" in
                PROXY_ENABLED) [[ "$val" == "true" ]] && PROXY_ENABLED=true || PROXY_ENABLED=false ;;
                PROXY_DOMAIN)  validate_domain "$val" && PROXY_DOMAIN="$val" ;;
                PROXY_PORT)    validate_port "$val" && PROXY_PORT="$val" ;;
                PROXY_EMAIL)   validate_email "$val" && PROXY_EMAIL="$val" ;;
                SUB_MODE)      [[ "$val" =~ ^(none|same|dedicated)$ ]] && SUB_MODE="$val" ;;
                SUB_DOMAIN)    validate_domain "$val" && SUB_DOMAIN="$val" ;;
                SUB_PORT)      validate_port "$val" && SUB_PORT="$val" ;;
                SUB_PATH)      validate_webpath "$val" && SUB_PATH="$val" ;;
                SUB_JSON_PATH) validate_webpath "$val" && SUB_JSON_PATH="$val" ;;
            esac
        fi
    done <<< "$conf_raw"
}

save_proxy_conf() {
    local conf_body
    conf_body=$(printf 'PROXY_ENABLED="%s"\nPROXY_DOMAIN="%s"\nPROXY_PORT="%s"\nPROXY_EMAIL="%s"\nSUB_MODE="%s"\nSUB_DOMAIN="%s"\nSUB_PORT="%s"\nSUB_PATH="%s"\nSUB_JSON_PATH="%s"\n' \
        "$PROXY_ENABLED" "$PROXY_DOMAIN" "$PROXY_PORT" "$PROXY_EMAIL" \
        "$SUB_MODE" "$SUB_DOMAIN" "$SUB_PORT" "$SUB_PATH" "$SUB_JSON_PATH")

    run "mkdir -p $(quote_sh "$INSTALL_DIR/caddy") && chmod 755 $(quote_sh "$INSTALL_DIR/caddy")" || return 1
    if $REMOTE; then
        printf '%s' "$conf_body" | ssh_cmd "umask 077 && cat > $(quote_sh "$INSTALL_DIR/caddy/proxy.conf") && chmod 600 $(quote_sh "$INSTALL_DIR/caddy/proxy.conf")"
    else
        ( umask 077; printf '%s' "$conf_body" > "$INSTALL_DIR/caddy/proxy.conf" )
        chmod 600 "$INSTALL_DIR/caddy/proxy.conf"
    fi
}

load_probe_conf() {
    DECOY_THEME="cloud"
    DECOY_SITE_NAME="Meridian Cloud Systems"
    DECOY_SITE_TAGLINE="Managed Edge Infrastructure & Reliability Engineering"
    DECOY_CONTACT_EMAIL="hello@meridiancloud.example"

    PROBE_REDIRECT_ENABLED=false
    PROBE_REDIRECT_TARGET="https://www.cloudflare.com"
    PROBE_REDIRECT_STATUS="302"
    PROBE_FALLBACK_MODE="decoy"
    PROBE_FALLBACK_URL=""
    PROBE_CHECK_INTERVAL="60"
    PROBE_ACTIVE_STATE="primary"
    PROBE_DETECT_SCANNERS=true
    PROBE_DETECT_CRAWLERS=false
    PROBE_DETECT_CLI=true
    PROBE_DETECT_EMPTY_UA=true
    PROBE_DETECT_BAD_METHODS=true
    PROBE_DETECT_PATHS=true
    PROBE_CUSTOM_UA=""
    PROBE_CUSTOM_PATHS=""
    PROBE_BLOCK_CIDRS=""
    PROBE_ALLOW_CIDRS=""

    local conf_raw
    conf_raw=$(run_out "cat $(quote_sh "$INSTALL_DIR/caddy/probe.conf")" || true)
    if [[ -n "$conf_raw" ]]; then
        local line key val
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"
                if [[ "$val" =~ ^\"(.*)\"$ ]]; then
                    val="${BASH_REMATCH[1]}"
                elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
                    val="${BASH_REMATCH[1]}"
                fi
                has_control_chars "$val" && continue
                case "$key" in
                    DECOY_THEME)              [[ "$val" =~ ^(cloud|studio|docs)$ ]] && DECOY_THEME="$val" ;;
                    DECOY_SITE_NAME)          [[ -n "$val" && ${#val} -le 80 && ! "$val" =~ [\<\>\"\'\{\}\;\`] ]] && DECOY_SITE_NAME="$val" ;;
                    DECOY_SITE_TAGLINE)       [[ -n "$val" && ${#val} -le 140 && ! "$val" =~ [\<\>\"\'\{\}\;\`] ]] && DECOY_SITE_TAGLINE="$val" ;;
                    DECOY_CONTACT_EMAIL)      validate_email "$val" && DECOY_CONTACT_EMAIL="$val" ;;
                    PROBE_REDIRECT_ENABLED)   [[ "$val" == "true" ]] && PROBE_REDIRECT_ENABLED=true || PROBE_REDIRECT_ENABLED=false ;;
                    PROBE_REDIRECT_TARGET)    validate_redirect_url "$val" && PROBE_REDIRECT_TARGET="$val" ;;
                    PROBE_REDIRECT_STATUS)    [[ "$val" =~ ^(301|302|307)$ ]] && PROBE_REDIRECT_STATUS="$val" ;;
                    PROBE_FALLBACK_MODE)      [[ "$val" =~ ^(decoy|secondary_url|not_found)$ ]] && PROBE_FALLBACK_MODE="$val" ;;
                    PROBE_FALLBACK_URL)       [[ -z "$val" ]] && PROBE_FALLBACK_URL="" || { validate_redirect_url "$val" && PROBE_FALLBACK_URL="$val"; } ;;
                    PROBE_CHECK_INTERVAL)     [[ "$val" =~ ^[0-9]+$ ]] && (( 10#$val >= 15 && 10#$val <= 3600 )) && PROBE_CHECK_INTERVAL="$((10#$val))" ;;
                    PROBE_DETECT_SCANNERS)    [[ "$val" == "true" ]] && PROBE_DETECT_SCANNERS=true || PROBE_DETECT_SCANNERS=false ;;
                    PROBE_DETECT_CRAWLERS)    [[ "$val" == "true" ]] && PROBE_DETECT_CRAWLERS=true || PROBE_DETECT_CRAWLERS=false ;;
                    PROBE_DETECT_CLI)         [[ "$val" == "true" ]] && PROBE_DETECT_CLI=true || PROBE_DETECT_CLI=false ;;
                    PROBE_DETECT_EMPTY_UA)    [[ "$val" == "true" ]] && PROBE_DETECT_EMPTY_UA=true || PROBE_DETECT_EMPTY_UA=false ;;
                    PROBE_DETECT_BAD_METHODS) [[ "$val" == "true" ]] && PROBE_DETECT_BAD_METHODS=true || PROBE_DETECT_BAD_METHODS=false ;;
                    PROBE_DETECT_PATHS)       [[ "$val" == "true" ]] && PROBE_DETECT_PATHS=true || PROBE_DETECT_PATHS=false ;;
                    PROBE_CUSTOM_UA)          [[ ! "$val" =~ [\{\}\;\<\>\"\'\\\`] ]] && PROBE_CUSTOM_UA="$val" ;;
                    PROBE_CUSTOM_PATHS)       [[ ! "$val" =~ [\{\}\;\<\>\"\'\\\`] ]] && PROBE_CUSTOM_PATHS="$val" ;;
                    PROBE_BLOCK_CIDRS)        validate_cidr_csv "$val" && PROBE_BLOCK_CIDRS="$val" ;;
                    PROBE_ALLOW_CIDRS)        validate_cidr_csv "$val" && PROBE_ALLOW_CIDRS="$val" ;;
                esac
            fi
        done <<< "$conf_raw"
    fi

    local state_raw st_val
    state_raw=$(run_out "cat $(quote_sh "$INSTALL_DIR/caddy/probe-state.json")" || true)
    if [[ -n "$state_raw" ]]; then
        st_val=$(printf '%s' "$state_raw" | sed -nE 's/.*"active_state"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)
        case "$st_val" in
            primary|fallback_secondary|fallback_decoy|fallback_404|disabled) PROBE_ACTIVE_STATE="$st_val" ;;
        esac
    fi
}

save_probe_conf() {
    local conf_body
    conf_body=$(cat <<EOF
DECOY_THEME="${DECOY_THEME}"
DECOY_SITE_NAME="${DECOY_SITE_NAME}"
DECOY_SITE_TAGLINE="${DECOY_SITE_TAGLINE}"
DECOY_CONTACT_EMAIL="${DECOY_CONTACT_EMAIL}"
PROBE_REDIRECT_ENABLED="${PROBE_REDIRECT_ENABLED}"
PROBE_REDIRECT_TARGET="${PROBE_REDIRECT_TARGET}"
PROBE_REDIRECT_STATUS="${PROBE_REDIRECT_STATUS}"
PROBE_FALLBACK_MODE="${PROBE_FALLBACK_MODE}"
PROBE_FALLBACK_URL="${PROBE_FALLBACK_URL}"
PROBE_CHECK_INTERVAL="${PROBE_CHECK_INTERVAL}"
PROBE_DETECT_SCANNERS="${PROBE_DETECT_SCANNERS}"
PROBE_DETECT_CRAWLERS="${PROBE_DETECT_CRAWLERS}"
PROBE_DETECT_CLI="${PROBE_DETECT_CLI}"
PROBE_DETECT_EMPTY_UA="${PROBE_DETECT_EMPTY_UA}"
PROBE_DETECT_BAD_METHODS="${PROBE_DETECT_BAD_METHODS}"
PROBE_DETECT_PATHS="${PROBE_DETECT_PATHS}"
PROBE_CUSTOM_UA="${PROBE_CUSTOM_UA}"
PROBE_CUSTOM_PATHS="${PROBE_CUSTOM_PATHS}"
PROBE_BLOCK_CIDRS="${PROBE_BLOCK_CIDRS}"
PROBE_ALLOW_CIDRS="${PROBE_ALLOW_CIDRS}"
EOF
)
    run "mkdir -p $(quote_sh "$INSTALL_DIR/caddy") && chmod 755 $(quote_sh "$INSTALL_DIR/caddy")" || return 1
    if $REMOTE; then
        printf '%s\n' "$conf_body" | ssh_cmd "umask 077 && cat > $(quote_sh "$INSTALL_DIR/caddy/probe.conf") && chmod 600 $(quote_sh "$INSTALL_DIR/caddy/probe.conf")"
    else
        ( umask 077; printf '%s\n' "$conf_body" > "$INSTALL_DIR/caddy/probe.conf" )
        chmod 600 "$INSTALL_DIR/caddy/probe.conf"
    fi
}

load_webpanel_conf() {
    WEBPANEL_ENABLED=false
    WEBPANEL_PORT="2059"
    WEBPANEL_PATH="/deploy/"
    WEBPANEL_USER="admin"
    WEBPANEL_SESSION_IDLE="30"
    WEBPANEL_BIND="127.0.0.1"
    WEBPANEL_DOMAIN=""

    local conf_raw
    conf_raw=$(run_out "cat $(quote_sh "$INSTALL_DIR/webpanel/webpanel.conf")" || true)
    [[ -z "$conf_raw" ]] && return 0

    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            if [[ "$val" =~ ^\"(.*)\"$ ]]; then
                val="${BASH_REMATCH[1]}"
            elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            case "$key" in
                WEBPANEL_ENABLED)      [[ "$val" == "true" ]] && WEBPANEL_ENABLED=true || WEBPANEL_ENABLED=false ;;
                WEBPANEL_PORT)         validate_port "$val" && WEBPANEL_PORT="$val" ;;
                WEBPANEL_PATH)         validate_webpath "$val" && WEBPANEL_PATH=$(_normalize_webpath "$val") ;;
                WEBPANEL_USER)         [[ "$val" =~ ^[a-zA-Z0-9._-]{1,64}$ ]] && WEBPANEL_USER="$val" ;;
                WEBPANEL_SESSION_IDLE) [[ "$val" =~ ^[0-9]+$ ]] && (( 10#$val >= 5 && 10#$val <= 1440 )) && WEBPANEL_SESSION_IDLE="$((10#$val))" ;;
                WEBPANEL_BIND)         [[ "$val" == "127.0.0.1" || "$val" == "::1" ]] && WEBPANEL_BIND="$val" ;;
                WEBPANEL_DOMAIN)       validate_domain "$val" && WEBPANEL_DOMAIN="$val" ;;
            esac
        fi
    done <<< "$conf_raw"
}

save_webpanel_conf() {
    local conf_body
    conf_body=$(cat <<EOF
WEBPANEL_ENABLED="${WEBPANEL_ENABLED}"
WEBPANEL_BIND="${WEBPANEL_BIND:-127.0.0.1}"
WEBPANEL_PORT="${WEBPANEL_PORT}"
WEBPANEL_PATH="${WEBPANEL_PATH}"
WEBPANEL_USER="${WEBPANEL_USER}"
WEBPANEL_SESSION_IDLE="${WEBPANEL_SESSION_IDLE}"
WEBPANEL_DOMAIN="${WEBPANEL_DOMAIN:-$PROXY_DOMAIN}"
EOF
)
    run "mkdir -p $(quote_sh "$INSTALL_DIR/webpanel") && chmod 700 $(quote_sh "$INSTALL_DIR/webpanel")" || return 1
    if $REMOTE; then
        printf '%s\n' "$conf_body" | ssh_cmd "umask 077 && cat > $(quote_sh "$INSTALL_DIR/webpanel/webpanel.conf") && chmod 600 $(quote_sh "$INSTALL_DIR/webpanel/webpanel.conf")"
    else
        ( umask 077; printf '%s\n' "$conf_body" > "$INSTALL_DIR/webpanel/webpanel.conf" )
        chmod 600 "$INSTALL_DIR/webpanel/webpanel.conf"
    fi
}

# ─── 3X-UI Forward Compatibility & Capability Adapter Layer ─────────────────
_semver_parse() {
    local raw="${1-}"
    raw="${raw#v}"
    raw="${raw#V}"
    raw="${raw%%-*}"
    raw="${raw%%+*}"
    if [[ "$raw" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
        printf '%d %d %d' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[4]:-0}))"
        return 0
    fi
    return 1
}

_semver_compare() {
    local p1 p2
    p1=$(_semver_parse "$1") || return 1
    p2=$(_semver_parse "$2") || return 1
    local a1 b1 c1 a2 b2 c2
    read -r a1 b1 c1 <<< "$p1"
    read -r a2 b2 c2 <<< "$p2"
    if (( a1 != a2 )); then (( a1 > a2 )) && echo "1" || echo "-1"; return 0; fi
    if (( b1 != b2 )); then (( b1 > b2 )) && echo "1" || echo "-1"; return 0; fi
    if (( c1 != c2 )); then (( c1 > c2 )) && echo "1" || echo "-1"; return 0; fi
    echo "0"
}

xui_classify_version() {
    local target="${1-}" current="${2-}"
    local parsed
    if ! parsed=$(_semver_parse "$target"); then
        XUI_COMPAT_STATUS="unknown_tag"
        printf 'unknown_tag'
        return 0
    fi
    local maj min pat
    read -r maj min pat <<< "$parsed"
    if (( maj < 2 )); then
        XUI_COMPAT_STATUS="unsupported_legacy"
        printf 'unsupported_legacy'
        return 0
    fi
    if (( maj > XUI_COMPAT_MAX_TESTED_MAJOR )); then
        XUI_COMPAT_STATUS="unsupported_major"
        printf 'unsupported_major'
        return 0
    fi
    if [[ -n "$current" ]]; then
        local cparsed cmaj cmin cpat
        if cparsed=$(_semver_parse "$current"); then
            read -r cmaj cmin cpat <<< "$cparsed"
            if (( maj > cmaj )); then
                XUI_COMPAT_STATUS="major_upgrade"
                printf 'major_upgrade'
                return 0
            fi
        fi
    fi
    XUI_COMPAT_STATUS="supported"
    printf 'supported'
}

_xui_find_binary() {
    if [[ -n "${XUI_CAPS_BIN:-}" ]]; then
        printf '%s' "$XUI_CAPS_BIN"
        return 0
    fi
    local found=""
    if is_running; then
        found=$(run_out "docker exec 3xui_app sh -c 'for p in /app/x-ui /usr/local/x-ui/x-ui /app/3x-ui; do if [ -x \"\$p\" ] && [ \"\$(head -c 2 \"\$p\" 2>/dev/null)\" != \"#!\" ]; then printf \"%s\" \"\$p\"; exit 0; fi; done; exe=\$(readlink -f /proc/1/exe 2>/dev/null || true); case \"\$exe\" in *x-ui*|*3x-ui*) [ -x \"\$exe\" ] && printf \"%s\" \"\$exe\" ;; esac'" || true)
    fi
    XUI_CAPS_BIN="$found"
    printf '%s' "$found"
}

xui_detect_version() {
    local tag="" oci_ver="" bin_ver="" bin_path=""
    if is_deployed; then
        tag=$(run_out "awk -F: '/image:[[:space:]]*ghcr\\.io\\/mhsanaei\\/3x-ui:/ {print \$NF; exit}' $(quote_sh "$INSTALL_DIR/compose.yaml")" | tr -d '\r ' || true)
    fi
    if is_running; then
        oci_ver=$(run_out "docker inspect --format '{{index .Config.Labels \"org.opencontainers.image.version\"}}' 3xui_app 2>/dev/null" | tr -d '\r ' || true)
        [[ "$oci_ver" == "<no value>" ]] && oci_ver=""
        if [[ -z "$oci_ver" ]] && { [[ -z "$tag" || "$tag" == "latest" ]]; }; then
            bin_path=$(_xui_find_binary)
            if [[ -n "$bin_path" ]]; then
                bin_ver=$(run_out "docker exec 3xui_app $(quote_sh "$bin_path") -v 2>/dev/null || docker exec 3xui_app $(quote_sh "$bin_path") version 2>/dev/null" | grep -Eo 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)
            fi
        fi
    fi

    if _semver_parse "$oci_ver" >/dev/null 2>&1 && { [[ -z "$tag" || "$tag" == "latest" ]]; }; then
        XUI_DETECTED_VERSION="$oci_ver"
    elif [[ -n "$bin_ver" ]] && { [[ -z "$tag" || "$tag" == "latest" ]]; }; then
        XUI_DETECTED_VERSION="$bin_ver"
    else
        XUI_DETECTED_VERSION="${tag:-${oci_ver:-${bin_ver:-unknown}}}"
    fi
    printf '%s' "$XUI_DETECTED_VERSION"
}

_xui_check_db_schema() {
    local issues=""
    if _is_postgres_backend; then
        if ! is_pg_running; then
            XUI_CAPS_SCHEMA_OK="unavailable"
            return 0
        fi
        get_pg_env
        local s_cols i_cols
        s_cols=$(run_out "docker exec 3xui_postgres psql -U $(quote_sh "$PG_USER") -d $(quote_sh "$PG_DB") -tAc \"SELECT column_name FROM information_schema.columns WHERE table_name='settings';\"" || true)
        i_cols=$(run_out "docker exec 3xui_postgres psql -U $(quote_sh "$PG_USER") -d $(quote_sh "$PG_DB") -tAc \"SELECT column_name FROM information_schema.columns WHERE table_name='inbounds';\"" || true)
        [[ -z "$s_cols" ]] && issues+="missing table 'settings'; "
        if [[ -n "$s_cols" ]]; then
            printf '%s\n' "$s_cols" | grep -qx 'key' || issues+="settings.key missing; "
            printf '%s\n' "$s_cols" | grep -qx 'value' || issues+="settings.value missing; "
        fi
        [[ -z "$i_cols" ]] && issues+="missing table 'inbounds'; "
        if [[ -n "$i_cols" ]]; then
            for col in id enable protocol listen port remark; do
                printf '%s\n' "$i_cols" | grep -qx "$col" || issues+="inbounds.${col} missing; "
            done
            if ! printf '%s\n' "$i_cols" | grep -qxE 'stream_settings|streamSettings'; then
                issues+="inbounds.stream_settings missing; "
            fi
        fi
    else
        local s_info i_info
        s_info=$(_xui_sqlite_query "PRAGMA table_info(settings);" "|" || true)
        i_info=$(_xui_sqlite_query "PRAGMA table_info(inbounds);" "|" || true)
        if [[ -z "$s_info" && -z "$i_info" ]]; then
            XUI_CAPS_SCHEMA_OK="unavailable"
            return 0
        fi
        [[ -z "$s_info" ]] && issues+="missing table 'settings'; "
        if [[ -n "$s_info" ]]; then
            printf '%s\n' "$s_info" | cut -d'|' -f2 | grep -qx 'key' || issues+="settings.key missing; "
            printf '%s\n' "$s_info" | cut -d'|' -f2 | grep -qx 'value' || issues+="settings.value missing; "
        fi
        [[ -z "$i_info" ]] && issues+="missing table 'inbounds'; "
        if [[ -n "$i_info" ]]; then
            for col in id enable protocol listen port remark; do
                printf '%s\n' "$i_info" | cut -d'|' -f2 | grep -qx "$col" || issues+="inbounds.${col} missing; "
            done
            if ! printf '%s\n' "$i_info" | cut -d'|' -f2 | grep -qxE 'stream_settings|streamSettings'; then
                issues+="inbounds.stream_settings missing; "
            fi
        fi
    fi

    if [[ -n "$issues" ]]; then
        XUI_CAPS_SCHEMA_OK="drift"
        report_diagnostic "ERROR" "db_schema_check" \
            "3x-ui database schema differs from expected contract: ${issues}" \
            "3x-ui settings / inbounds tables" \
            "Check 3x-ui release notes for DB schema changes and update 3xui-deploy before applying settings."
        return 1
    fi
    XUI_CAPS_SCHEMA_OK="ok"
    return 0
}

xui_probe_capabilities() {
    XUI_CAPS_FLAGS=""
    local bin=""
    if is_running; then
        bin=$(_xui_find_binary)
        XUI_CAPS_BIN="$bin"
        _xui_detect_db_path >/dev/null || true
        _xui_detect_bin_dir >/dev/null || true
        if [[ -z "$bin" ]]; then
            report_diagnostic "ERROR" "capability_probe" \
                "No executable 3x-ui Go binary found in running container (checked /app/x-ui, /usr/local/x-ui/x-ui, /app/3x-ui)" \
                "3xui_app CLI integration" \
                "Verify the container image layout or run '3xui-deploy compat matrix'."
            return 1
        fi
        local help_out
        help_out=$(run_out "docker exec 3xui_app $(quote_sh "$bin") setting -h 2>&1 || docker exec 3xui_app $(quote_sh "$bin") setting --help 2>&1" || true)
        local flag found_flags=""
        for flag in show getListen getCert port listenIP webBasePath username password resetTwoFactor webCert webCertKey; do
            if printf '%s' "$help_out" | grep -qE -- "[-]{1,2}${flag}\\b"; then
                found_flags+="${found_flags:+,}${flag}"
            fi
        done
        XUI_CAPS_FLAGS="$found_flags"
        if [[ -z "$found_flags" ]]; then
            warn "Could not detect known flags in '${bin} setting -h' (future CLI contract drift possible)."
        fi
    fi
    _xui_check_db_schema || return 1
    return 0
}

xui_preflight_image() {
    local tag="$1"
    validate_tag "$tag" || { error "Invalid tag for preflight: $tag"; return 1; }
    local img="ghcr.io/mhsanaei/3x-ui:${tag}"
    local probe_script='
b=""
for p in /app/x-ui /usr/local/x-ui/x-ui /app/3x-ui; do
    if [ -x "$p" ] && [ "$(head -c 2 "$p" 2>/dev/null)" != "#!" ]; then
        b="$p"; break
    fi
done
[ -n "$b" ] || { echo "PREFLIGHT_ERR:no_go_binary"; exit 2; }
help_out=$("$b" setting -h 2>&1 || "$b" setting --help 2>&1 || true)
printf "PREFLIGHT_BIN=%s\n" "$b"
printf "%s\n" "$help_out" | grep -qE -- "-show|-port|-username" || { echo "PREFLIGHT_ERR:setting_cli_changed"; exit 3; }
echo "PREFLIGHT_OK=1"
'
    local out rc=0
    out=$(run_out "docker run --rm --entrypoint sh $(quote_sh "$img") -c $(quote_sh "$probe_script") 2>&1") || rc=$?
    if (( rc != 0 )) || ! printf '%s\n' "$out" | grep -q 'PREFLIGHT_OK=1'; then
        report_diagnostic "ERROR" "image_preflight" \
            "Image ${img} failed pre-deployment binary/CLI compatibility inspection" \
            "ghcr.io/mhsanaei/3x-ui:${tag}" \
            "Inspect release notes for breaking changes or re-run with --force-compat if intentional." \
            "$(printf '%s' "$out" | tr '\n' ' ')"
        return 1
    fi
    log_debug "Preflight OK for $img: $(printf '%s' "$out" | tr '\n' ' ')"
    return 0
}

xui_check_compatibility() {
    local subcmd="${1:-check}"
    local arg="${2:-}"

    if [[ "$subcmd" == "matrix" ]]; then
        echo ""
        echo -e "  ${BOLD}3x-ui Compatibility Contract Matrix${NC}"
        echo -e "  ${DIM}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${NC}"
        echo "  Supported Versions : v2.0.0 .. v3.x (majors: ${XUI_COMPAT_SUPPORTED_MAJORS})"
        echo "  Legacy Unsupported : < v${XUI_COMPAT_MIN_VERSION} (blocked unless --force-compat)"
        echo "  Future Major       : >= v$(( XUI_COMPAT_MAX_TESTED_MAJOR + 1 )).0.0 (blocked unless --force-compat)"
        echo "  Binary Candidates  : /app/x-ui, /usr/local/x-ui/x-ui, /app/3x-ui"
        echo "  DB Tables Required : settings(key,value), inbounds(id,enable,protocol,listen,port,remark,stream_settings)"
        echo "  Setting CLI Flags  : show, getListen, getCert, port, listenIP, webBasePath, username, password, resetTwoFactor, webCert, webCertKey"
        echo ""
        return 0
    fi

    if [[ "$subcmd" == "test" ]]; then
        [[ -n "$arg" ]] || { error "Usage: manage.sh compat test <version-tag>"; return 1; }
        validate_tag "$arg" || { error "Invalid tag: $arg"; return 1; }
        local cur cls
        cur=$(xui_detect_version || true)
        cls=$(xui_classify_version "$arg" "$cur")
        info "Target tag '$arg' classified as: $cls (current: ${cur:-none})"
        if [[ "$cls" == "unsupported_legacy" || "$cls" == "unsupported_major" ]]; then
            report_diagnostic "CRITICAL" "compat_test" \
                "Target 3x-ui tag '${arg}' is classified as '${cls}' outside tested majors (${XUI_COMPAT_SUPPORTED_MAJORS})." \
                "3xui_app / compose.yaml" \
                "Choose a supported v2.x/v3.x release tag or pass --force-compat at your own risk."
            $FORCE_COMPAT || return 1
        fi
        if run_q "command -v docker"; then
            info "Pulling ghcr.io/mhsanaei/3x-ui:${arg} for read-only preflight..."
            run "docker pull $(quote_sh "ghcr.io/mhsanaei/3x-ui:${arg}")" || return 1
            xui_preflight_image "$arg" || return 1
            success "Pre-flight compatibility check passed for ${arg}"
        else
            warn "Docker not installed; skipping image pull preflight (classification=${cls})."
        fi
        return 0
    fi

    local ver cls probe_rc=0
    ver=$(xui_detect_version)
    cls=$(xui_classify_version "$ver")
    xui_probe_capabilities || probe_rc=$?

    echo ""
    echo -e "  ${BOLD}3x-ui Compatibility & Capability Report${NC}"
    echo -e "  ${DIM}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${NC}"
    echo "  Detected Version : ${ver:-unknown}"
    echo "  Classification   : ${cls}"
    echo "  Binary           : ${XUI_CAPS_BIN:-not detected}"
    echo "  DB Path          : ${XUI_CAPS_DB_PATH:-/etc/x-ui/x-ui.db}"
    echo "  Bin Dir          : ${XUI_CAPS_BIN_DIR:-/app/bin}"
    echo "  Schema           : ${XUI_CAPS_SCHEMA_OK:-unknown}"
    echo "  CLI Flags        : ${XUI_CAPS_FLAGS:-none detected}"
    echo ""

    if [[ "$cls" == "unsupported_legacy" || "$cls" == "unsupported_major" ]]; then
        report_diagnostic "CRITICAL" "compat_check" \
            "Installed 3x-ui version '${ver}' (${cls}) is outside supported versions (v2.x-v3.x)." \
            "3xui_app" \
            "Upgrade/pin to a supported v2.x/v3.x release or update 3xui-deploy."
        $FORCE_COMPAT || return 1
    fi
    (( probe_rc == 0 )) || return 1
    return 0
}

# ─── Panel Introspection & Settings ─────────────────────────────────────────
# Note: inside mhsanaei/3x-ui Docker images, /usr/bin/x-ui is the x-ui.sh shell
# wrapper (no 'setting' subcommand). Probe Go binary candidates dynamically.
_xui_setting_cmd() {
    local args="" a
    for a in "$@"; do
        args+=" $(quote_sh "$a")"
    done
    printf 'docker exec 3xui_app sh -c '\''b=""; for c in /app/x-ui /usr/local/x-ui/x-ui /app/3x-ui; do if [ -x "$c" ] && [ "$(head -c 2 "$c" 2>/dev/null)" != "#!" ]; then b="$c"; break; fi; done; [ -n "$b" ] || b=/app/x-ui; exec "$b" setting "$@"'\'' _%s' "$args"
}

# Set panel username/password via stdin so the password never appears in local,
# SSH, or docker exec process command-line arguments.
_xui_set_credentials_stdin() {
    local user="$1" pass="$2" port="${3:-}" webpath="${4:-}"
    local inner_sh='IFS= read -r _p; _u="$1"; _pt="$2"; _wp="$3"; b=/app/x-ui; [ -x "$b" ] || b=/usr/local/x-ui/x-ui; [ -x "$b" ] || b=/app/3x-ui; set -- setting "-username=${_u}" "-password=${_p}"; [ -n "$_pt" ] && set -- "$@" "-port=${_pt}"; [ -n "$_wp" ] && set -- "$@" "-webBasePath=${_wp}"; exec "$b" "$@"'
    local cmd
    cmd="docker exec -i 3xui_app sh -c $(quote_sh "$inner_sh") _ $(quote_sh "$user") $(quote_sh "$port") $(quote_sh "$webpath")"
    if $REMOTE; then
        printf '%s\n' "$pass" | ssh_cmd "$cmd" 2>&1
    else
        printf '%s\n' "$pass" | bash -c "$cmd" 2>&1
    fi
}

_normalize_webpath() {
    local p="${1-}"
    p=$(printf '%s' "$p" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [[ -z "$p" || "$p" == "/" ]]; then
        printf '/'
        return 0
    fi
    [[ "$p" != /* ]] && p="/$p"
    [[ "$p" != */ ]] && p="${p}/"
    printf '%s' "$p"
}

_paths_overlap() {
    local a b
    a=$(_normalize_webpath "${1:-/}")
    b=$(_normalize_webpath "${2:-/}")
    a="${a%/}"; [[ -z "$a" ]] && a="/"
    b="${b%/}"; [[ -z "$b" ]] && b="/"
    [[ "$a" == "$b" || "$a" == "/" || "$b" == "/" ]] && return 0
    [[ "$b" == "$a"/* || "$a" == "$b"/* ]]
}

_parse_panel_outputs() {
    local show_out="${1-}" listen_out="${2-}" cert_out="${3-}"
    local clean_show clean_listen clean_cert val
    clean_show=$(printf '%s\n' "$show_out" | sed -E $'s/\x1B\\[[0-9;]*[A-Za-z]//g')
    clean_listen=$(printf '%s\n' "$listen_out" | sed -E $'s/\x1B\\[[0-9;]*[A-Za-z]//g')
    clean_cert=$(printf '%s\n' "$cert_out" | sed -E $'s/\x1B\\[[0-9;]*[A-Za-z]//g')

    if [[ -n "$clean_show" ]]; then
        val=$(printf '%s\n' "$clean_show" | awk '/^[[:space:]]*port[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' | tr -d '\r ')
        validate_port "$val" && PANEL_PORT="$val"

        val=$(printf '%s\n' "$clean_show" | awk '/^[[:space:]]*webBasePath[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}')
        if [[ -n "$val" ]]; then
            PANEL_PATH=$(_normalize_webpath "$val")
        fi

        val=$(printf '%s\n' "$clean_show" | awk '/^[[:space:]]*username[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' | tr -d '\r ')
        [[ -n "$val" ]] && PANEL_USER="$val"

        val=$(printf '%s\n' "$clean_show" | awk '/^[[:space:]]*hasDefaultCredential[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' | tr -d '\r ')
        [[ -n "$val" ]] && PANEL_HAS_DEFAULT="$val"
    fi

    if [[ -n "$clean_listen" ]]; then
        val=$(printf '%s\n' "$clean_listen" | awk '
            {
                low = tolower($0)
                if (low ~ /^[[:space:]]*(current[[:space:]]+)?(listen[[:space:]]*ip|listenip|weblisten|listen)[[:space:]]*:/) {
                    sub(/^[^:]*:[[:space:]]*/, "", $0)
                    print $0
                    exit
                }
            }
        ' | tr -d '\r ')
        if [[ -n "$val" && "$val" != "<nil>" && "$val" != "none" ]] && validate_listen_ip "$val"; then
            PANEL_LISTEN="$val"
        fi
    fi

    local cert_path="" key_path=""
    if [[ -n "$clean_cert" ]]; then
        cert_path=$(printf '%s\n' "$clean_cert" | awk '/^[[:space:]]*cert[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' | tr -d '\r ')
        key_path=$(printf '%s\n' "$clean_cert"  | awk '/^[[:space:]]*key[[:space:]]*:/  {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' | tr -d '\r ')
    fi
    if [[ -n "$cert_path" && -n "$key_path" && "$cert_path" != "none" && "$cert_path" != "<nil>" ]]; then
        PANEL_PROTO="https"
    elif printf '%s\n' "$clean_show" | grep -q 'Panel is secure with SSL'; then
        PANEL_PROTO="https"
    fi
}

get_panel_info() {
    PANEL_PORT="2053"
    PANEL_PATH="/"
    PANEL_USER="admin"
    PANEL_PROTO="http"
    PANEL_LISTEN=""
    PANEL_DOMAIN=""
    PANEL_2FA=""
    PANEL_SESSION_AGE=""
    PANEL_HAS_DEFAULT=""

    SUB_ENABLE_DB=""
    SUB_LISTEN_DB=""
    SUB_DOMAIN_DB=""
    SUB_PORT_DB=""
    SUB_PATH_DB=""
    SUB_JSON_ENABLE_DB=""
    SUB_JSON_PATH_DB=""
    SUB_URI_DB=""
    SUB_JSON_URI_DB=""
    SUB_ENCRYPT_DB=""
    SUB_CERT_DB=""
    SUB_KEY_DB=""

    load_proxy_conf

    local running=false
    is_running && running=true

    local out="" cert_out="" listen_out=""
    if $running; then
        out=$(run_out "$(_xui_setting_cmd -show=true)" || true)
        listen_out=$(run_out "$(_xui_setting_cmd -getListen=true)" || true)
        cert_out=$(run_out "$(_xui_setting_cmd -getCert=true)" || true)
        _parse_panel_outputs "$out" "$listen_out" "$cert_out"
    fi

    local db_rows line db_k db_v
    db_rows=$(xui_db_get_many || true)
    if [[ -n "$db_rows" ]]; then
        while IFS= read -r line; do
            [[ "$line" == *$'\t'* ]] || continue
            db_k="${line%%$'\t'*}"
            db_v="${line#*$'\t'}"
            db_v="${db_v%$'\r'}"
            case "$db_k" in
                webDomain)       PANEL_DOMAIN="$db_v" ;;
                twoFactorEnable) PANEL_2FA="$db_v" ;;
                sessionMaxAge)   PANEL_SESSION_AGE="$db_v" ;;
                webListen)
                    if [[ -z "$PANEL_LISTEN" && -n "$db_v" ]] && validate_listen_ip "$db_v"; then
                        PANEL_LISTEN="$db_v"
                    fi
                    ;;
                webPort)
                    [[ -z "$out" ]] && validate_port "$db_v" && PANEL_PORT="$db_v"
                    ;;
                webBasePath)
                    [[ -z "$out" && -n "$db_v" ]] && PANEL_PATH=$(_normalize_webpath "$db_v")
                    ;;
                webCertFile)
                    [[ -z "$out" && -n "$db_v" ]] && PANEL_PROTO="https"
                    ;;
                subEnable)     SUB_ENABLE_DB="$db_v" ;;
                subListen)     SUB_LISTEN_DB="$db_v" ;;
                subDomain)     SUB_DOMAIN_DB="$db_v" ;;
                subPort)       SUB_PORT_DB="$db_v" ;;
                subPath)       SUB_PATH_DB="$db_v" ;;
                subJsonEnable) SUB_JSON_ENABLE_DB="$db_v" ;;
                subJsonPath)   SUB_JSON_PATH_DB="$db_v" ;;
                subURI)        SUB_URI_DB="$db_v" ;;
                subJsonURI)    SUB_JSON_URI_DB="$db_v" ;;
                subEncrypt)    SUB_ENCRYPT_DB="$db_v" ;;
                subCertFile)   SUB_CERT_DB="$db_v" ;;
                subKeyFile)    SUB_KEY_DB="$db_v" ;;
            esac
        done <<< "$db_rows"
    fi

    if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]] && [[ "$SUB_MODE" != "none" ]]; then
        local port_sfx="" sub_host="$PROXY_DOMAIN"
        [[ "$PROXY_PORT" != "443" ]] && port_sfx=":${PROXY_PORT}"
        [[ "$SUB_MODE" == "dedicated" && -n "$SUB_DOMAIN" ]] && sub_host="$SUB_DOMAIN"
        PROXY_SUB_URL="https://${sub_host}${port_sfx}${SUB_PATH}"
    fi

    $running && return 0 || return 1
}

format_panel_url() {
    local ip="$1"
    local path
    path=$(_normalize_webpath "$PANEL_PATH")
    if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]] && is_caddy_running; then
        local port_sfx=""
        [[ "$PROXY_PORT" != "443" ]] && port_sfx=":${PROXY_PORT}"
        printf 'https://%s%s%s' "$PROXY_DOMAIN" "$port_sfx" "$path"
        return 0
    fi
    printf '%s://%s%s' "$PANEL_PROTO" "$(_format_host_port "$ip" "$PANEL_PORT")" "$path"
}

_probe_panel_http() {
    local url="$1"
    local resolve_arg="${2:-}"
    local host_header="${3:-}"
    local curl_bin="curl"
    if ! run_q "command -v curl" && is_running; then
        curl_bin="docker exec 3xui_app curl"
    fi

    local curl_cmd="$curl_bin -ksSL --proto '=http,https' --max-redirs 5 --max-time 4"
    [[ -n "$resolve_arg" ]] && curl_cmd+=" --resolve $(quote_sh "$resolve_arg")"
    [[ -n "$host_header" ]] && curl_cmd+=" -H $(quote_sh "Host: ${host_header}")"
    curl_cmd+=" -w '\n__HTTP_CODE__:%{http_code}' $(quote_sh "$url")"

    local resp code body
    resp=$(run_out "$curl_cmd" || true)
    code=$(printf '%s\n' "$resp" | awk -F: '/^__HTTP_CODE__:/ {print $2; exit}' | tr -d '\r ')
    body=$(printf '%s\n' "$resp" | sed '/^__HTTP_CODE__:/d')

    if [[ "$code" == "200" ]] && printf '%s' "$body" | grep -qiE '(<html|id="app"|3x-ui|assets/|vite)'; then
        if ! printf '%s' "$body" | grep -qE '(Edge Relay Node|Service Status Portal|static-site-template:|Meridian Cloud Systems|Northstar Digital Studio|Atlas Engineering Docs)'; then
            return 0
        fi
    fi
    return 1
}

verify_panel_loaded() {
    local max_wait="${1:-12}"
    PANEL_LOAD_STATUS="unknown"

    is_running || { PANEL_LOAD_STATUS="stopped"; return 1; }
    get_panel_info || true

    local bind_host="127.0.0.1"
    if [[ -n "$PANEL_LISTEN" && "$PANEL_LISTEN" != "0.0.0.0" && "$PANEL_LISTEN" != "::" ]]; then
        bind_host="$PANEL_LISTEN"
    fi
    local path
    path=$(_normalize_webpath "$PANEL_PATH")
    local backend_url="${PANEL_PROTO}://$(_format_host_port "$bind_host" "$PANEL_PORT")${path}"
    local backend_host_hdr="${PANEL_DOMAIN:-}"
    if [[ -z "$backend_host_hdr" ]] && $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
        backend_host_hdr="$PROXY_DOMAIN"
    fi

    local backend_ok=false i
    local attempts=$(( max_wait > 0 ? max_wait : 1 ))
    for (( i=0; i<attempts; i++ )); do
        if _probe_panel_http "$backend_url" "" "$backend_host_hdr"; then
            backend_ok=true
            break
        fi
        (( i + 1 < attempts )) && sleep 1 || true
    done

    if ! $backend_ok; then
        PANEL_LOAD_STATUS="backend_unreachable"
        warn "Panel did not respond with 3X-UI UI at ${backend_url}"
        return 1
    fi

    if $PROXY_ENABLED && is_caddy_running && [[ -n "$PROXY_DOMAIN" ]]; then
        local proxy_url="https://$(_format_host_port "$PROXY_DOMAIN" "$PROXY_PORT")${path}"
        local resolve_entry="${PROXY_DOMAIN}:${PROXY_PORT}:127.0.0.1"
        local proxy_ok=false
        local proxy_attempts=$(( max_wait > 0 ? 4 : 1 ))
        for (( i=0; i<proxy_attempts; i++ )); do
            if _probe_panel_http "$proxy_url" "$resolve_entry"; then
                proxy_ok=true
                break
            fi
            (( i + 1 < proxy_attempts )) && sleep 1 || true
        done
        if ! $proxy_ok; then
            PANEL_LOAD_STATUS="proxy_failed"
            warn "Backend responds on ${backend_url}, but Caddy proxy probe failed for ${proxy_url}"
            return 1
        fi
        local curl_bin="curl"
        if ! run_q "command -v curl" && is_running; then
            curl_bin="docker exec 3xui_app curl"
        fi
        if ! run_q "$curl_bin -fsS --proto '=https' --tlsv1.2 --max-time 4 --resolve $(quote_sh "$resolve_entry") $(quote_sh "$proxy_url") >/dev/null"; then
            warn "HTTPS certificate on ${PROXY_DOMAIN}:${PROXY_PORT} is not yet publicly trusted (self-signed or ACME issuance pending)."
        fi
        PANEL_LOAD_STATUS="loaded_proxy"
        success "Panel verified live through Caddy proxy (${proxy_url})"
        return 0
    fi

    PANEL_LOAD_STATUS="loaded_direct"
    success "Panel verified live at ${backend_url}"
    return 0
}

_check_domain_dns() {
    local domain="${1-}"
    validate_domain "$domain" || return 1

    local resolved=""
    resolved=$(run_out "
        if command -v getent >/dev/null 2>&1; then
            getent ahosts $(quote_sh "$domain") 2>/dev/null | awk '{print \$1}' | sort -u
        elif command -v dig >/dev/null 2>&1; then
            { dig +short A $(quote_sh "$domain"); dig +short AAAA $(quote_sh "$domain"); } 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' | sort -u
        elif command -v nslookup >/dev/null 2>&1; then
            nslookup $(quote_sh "$domain") 2>/dev/null | awk '/^Address:[[:space:]]*/ {print \$2}' | grep -E '^[0-9a-fA-F:.]+$' | sort -u
        fi
    " || true)

    if [[ -z "$resolved" ]]; then
        warn "DNS lookup for ${domain} returned no A/AAAA records (ensure DNS points to this server)."
        return 1
    fi

    local pub4="" pub6="" local_ip=""
    pub4=$(run_out "curl -4fsS --proto '=https' --tlsv1.2 --max-time 2 https://api.ipify.org" || true)
    pub6=$(run_out "curl -6fsS --proto '=https' --tlsv1.2 --max-time 2 https://api64.ipify.org" || true)
    local_ip=$(run_out "hostname -I 2>/dev/null | awk '{print \$1}'" || true)

    local matched="" r="" resolved_csv=""
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        resolved_csv+="${resolved_csv:+, }${r}"
        if [[ -n "$pub4" && "$r" == "$pub4" ]] || [[ -n "$pub6" && "$r" == "$pub6" ]] || [[ -z "$pub4" && -z "$pub6" && -n "$local_ip" && "$r" == "$local_ip" ]]; then
            matched="$r"
        fi
    done <<< "$resolved"

    if [[ -n "$matched" ]]; then
        success "DNS for ${domain} resolves to this server (${matched})."
        return 0
    fi

    warn "DNS for ${domain} resolves to [${resolved_csv}], which differs from server IP (${pub4:-unknown}${pub6:+, $pub6})."
    echo "  Note: If using Cloudflare/CDN proxy (orange cloud), ensure SSL/TLS mode is Full (strict)."
    return 0
}

_probe_sub_http() {
    local url="$1"
    local resolve_arg="${2:-}"
    local host_header="${3:-}"
    local expect_proxy_hdr="${4:-false}"
    local curl_bin="curl"
    if ! run_q "command -v curl" && is_running; then
        curl_bin="docker exec 3xui_app curl"
    fi

    local curl_cmd="$curl_bin -ksSi --proto '=http,https' --max-time 4"
    [[ -n "$resolve_arg" ]] && curl_cmd+=" --resolve $(quote_sh "$resolve_arg")"
    [[ -n "$host_header" ]] && curl_cmd+=" -H $(quote_sh "Host: ${host_header}")"
    curl_cmd+=" -w '\n__HTTP_CODE__:%{http_code}' $(quote_sh "$url")"

    local resp code clean_resp
    resp=$(run_out "$curl_cmd" || true)
    code=$(printf '%s\n' "$resp" | awk -F: '/^__HTTP_CODE__:/ {print $2; exit}' | tr -d '\r ')
    clean_resp=$(printf '%s\n' "$resp" | sed '/^__HTTP_CODE__:/d' | tr -d '\r')

    case "$code" in
        ""|000|502|503|504)
            _SUB_PROBE_ERR="unreachable"
            return 1
            ;;
        403)
            _SUB_PROBE_ERR="forbidden"
            return 1
            ;;
    esac

    if printf '%s' "$clean_resp" | grep -qE '(Edge Relay Node|Service Status Portal|static-site-template:|Meridian Cloud Systems|Northstar Digital Studio|Atlas Engineering Docs)'; then
        _SUB_PROBE_ERR="decoy"
        return 1
    fi
    if [[ "$expect_proxy_hdr" == "true" ]] && ! printf '%s\n' "$clean_resp" | grep -qiE '^cache-control:[[:space:]]*no-store'; then
        _SUB_PROBE_ERR="missing_proxy_header"
        return 1
    fi
    _SUB_PROBE_ERR=""
    return 0
}

verify_subscription_endpoint() {
    local max_wait="${1:-8}"
    SUB_VERIFY_STATUS="unknown"

    is_running || { SUB_VERIFY_STATUS="stopped"; return 1; }
    get_panel_info || true

    if $PROXY_ENABLED && [[ "$SUB_MODE" != "none" ]]; then
        local expected_sub_host="$PROXY_DOMAIN"
        [[ "$SUB_MODE" == "dedicated" && -n "$SUB_DOMAIN" ]] && expected_sub_host="$SUB_DOMAIN"
        local port_sfx=""
        [[ "$PROXY_PORT" != "443" ]] && port_sfx=":${PROXY_PORT}"
        local expected_sub_uri="https://${expected_sub_host}${port_sfx}${SUB_PATH}"
        local expected_sub_json_uri="https://${expected_sub_host}${port_sfx}${SUB_JSON_PATH}"

        local db_errs=0
        [[ "$SUB_ENABLE_DB" != "true" ]] && { warn "DB mismatch: subEnable is '${SUB_ENABLE_DB:-unset}' (expected 'true')"; db_errs=$((db_errs+1)); }
        [[ "$SUB_LISTEN_DB" != "127.0.0.1" ]] && { warn "DB mismatch: subListen is '${SUB_LISTEN_DB:-unset}' (expected '127.0.0.1')"; db_errs=$((db_errs+1)); }
        [[ "$SUB_DOMAIN_DB" != "$expected_sub_host" ]] && { warn "DB mismatch: subDomain is '${SUB_DOMAIN_DB:-unset}' (expected '${expected_sub_host}')"; db_errs=$((db_errs+1)); }
        [[ "$SUB_PORT_DB" != "$SUB_PORT" ]] && { warn "DB mismatch: subPort is '${SUB_PORT_DB:-unset}' (expected '${SUB_PORT}')"; db_errs=$((db_errs+1)); }
        [[ "$SUB_URI_DB" != "$expected_sub_uri" ]] && { warn "DB mismatch: subURI is '${SUB_URI_DB:-unset}' (expected '${expected_sub_uri}')"; db_errs=$((db_errs+1)); }
        if [[ "$SUB_JSON_ENABLE_DB" != "true" && "$SUB_JSON_ENABLE_DB" != "false" ]]; then
            warn "DB mismatch: subJsonEnable is unset (expected 'true' or 'false')"
            db_errs=$((db_errs+1))
        fi
        if [[ "$SUB_JSON_ENABLE_DB" == "true" && "$SUB_JSON_URI_DB" != "$expected_sub_json_uri" ]]; then
            warn "DB mismatch: subJsonURI is '${SUB_JSON_URI_DB:-unset}' (expected '${expected_sub_json_uri}')"
            db_errs=$((db_errs+1))
        fi
        if (( db_errs > 0 )); then
            SUB_VERIFY_STATUS="db_mismatch"
            return 1
        fi

        local backend_url="http://127.0.0.1:${SUB_PORT}${SUB_PATH}__probe__"
        local attempts=$(( max_wait > 0 ? max_wait : 1 ))
        local i backend_ok=false
        for (( i=0; i<attempts; i++ )); do
            if _probe_sub_http "$backend_url" "" "$expected_sub_host" "false"; then
                backend_ok=true
                break
            fi
            [[ "$_SUB_PROBE_ERR" == "forbidden" ]] && break
            (( i + 1 < attempts )) && sleep 1 || true
        done

        if ! $backend_ok; then
            if [[ "$_SUB_PROBE_ERR" == "forbidden" ]]; then
                SUB_VERIFY_STATUS="domain_rejected"
                warn "Subscription backend rejected Host '${expected_sub_host}' with HTTP 403 (check subDomain in 3X-UI)."
            else
                SUB_VERIFY_STATUS="listen_down"
                warn "Subscription listener did not respond on 127.0.0.1:${SUB_PORT}."
            fi
            return 1
        fi

        if is_caddy_running; then
            local resolve_entry="${expected_sub_host}:${PROXY_PORT}:127.0.0.1"
            local sub_proxy_url="https://$(_format_host_port "$expected_sub_host" "$PROXY_PORT")${SUB_PATH}__probe__"
            local json_proxy_url="https://$(_format_host_port "$expected_sub_host" "$PROXY_PORT")${SUB_JSON_PATH}__probe__"
            local proxy_ok=false
            local proxy_attempts=$(( max_wait > 0 ? 4 : 1 ))
            for (( i=0; i<proxy_attempts; i++ )); do
                if _probe_sub_http "$sub_proxy_url" "$resolve_entry" "" "true" && \
                   { [[ "$SUB_JSON_ENABLE_DB" != "true" ]] || _probe_sub_http "$json_proxy_url" "$resolve_entry" "" "true"; }; then
                    proxy_ok=true
                    break
                fi
                (( i + 1 < proxy_attempts )) && sleep 1 || true
            done
            if ! $proxy_ok; then
                SUB_VERIFY_STATUS="proxy_failed"
                warn "Caddy subscription proxy probe failed for ${expected_sub_uri} (${_SUB_PROBE_ERR:-error})."
                return 1
            fi
        else
            SUB_VERIFY_STATUS="proxy_failed"
            warn "Caddy container (3xui_caddy) is not running — subscription domain ${expected_sub_host} is unreachable."
            return 1
        fi

        _check_domain_dns "$expected_sub_host" || true
        SUB_VERIFY_STATUS="ok_proxy"
        success "Subscription endpoint verified via Caddy (${expected_sub_uri})"
        return 0
    fi

    if [[ "$SUB_ENABLE_DB" == "true" ]]; then
        if _is_loopback_addr "${SUB_LISTEN_DB:-}"; then
            warn "Subscription server is bound to loopback (${SUB_LISTEN_DB}) without Caddy active — unreachable externally."
        fi
        local sub_port="${SUB_PORT_DB:-2096}"
        local sub_path="${SUB_PATH_DB:-/sub/}"
        sub_path=$(_normalize_webpath "$sub_path")
        local bind_host="127.0.0.1"
        if [[ -n "$SUB_LISTEN_DB" && "$SUB_LISTEN_DB" != "0.0.0.0" && "$SUB_LISTEN_DB" != "::" ]]; then
            bind_host="$SUB_LISTEN_DB"
        fi
        local sub_proto="http"
        [[ -n "$SUB_CERT_DB" && -n "$SUB_KEY_DB" ]] && sub_proto="https"
        local direct_url="${sub_proto}://$(_format_host_port "$bind_host" "$sub_port")${sub_path}__probe__"
        local attempts=$(( max_wait > 0 ? max_wait : 1 ))
        local i direct_ok=false
        for (( i=0; i<attempts; i++ )); do
            if _probe_sub_http "$direct_url" "" "${SUB_DOMAIN_DB:-}" "false"; then
                direct_ok=true
                break
            fi
            [[ "$_SUB_PROBE_ERR" == "forbidden" ]] && break
            (( i + 1 < attempts )) && sleep 1 || true
        done
        if ! $direct_ok; then
            if [[ "$_SUB_PROBE_ERR" == "forbidden" ]]; then
                SUB_VERIFY_STATUS="domain_rejected"
                warn "Direct subscription server rejected Host '${SUB_DOMAIN_DB}' with HTTP 403."
            else
                SUB_VERIFY_STATUS="listen_down"
                warn "Direct subscription listener did not respond on ${direct_url}."
            fi
            return 1
        fi
        [[ -n "$SUB_DOMAIN_DB" ]] && { _check_domain_dns "$SUB_DOMAIN_DB" || true; }
        SUB_VERIFY_STATUS="ok_direct"
        success "Subscription server verified directly on port ${sub_port}"
        return 0
    fi

    SUB_VERIFY_STATUS="disabled"
    info "Subscription server is disabled."
    return 0
}

_apply_subscription_db_settings() {
    local sub_en="$1" sub_listen="$2" sub_dom="$3" sub_port="$4" sub_path="$5"
    local json_en="$6" json_path="$7" sub_enc="$8" sub_cert="$9" sub_key="${10}"
    local sub_uri="${11}" json_uri="${12}"
    xui_db_set "subEnable" "$sub_en" || return 1
    xui_db_set "subListen" "$sub_listen" || return 1
    xui_db_set "subDomain" "$sub_dom" || return 1
    xui_db_set "subPort" "$sub_port" || return 1
    xui_db_set "subPath" "$sub_path" || return 1
    xui_db_set "subJsonEnable" "$json_en" || return 1
    xui_db_set "subJsonPath" "$json_path" || return 1
    xui_db_set "subEncrypt" "$sub_enc" || return 1
    xui_db_set "subCertFile" "$sub_cert" || return 1
    xui_db_set "subKeyFile" "$sub_key" || return 1
    xui_db_set "subURI" "$sub_uri" || return 1
    xui_db_set "subJsonURI" "$json_uri" || return 1
}

_clear_subscription_proxy_db() {
    xui_db_set "subListen" "" || true
    xui_db_set "subDomain" "" || true
    xui_db_set "subURI" "" || true
    xui_db_set "subJsonURI" "" || true
}

reset_credentials() {
    require_deployed || return 1
    require_running  || return 1

    get_panel_info || true
    local default_user="${PANEL_USER:-admin}"

    echo ""
    local new_user new_pass new_pass_confirm auto_pass=false
    read -rp "  New username [${default_user}]: " new_user
    new_user="${new_user:-$default_user}"
    if [[ -z "$new_user" || "$new_user" =~ [[:space:]] || "$new_user" == -* ]] || has_control_chars "$new_user"; then
        error "Invalid username (must be non-empty without spaces, leading '-', or control characters)"
        return 1
    fi

    read -rs -p "  New password [Enter to auto-generate strong 20-char password]: " new_pass
    echo ""
    if [[ -z "$new_pass" ]]; then
        new_pass=$(generate_random_string 20)
        auto_pass=true
    else
        if ! validate_strong_password "$new_pass"; then
            error "Password does not meet security requirements (min 12 chars, no control chars or common defaults, >=16 chars or >=2 character classes)"
            return 1
        fi
        read -rs -p "  Confirm new password: " new_pass_confirm
        echo ""
        if [[ "$new_pass" != "$new_pass_confirm" ]]; then
            new_pass=""
            new_pass_confirm=""
            error "Passwords do not match"
            return 1
        fi
        new_pass_confirm=""
    fi

    local cred_out="" cred_rc=0
    cred_out=$(_xui_set_credentials_stdin "$new_user" "$new_pass") || cred_rc=$?

    if (( cred_rc != 0 )) || printf '%s' "$cred_out" | grep -qiE '(failed|error)'; then
        new_pass=""
        error "Update credentials failed"
        [[ -n "$cred_out" ]] && echo "  $cred_out"
        return 1
    fi

    get_panel_info || true
    success "Credentials updated (username: ${PANEL_USER:-$new_user})"
    $auto_pass && echo -e "  Generated password: ${BOLD}${YELLOW}${new_pass}${NC}  (save this now!)"
    new_pass=""
    confirm "Restart panel now to apply & refresh active sessions?" && restart_panel || true
}

_sync_caddy_if_active() {
    load_proxy_conf
    $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]] || return 0
    local p_port="$1" p_path="$2"
    local use_p_cert=false use_s_cert=false
    if run_q "grep -q $(quote_sh "tls /root/cert/$PROXY_DOMAIN/") $(quote_sh "$INSTALL_DIR/caddy/Caddyfile")" \
        && run_q "test -f $(quote_sh "$INSTALL_DIR/cert/$PROXY_DOMAIN/fullchain.pem") && test -f $(quote_sh "$INSTALL_DIR/cert/$PROXY_DOMAIN/privkey.pem")"; then
        use_p_cert=true
    fi
    if [[ "$SUB_MODE" == "dedicated" && -n "$SUB_DOMAIN" ]]; then
        if run_q "grep -q $(quote_sh "tls /root/cert/$SUB_DOMAIN/") $(quote_sh "$INSTALL_DIR/caddy/Caddyfile")" \
            && run_q "test -f $(quote_sh "$INSTALL_DIR/cert/$SUB_DOMAIN/fullchain.pem") && test -f $(quote_sh "$INSTALL_DIR/cert/$SUB_DOMAIN/privkey.pem")"; then
            use_s_cert=true
        fi
    fi

    local cf="$INSTALL_DIR/caddy/Caddyfile"
    local cf_bak="$INSTALL_DIR/caddy/Caddyfile.bak"
    local had_cf=false
    if run_q "test -f $(quote_sh "$cf")"; then
        had_cf=true
        run "cp $(quote_sh "$cf") $(quote_sh "$cf_bak") && chmod 644 $(quote_sh "$cf_bak")" || true
    fi

    if ! generate_caddyfile "$PROXY_DOMAIN" "$PROXY_PORT" "$PROXY_EMAIL" "$p_port" "$p_path" \
        "$SUB_MODE" "$SUB_DOMAIN" "$SUB_PORT" "$SUB_PATH" "$SUB_JSON_PATH" \
        "$use_p_cert" "$use_s_cert"; then
        $had_cf && run_q "mv -f $(quote_sh "$cf_bak") $(quote_sh "$cf")" || true
        report_diagnostic "ERROR" "sync_caddy" \
            "Failed to generate updated Caddyfile" \
            "Caddy reverse proxy ($cf)" \
            "Restored previous Caddyfile; check proxy.conf and probe.conf values."
        return 1
    fi

    if is_caddy_running; then
        if _caddy_reload; then
            run_q "rm -f $(quote_sh "$cf_bak")" || true
            success "Synced & reloaded Caddy reverse proxy"
        else
            if $had_cf; then
                run_q "mv -f $(quote_sh "$cf_bak") $(quote_sh "$cf")" || true
                _caddy_reload >/dev/null 2>&1 || true
            fi
            report_diagnostic "ERROR" "caddy_reload" \
                "Caddy rejected the regenerated configuration and was rolled back" \
                "3xui_caddy ($cf)" \
                "Inspect Caddy logs and probe/proxy settings."
            return 1
        fi
    else
        run_q "rm -f $(quote_sh "$cf_bak")" || true
    fi
}

change_panel_port() {
    require_running || return 1
    get_panel_info || true
    echo ""
    echo -e "  Current port: ${BOLD}${PANEL_PORT}${NC}"
    local new_port
    read -rp "  New panel port (1-65535): " new_port
    if ! validate_port "$new_port"; then
        error "Invalid port: $new_port"
        return 1
    fi
    run "$(_xui_setting_cmd -port "$new_port")" || return 1
    success "Panel port updated to $new_port (restart required to take effect)"
    if confirm "Restart panel now?"; then
        restart_panel || true
        _sync_caddy_if_active "$new_port" "$PANEL_PATH"
    elif $PROXY_ENABLED; then
        warn "Caddy still proxies to port $PANEL_PORT until you restart the panel and run 'Reverse proxy -> Setup/Reconfigure'."
    fi
}

change_panel_listen_ip() {
    require_running || return 1
    get_panel_info || true
    echo ""
    echo -e "  Current listen IP: ${BOLD}${PANEL_LISTEN:-0.0.0.0 (all interfaces)}${NC}"
    $PROXY_ENABLED && echo -e "  ${DIM}Note: Caddy reverse proxy expects panel bound to 127.0.0.1.${NC}"
    local new_listen
    read -rp "  New listen IP (blank/0.0.0.0=all, 127.0.0.1=local/proxy, ::1=IPv6 loopback): " new_listen
    if ! validate_listen_ip "$new_listen"; then
        error "Invalid listen IP: $new_listen"
        return 1
    fi
    if [[ -n "$new_listen" && "$new_listen" != "0.0.0.0" && "$new_listen" != "::" && "$new_listen" != "127.0.0.1" && "$new_listen" != "::1" ]]; then
        if run_q "command -v ip" && ! run_q "ip -o addr show | grep -qF $(quote_sh " ${new_listen}/")"; then
            warn "Address '${new_listen}' was not detected on local host interfaces (binding may fail)."
            confirm "Use '${new_listen}' anyway?" || return 0
        fi
    fi
    if $PROXY_ENABLED && ! _is_loopback_addr "$new_listen"; then
        warn "Setting a non-loopback listen IP while Caddy proxy is enabled exposes the panel directly!"
        confirm "Continue with direct exposure?" || return 0
    fi

    if [[ -n "$new_listen" ]]; then
        run "$(_xui_setting_cmd -listenIP "$new_listen")" >/dev/null 2>&1 || true
    fi
    xui_db_set "webListen" "$new_listen" || return 1
    success "Panel listen IP updated to '${new_listen:-0.0.0.0 (all interfaces)}'"
    confirm "Restart panel now?" && restart_panel || true
}

change_panel_webpath() {
    require_running || return 1
    get_panel_info || true
    echo ""
    echo -e "  Current Web Base Path: ${BOLD}${PANEL_PATH}${NC}"
    local new_path
    read -rp "  New path (e.g. /mysecret/) [Enter to auto-generate]: " new_path
    if [[ -z "$new_path" ]]; then
        new_path="/$(generate_random_string 12)/"
    else
        [[ "$new_path" != /* ]] && new_path="/$new_path"
        [[ "$new_path" != */ ]] && new_path="${new_path}/"
    fi
    if ! validate_webpath "$new_path"; then
        error "Invalid path (allowed: alphanumeric, '/', '_', '-'; max 128 chars; no '..' or '//')"
        return 1
    fi
    if $PROXY_ENABLED && [[ "$new_path" == "/" ]]; then
        error "Web Base Path cannot be '/' while Caddy camouflage site is active"
        return 1
    fi
    run "$(_xui_setting_cmd -webBasePath "$new_path")" || return 1
    success "Web Base Path set to ${BOLD}${new_path}${NC}"
    if confirm "Restart panel now?"; then
        restart_panel || true
        _sync_caddy_if_active "$PANEL_PORT" "$new_path"
    elif $PROXY_ENABLED; then
        warn "Caddy still routes $PANEL_PATH until you restart the panel and reconfigure Caddy."
    fi
}

configure_subscription_settings() {
    require_deployed || return 1
    require_running  || return 1
    get_panel_info || true

    echo ""
    echo -e "  ${BOLD}${MAGENTA}Subscription Domain & Network Configuration${NC}"
    echo -e "  ${DIM}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${NC}"
    echo -e "  subEnable    : ${SUB_ENABLE_DB:-unset}  (JSON: ${SUB_JSON_ENABLE_DB:-false}, Encrypt: ${SUB_ENCRYPT_DB:-false})"
    echo -e "  subListen    : ${SUB_LISTEN_DB:-all interfaces}  Port: ${SUB_PORT_DB:-2096}"
    echo -e "  subDomain    : ${SUB_DOMAIN_DB:-(none)}"
    echo -e "  subPath      : ${SUB_PATH_DB:-/sub/}  JSON: ${SUB_JSON_PATH_DB:-/json/}"
    echo -e "  subURI       : ${SUB_URI_DB:-(auto)}"
    echo -e "  subJsonURI   : ${SUB_JSON_URI_DB:-(auto)}"
    echo -e "  subCertFile  : ${SUB_CERT_DB:-(none)}"
    if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
        echo -e "  Caddy Proxy  : ${GREEN}enabled${NC} (mode=${SUB_MODE}, panel=${PROXY_DOMAIN}:${PROXY_PORT})"
    else
        echo -e "  Caddy Proxy  : ${DIM}disabled (direct mode)${NC}"
    fi
    echo ""

    if ! confirm "Enable 3X-UI subscription server?"; then
        xui_db_set "subEnable" "false" || return 1
        if $PROXY_ENABLED && [[ "$SUB_MODE" != "none" ]]; then
            SUB_MODE="none"
            _clear_subscription_proxy_db
            save_proxy_conf || true
            _sync_caddy_if_active "$PANEL_PORT" "$PANEL_PATH" || true
        fi
        success "Subscription server disabled"
        confirm "Restart panel now?" && restart_panel || true
        return 0
    fi

    local new_sub_mode="$SUB_MODE" new_sub_domain="${SUB_DOMAIN_DB:-$SUB_DOMAIN}"
    local new_sub_listen="${SUB_LISTEN_DB:-}" new_sub_port="${SUB_PORT_DB:-${SUB_PORT:-2096}}"
    local new_sub_path="${SUB_PATH_DB:-${SUB_PATH:-/sub/}}" new_json_path="${SUB_JSON_PATH_DB:-${SUB_JSON_PATH:-/json/}}"
    local new_json_en="true" new_sub_enc="true"
    local new_sub_cert="" new_sub_key=""
    local new_sub_uri="" new_json_uri=""

    if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
        tui_select "Subscription Proxy Mode" "Caddy reverse proxy is active (${PROXY_DOMAIN}:${PROXY_PORT}):" \
            "Dedicated subscription domain (e.g. sub.example.com)" \
            "Same domain as panel (${PROXY_DOMAIN})" \
            "Cancel"
        local m_sel=$?
        clear_screen
        case "$m_sel" in
            0) new_sub_mode="dedicated" ;;
            1) new_sub_mode="same" ;;
            2|255) info "Cancelled"; return 0 ;;
        esac

        new_sub_listen="127.0.0.1"
        if [[ "$new_sub_mode" == "dedicated" ]]; then
            read -rp "  Subscription domain (e.g. sub.example.com)${new_sub_domain:+ [$new_sub_domain]}: " input_dom
            new_sub_domain="${input_dom:-$new_sub_domain}"
            if ! validate_domain "$new_sub_domain" || [[ "$new_sub_domain" == "$PROXY_DOMAIN" ]]; then
                error "Valid subscription domain different from $PROXY_DOMAIN is required"
                return 1
            fi
        else
            new_sub_domain="$PROXY_DOMAIN"
        fi
    else
        local disp_dom="${new_sub_domain:-none}"
        read -rp "  Subscription domain (or 'none' to clear) [${disp_dom}]: " input_dom
        if [[ "$input_dom" == "none" || "$input_dom" == "-" ]]; then
            new_sub_domain=""
        elif [[ -n "$input_dom" ]]; then
            if ! validate_domain "$input_dom"; then
                error "Invalid domain: $input_dom"
                return 1
            fi
            new_sub_domain="$input_dom"
        fi

        local disp_listen="${new_sub_listen:-0.0.0.0}"
        read -rp "  Subscription listen IP (blank/0.0.0.0=all, 127.0.0.1=loopback) [${disp_listen}]: " input_listen
        if [[ "$input_listen" == "0.0.0.0" || "$input_listen" == "all" ]]; then
            new_sub_listen=""
        elif [[ -n "$input_listen" ]]; then
            if ! validate_listen_ip "$input_listen"; then
                error "Invalid listen IP: $input_listen"
                return 1
            fi
            new_sub_listen="$input_listen"
        fi
        if _is_loopback_addr "$new_sub_listen"; then
            warn "Binding subscription server to loopback (${new_sub_listen}) without Caddy makes it unreachable externally."
            confirm "Continue with loopback listen IP?" || return 0
        fi
    fi

    read -rp "  Subscription listen port [${new_sub_port}]: " input_sp
    new_sub_port="${input_sp:-$new_sub_port}"
    validate_port "$new_sub_port" || { error "Invalid subscription port"; return 1; }
    [[ "$new_sub_port" == "$PANEL_PORT" ]] && { error "Subscription port must differ from panel port ($PANEL_PORT)"; return 1; }
    if $PROXY_ENABLED && [[ "$new_sub_port" == "$PROXY_PORT" ]]; then
        error "Internal subscription port cannot equal Caddy HTTPS port ($PROXY_PORT)"
        return 1
    fi
    local inbounds_list=""
    inbounds_list=$(get_xui_inbounds || true)
    if [[ -n "$inbounds_list" ]]; then
        local i_id i_en i_proto i_listen i_port i_rem i_net i_sec i_path i_fw
        while IFS='|' read -r i_id i_en i_proto i_listen i_port i_rem i_net i_sec i_path i_fw; do
            _is_inbound_enabled "$i_en" || continue
            if [[ "$i_port" == "$new_sub_port" ]]; then
                error "Inbound #${i_id} (${i_rem:-unnamed}, ${i_proto}/${i_net}) already uses port ${new_sub_port} — choose a different subscription port."
                return 1
            fi
        done <<< "$inbounds_list"
    fi

    read -rp "  Subscription path [${new_sub_path}]: " input_spath
    new_sub_path=$(_normalize_webpath "${input_spath:-$new_sub_path}")
    if [[ "$new_sub_path" == "/" ]] || ! validate_webpath "$new_sub_path"; then
        error "Invalid subscription path (cannot be '/')"
        return 1
    fi
    if $PROXY_ENABLED && [[ "$new_sub_mode" == "same" ]] && _paths_overlap "$new_sub_path" "$PANEL_PATH"; then
        error "Subscription path '$new_sub_path' overlaps panel path '$PANEL_PATH'"
        return 1
    fi

    read -rp "  JSON subscription path [${new_json_path}]: " input_jpath
    new_json_path=$(_normalize_webpath "${input_jpath:-$new_json_path}")
    if [[ "$new_json_path" == "/" ]] || ! validate_webpath "$new_json_path" || _paths_overlap "$new_sub_path" "$new_json_path"; then
        error "Invalid or overlapping JSON subscription path"
        return 1
    fi
    if $PROXY_ENABLED && [[ "$new_sub_mode" == "same" ]] && _paths_overlap "$new_json_path" "$PANEL_PATH"; then
        error "JSON subscription path '$new_json_path' overlaps panel path '$PANEL_PATH'"
        return 1
    fi

    confirm "Enable JSON subscription endpoint ($new_json_path)?" && new_json_en="true" || new_json_en="false"
    confirm "Base64-encode subscription responses (subEncrypt)?" && new_sub_enc="true" || new_sub_enc="false"

    if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
        local port_sfx=""
        [[ "$PROXY_PORT" != "443" ]] && port_sfx=":${PROXY_PORT}"
        new_sub_uri="https://${new_sub_domain}${port_sfx}${new_sub_path}"
        new_json_uri="https://${new_sub_domain}${port_sfx}${new_json_path}"
    else
        if [[ -n "$new_sub_domain" ]] && run_q "test -f $(quote_sh "$INSTALL_DIR/cert/$new_sub_domain/fullchain.pem") && test -f $(quote_sh "$INSTALL_DIR/cert/$new_sub_domain/privkey.pem")"; then
            if confirm "Found TLS cert in $INSTALL_DIR/cert/$new_sub_domain/. Enable HTTPS on direct subscription server?"; then
                new_sub_cert="/root/cert/${new_sub_domain}/fullchain.pem"
                new_sub_key="/root/cert/${new_sub_domain}/privkey.pem"
            fi
        elif [[ -n "$SUB_CERT_DB" && -n "$SUB_KEY_DB" ]]; then
            if confirm "Keep existing subscription TLS cert ($SUB_CERT_DB)?"; then
                new_sub_cert="$SUB_CERT_DB"
                new_sub_key="$SUB_KEY_DB"
            fi
        fi

        local sub_scheme="http" sub_port_sfx=":${new_sub_port}"
        if [[ -n "$new_sub_cert" && -n "$new_sub_key" ]]; then
            sub_scheme="https"
            [[ "$new_sub_port" == "443" ]] && sub_port_sfx=""
        else
            [[ "$new_sub_port" == "80" ]] && sub_port_sfx=""
        fi
        local ext_host="${new_sub_domain:-$(get_target_ip)}"
        if [[ -n "$sub_port_sfx" ]]; then
            new_sub_uri="${sub_scheme}://$(_format_host_port "$ext_host" "$new_sub_port")${new_sub_path}"
            new_json_uri="${sub_scheme}://$(_format_host_port "$ext_host" "$new_sub_port")${new_json_path}"
        else
            new_sub_uri="${sub_scheme}://${ext_host}${new_sub_path}"
            new_json_uri="${sub_scheme}://${ext_host}${new_json_path}"
        fi
    fi

    [[ -n "$new_sub_domain" ]] && { _check_domain_dns "$new_sub_domain" || true; }

    _apply_subscription_db_settings "true" "$new_sub_listen" "$new_sub_domain" "$new_sub_port" "$new_sub_path" \
        "$new_json_en" "$new_json_path" "$new_sub_enc" "$new_sub_cert" "$new_sub_key" \
        "$new_sub_uri" "$new_json_uri" || return 1

    if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
        SUB_MODE="$new_sub_mode"
        if [[ "$new_sub_mode" == "dedicated" ]]; then
            SUB_DOMAIN="$new_sub_domain"
        else
            SUB_DOMAIN=""
        fi
        SUB_PORT="$new_sub_port"
        SUB_PATH="$new_sub_path"
        SUB_JSON_PATH="$new_json_path"
        save_proxy_conf || return 1
        _sync_caddy_if_active "$PANEL_PORT" "$PANEL_PATH" || return 1
    fi

    success "Subscription configuration updated!"
    echo -e "  Sub URI  : ${BOLD}${new_sub_uri}${NC}"
    [[ "$new_json_en" == "true" ]] && echo -e "  JSON URI : ${BOLD}${new_json_uri}${NC}"
    if confirm "Restart 3X-UI panel now to apply & verify subscription endpoint?"; then
        compose restart 3xui >/dev/null || compose restart >/dev/null || true
        invalidate_status
        verify_panel_loaded 10 || true
        verify_subscription_endpoint 8 || true
    fi
}

configure_panel_security() {
    require_deployed || return 1
    require_running  || return 1
    get_panel_info || true

    echo ""
    echo -e "  ${BOLD}${MAGENTA}Panel Auth, Session & Domain Hardening${NC}"
    echo -e "  ${DIM}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${NC}"
    echo -e "  webDomain       : ${PANEL_DOMAIN:-(none)}"
    echo -e "  sessionMaxAge   : ${PANEL_SESSION_AGE:-default (unlimited/0)} minutes"
    echo -e "  twoFactorEnable : ${PANEL_2FA:-false}"
    echo -e "  defaultCreds    : ${PANEL_HAS_DEFAULT:-unknown}"
    echo ""

    local changed=false
    local new_age
    read -rp "  Session timeout in minutes (5-10080, recommended 60) [${PANEL_SESSION_AGE:-60}]: " new_age
    if [[ -n "$new_age" ]]; then
        if ! [[ "$new_age" =~ ^[0-9]+$ ]] || (( 10#$new_age < 5 || 10#$new_age > 10080 )); then
            error "Invalid session timeout (must be 5..10080 minutes)"
            return 1
        fi
        xui_db_set "sessionMaxAge" "$(( 10#$new_age ))" || return 1
        success "Session timeout set to $(( 10#$new_age )) minute(s)"
        changed=true
    fi

    echo ""
    echo -e "  ${DIM}Setting webDomain enforces strict Host-header validation (403 on raw IP / SSH tunnel Host: localhost).${NC}"
    local disp_wdom="${PANEL_DOMAIN:-none}"
    local new_wdom
    read -rp "  Panel webDomain (domain or 'none' to clear) [${disp_wdom}]: " new_wdom
    local domain_set=""
    if [[ "$new_wdom" == "none" || "$new_wdom" == "-" ]]; then
        xui_db_set "webDomain" "" || return 1
        success "Cleared webDomain"
        changed=true
    elif [[ -n "$new_wdom" ]]; then
        if ! validate_domain "$new_wdom"; then
            error "Invalid domain: $new_wdom"
            return 1
        fi
        xui_db_set "webDomain" "$new_wdom" || return 1
        success "Panel webDomain set to ${new_wdom}"
        domain_set="$new_wdom"
        changed=true
    fi

    if $changed; then
        confirm "Restart panel now to apply changes?" && restart_panel || true
    fi

    if [[ -n "$domain_set" ]]; then
        load_proxy_conf
        if $PROXY_ENABLED && [[ "$PROXY_DOMAIN" == "$domain_set" ]]; then
            info "Panel domain '$domain_set' active; ensuring Web Management Panel is enabled..."
            enable_webpanel auto || warn "Could not auto-enable Web Management Panel."
        elif ! $PROXY_ENABLED; then
            echo ""
            info "A domain name ($domain_set) was configured for the main panel."
            if confirm "Set up Caddy HTTPS proxy & automatically enable the Web Management Panel on https://${domain_set}/deploy/?"; then
                PROXY_DOMAIN="$domain_set"
                setup_reverse_proxy || true
            fi
        fi
    fi
}

reset_panel_2fa() {
    require_running || return 1
    confirm "Disable / reset Two-Factor Authentication (2FA) for admin?" || return 0
    run "$(_xui_setting_cmd -resetTwoFactor=true)" || return 1
    success "Two-Factor Authentication reset"
    confirm "Restart panel now?" && restart_panel || true
}

panel_settings_show() {
    get_panel_info || true
    load_webpanel_conf
    cat <<EOF
PANEL_PORT=${PANEL_PORT}
PANEL_PATH=${PANEL_PATH}
PANEL_USER=${PANEL_USER}
PANEL_LISTEN=${PANEL_LISTEN}
PANEL_DOMAIN=${PANEL_DOMAIN}
PANEL_PROTO=${PANEL_PROTO}
PANEL_2FA=${PANEL_2FA}
PANEL_SESSION_AGE=${PANEL_SESSION_AGE}
PANEL_HAS_DEFAULT=${PANEL_HAS_DEFAULT}
SUB_ENABLE_DB=${SUB_ENABLE_DB}
SUB_LISTEN_DB=${SUB_LISTEN_DB}
SUB_DOMAIN_DB=${SUB_DOMAIN_DB}
SUB_PORT_DB=${SUB_PORT_DB}
SUB_PATH_DB=${SUB_PATH_DB}
SUB_JSON_ENABLE_DB=${SUB_JSON_ENABLE_DB}
SUB_JSON_PATH_DB=${SUB_JSON_PATH_DB}
SUB_URI_DB=${SUB_URI_DB}
SUB_JSON_URI_DB=${SUB_JSON_URI_DB}
SUB_ENCRYPT_DB=${SUB_ENCRYPT_DB}
PROXY_ENABLED=${PROXY_ENABLED}
PROXY_DOMAIN=${PROXY_DOMAIN}
PROXY_PORT=${PROXY_PORT}
PROXY_EMAIL=${PROXY_EMAIL}
SUB_MODE=${SUB_MODE}
SUB_DOMAIN=${SUB_DOMAIN}
SUB_PORT=${SUB_PORT}
SUB_PATH=${SUB_PATH}
SUB_JSON_PATH=${SUB_JSON_PATH}
WEBPANEL_ENABLED=${WEBPANEL_ENABLED}
WEBPANEL_PATH=${WEBPANEL_PATH}
WEBPANEL_PORT=${WEBPANEL_PORT}
WEBPANEL_SESSION_IDLE=${WEBPANEL_SESSION_IDLE}
WEBPANEL_DOMAIN=${WEBPANEL_DOMAIN}
EOF
}

settings_cli_dispatch() {
    local subcmd="${1:-show}"
    shift || true
    case "$subcmd" in
        show)
            panel_settings_show
            ;;
        set-port)
            require_deployed || return 1
            require_running  || return 1
            local new_port="${1:-}"
            validate_port "$new_port" || { error "Invalid port: $new_port"; return 1; }
            get_panel_info || true
            if $PROXY_ENABLED && [[ "$new_port" == "$PROXY_PORT" ]]; then
                error "Internal panel port cannot equal Caddy HTTPS port ($PROXY_PORT)"
                return 1
            fi
            if [[ "$SUB_ENABLE_DB" == "true" && "$new_port" == "${SUB_PORT_DB:-$SUB_PORT}" ]]; then
                error "Panel port cannot equal subscription port (${SUB_PORT_DB:-$SUB_PORT})"
                return 1
            fi
            run "$(_xui_setting_cmd -port "$new_port")" || return 1
            success "Panel port updated to $new_port"
            restart_panel || true
            _sync_caddy_if_active "$new_port" "$PANEL_PATH"
            ;;
        set-listen)
            require_deployed || return 1
            require_running  || return 1
            get_panel_info || true
            local new_listen="${1:-}"
            [[ "$new_listen" == "all" || "$new_listen" == "none" || "$new_listen" == "default" ]] && new_listen=""
            validate_listen_ip "$new_listen" || { error "Invalid listen IP: $new_listen"; return 1; }
            if $PROXY_ENABLED && ! _is_loopback_addr "$new_listen"; then
                warn "Setting a non-loopback listen IP while Caddy proxy is enabled exposes the panel directly!"
                $AUTO_YES || confirm "Continue with direct exposure?" || return 0
            fi
            if [[ -n "$new_listen" ]]; then
                run "$(_xui_setting_cmd -listenIP "$new_listen")" >/dev/null 2>&1 || true
            fi
            xui_db_set "webListen" "$new_listen" || return 1
            success "Panel listen IP updated to '${new_listen:-0.0.0.0}'"
            restart_panel || true
            ;;
        set-webpath)
            require_deployed || return 1
            require_running  || return 1
            get_panel_info || true
            load_webpanel_conf
            local new_path="${1:-}"
            if [[ "$new_path" == "random" ]]; then
                new_path="/$(generate_random_string 12)/"
            else
                new_path=$(_normalize_webpath "$new_path")
            fi
            if ! validate_webpath "$new_path"; then
                error "Invalid path (allowed: alphanumeric, '/', '_', '-'; max 128 chars; no '..' or '//')"
                return 1
            fi
            if $PROXY_ENABLED && [[ "$new_path" == "/" ]]; then
                error "Web Base Path cannot be '/' while Caddy camouflage site is active"
                return 1
            fi
            if $WEBPANEL_ENABLED && _paths_overlap "$new_path" "$WEBPANEL_PATH"; then
                error "Web Base Path '$new_path' overlaps WebPanel path '$WEBPANEL_PATH'"
                return 1
            fi
            if $PROXY_ENABLED && [[ "$SUB_MODE" == "same" ]]; then
                if _paths_overlap "$new_path" "$SUB_PATH" || _paths_overlap "$new_path" "$SUB_JSON_PATH"; then
                    error "Web Base Path '$new_path' overlaps subscription paths"
                    return 1
                fi
            fi
            run "$(_xui_setting_cmd -webBasePath "$new_path")" || return 1
            success "Web Base Path set to ${new_path}"
            restart_panel || true
            _sync_caddy_if_active "$PANEL_PORT" "$new_path"
            ;;
        set-security)
            require_deployed || return 1
            require_running  || return 1
            get_panel_info || true
            local new_age="${1:-keep}" new_wdom="${2:-keep}" changed=false
            if [[ "$new_age" != "keep" && -n "$new_age" ]]; then
                if ! [[ "$new_age" =~ ^[0-9]+$ ]] || (( 10#$new_age < 5 || 10#$new_age > 10080 )); then
                    error "Invalid session timeout (must be 5..10080 minutes)"
                    return 1
                fi
                xui_db_set "sessionMaxAge" "$(( 10#$new_age ))" || return 1
                success "Session timeout set to $(( 10#$new_age )) minute(s)"
                changed=true
            fi
            if [[ "$new_wdom" != "keep" ]]; then
                if [[ "$new_wdom" == "none" || "$new_wdom" == "-" || -z "$new_wdom" ]]; then
                    xui_db_set "webDomain" "" || return 1
                    success "Cleared webDomain"
                    changed=true
                else
                    validate_domain "$new_wdom" || { error "Invalid domain: $new_wdom"; return 1; }
                    xui_db_set "webDomain" "$new_wdom" || return 1
                    success "Panel webDomain set to ${new_wdom}"
                    changed=true
                fi
            fi
            if $changed; then
                restart_panel || true
            else
                info "No panel security settings changed"
            fi
            ;;
        set-sub)
            require_deployed || return 1
            require_running  || return 1
            get_panel_info || true
            load_webpanel_conf
            local s_en="true" s_mode="$SUB_MODE" s_dom="${SUB_DOMAIN_DB:-$SUB_DOMAIN}"
            local s_listen="${SUB_LISTEN_DB:-}" s_port="${SUB_PORT_DB:-${SUB_PORT:-2096}}"
            local s_path="${SUB_PATH_DB:-${SUB_PATH:-/sub/}}" s_json_en="${SUB_JSON_ENABLE_DB:-true}"
            local s_json_path="${SUB_JSON_PATH_DB:-${SUB_JSON_PATH:-/json/}}" s_enc="${SUB_ENCRYPT_DB:-true}"
            local kv k v
            for kv in "$@"; do
                [[ "$kv" == *=* ]] || continue
                k="${kv%%=*}"
                v="${kv#*=}"
                case "$k" in
                    enable)      [[ "$v" == "false" ]] && s_en="false" || s_en="true" ;;
                    mode)        s_mode="$v" ;;
                    domain)      s_dom="$v" ;;
                    listen)      [[ "$v" == "all" || "$v" == "0.0.0.0" ]] && s_listen="" || s_listen="$v" ;;
                    port)        s_port="$v" ;;
                    path)        s_path="$v" ;;
                    json_enable) [[ "$v" == "false" ]] && s_json_en="false" || s_json_en="true" ;;
                    json_path)   s_json_path="$v" ;;
                    encrypt)     [[ "$v" == "false" ]] && s_enc="false" || s_enc="true" ;;
                    *)           error "Unknown subscription parameter: $k"; return 1 ;;
                esac
            done

            if [[ "$s_en" == "false" ]]; then
                xui_db_set "subEnable" "false" || return 1
                if $PROXY_ENABLED && [[ "$SUB_MODE" != "none" ]]; then
                    SUB_MODE="none"
                    _clear_subscription_proxy_db
                    save_proxy_conf || true
                    _sync_caddy_if_active "$PANEL_PORT" "$PANEL_PATH" || return 1
                fi
                success "Subscription server disabled"
                restart_panel || true
                return 0
            fi

            if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
                [[ "$s_mode" == "dedicated" || "$s_mode" == "same" ]] || { error "Proxy subscription mode must be dedicated or same"; return 1; }
                s_listen="127.0.0.1"
                if [[ "$s_mode" == "dedicated" ]]; then
                    if ! validate_domain "$s_dom" || [[ "$s_dom" == "$PROXY_DOMAIN" ]]; then
                        error "Valid subscription domain different from $PROXY_DOMAIN is required"
                        return 1
                    fi
                else
                    s_dom="$PROXY_DOMAIN"
                fi
            else
                if [[ "$s_dom" == "none" || "$s_dom" == "-" ]]; then
                    s_dom=""
                elif [[ -n "$s_dom" ]]; then
                    validate_domain "$s_dom" || { error "Invalid subscription domain: $s_dom"; return 1; }
                fi
                validate_listen_ip "$s_listen" || { error "Invalid subscription listen IP: $s_listen"; return 1; }
            fi

            validate_port "$s_port" || { error "Invalid subscription port: $s_port"; return 1; }
            [[ "$s_port" == "$PANEL_PORT" ]] && { error "Subscription port must differ from panel port ($PANEL_PORT)"; return 1; }
            if $PROXY_ENABLED && [[ "$s_port" == "$PROXY_PORT" ]]; then
                error "Internal subscription port cannot equal Caddy HTTPS port ($PROXY_PORT)"
                return 1
            fi
            local inbounds_list=""
            inbounds_list=$(get_xui_inbounds || true)
            if [[ -n "$inbounds_list" ]]; then
                local i_id i_en i_proto i_listen i_port i_rem i_net i_sec i_path i_fw
                while IFS='|' read -r i_id i_en i_proto i_listen i_port i_rem i_net i_sec i_path i_fw; do
                    _is_inbound_enabled "$i_en" || continue
                    if [[ "$i_port" == "$s_port" ]]; then
                        error "Inbound #${i_id} (${i_rem:-unnamed}, ${i_proto}/${i_net}) already uses port ${s_port}"
                        return 1
                    fi
                done <<< "$inbounds_list"
            fi

            s_path=$(_normalize_webpath "$s_path")
            if [[ "$s_path" == "/" ]] || ! validate_webpath "$s_path"; then
                error "Invalid subscription path: $s_path"
                return 1
            fi
            s_json_path=$(_normalize_webpath "$s_json_path")
            if [[ "$s_json_path" == "/" ]] || ! validate_webpath "$s_json_path" || _paths_overlap "$s_path" "$s_json_path"; then
                error "Invalid or overlapping JSON subscription path: $s_json_path"
                return 1
            fi
            if $PROXY_ENABLED && [[ "$s_mode" == "same" ]]; then
                if _paths_overlap "$s_path" "$PANEL_PATH" || _paths_overlap "$s_json_path" "$PANEL_PATH"; then
                    error "Subscription paths overlap panel path '$PANEL_PATH'"
                    return 1
                fi
                if $WEBPANEL_ENABLED && { _paths_overlap "$s_path" "$WEBPANEL_PATH" || _paths_overlap "$s_json_path" "$WEBPANEL_PATH"; }; then
                    error "Subscription paths overlap WebPanel path '$WEBPANEL_PATH'"
                    return 1
                fi
            fi

            local new_sub_uri="" new_json_uri="" new_sub_cert="${SUB_CERT_DB:-}" new_sub_key="${SUB_KEY_DB:-}"
            if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
                local port_sfx=""
                [[ "$PROXY_PORT" != "443" ]] && port_sfx=":${PROXY_PORT}"
                new_sub_uri="https://${s_dom}${port_sfx}${s_path}"
                new_json_uri="https://${s_dom}${port_sfx}${s_json_path}"
                new_sub_cert=""
                new_sub_key=""
            else
                local sub_scheme="http" sub_port_sfx=":${s_port}"
                if [[ -n "$new_sub_cert" && -n "$new_sub_key" ]]; then
                    sub_scheme="https"
                    [[ "$s_port" == "443" ]] && sub_port_sfx=""
                else
                    [[ "$s_port" == "80" ]] && sub_port_sfx=""
                fi
                local ext_host="${s_dom:-$(get_target_ip)}"
                if [[ -n "$sub_port_sfx" ]]; then
                    new_sub_uri="${sub_scheme}://$(_format_host_port "$ext_host" "$s_port")${s_path}"
                    new_json_uri="${sub_scheme}://$(_format_host_port "$ext_host" "$s_port")${s_json_path}"
                else
                    new_sub_uri="${sub_scheme}://${ext_host}${s_path}"
                    new_json_uri="${sub_scheme}://${ext_host}${s_json_path}"
                fi
            fi

            _apply_subscription_db_settings "true" "$s_listen" "$s_dom" "$s_port" "$s_path" \
                "$s_json_en" "$s_json_path" "$s_enc" "$new_sub_cert" "$new_sub_key" \
                "$new_sub_uri" "$new_json_uri" || return 1

            if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
                SUB_MODE="$s_mode"
                [[ "$s_mode" == "dedicated" ]] && SUB_DOMAIN="$s_dom" || SUB_DOMAIN=""
                SUB_PORT="$s_port"
                SUB_PATH="$s_path"
                SUB_JSON_PATH="$s_json_path"
                save_proxy_conf || return 1
                _sync_caddy_if_active "$PANEL_PORT" "$PANEL_PATH" || return 1
            fi

            success "Subscription configuration updated (${new_sub_uri})"
            compose restart 3xui >/dev/null || compose restart >/dev/null || true
            invalidate_status
            verify_panel_loaded 10 || true
            verify_subscription_endpoint 8 || true
            ;;
        reset-2fa)
            require_deployed || return 1
            require_running  || return 1
            run "$(_xui_setting_cmd -resetTwoFactor=true)" || return 1
            success "Two-Factor Authentication reset"
            restart_panel || true
            ;;
        reset-credentials)
            require_deployed || return 1
            require_running  || return 1
            local new_user="" new_pass=""
            IFS= read -r new_user || true
            IFS= read -r new_pass || true
            if [[ -z "$new_user" || "$new_user" =~ [[:space:]] || "$new_user" == -* ]] || has_control_chars "$new_user"; then
                new_pass=""
                error "Invalid username (must be non-empty without spaces, leading '-', or control characters)"
                return 1
            fi
            if ! validate_strong_password "$new_pass"; then
                new_pass=""
                error "Password does not meet security requirements (min 12 chars, no control chars or weak defaults, >=16 chars or >=2 classes)"
                return 1
            fi
            local cred_out="" cred_rc=0
            cred_out=$(_xui_set_credentials_stdin "$new_user" "$new_pass") || cred_rc=$?
            new_pass=""
            if (( cred_rc != 0 )) || printf '%s' "$cred_out" | grep -qiE '(failed|error)'; then
                error "Update credentials failed"
                [[ -n "$cred_out" ]] && echo "  $cred_out"
                return 1
            fi
            get_panel_info || true
            success "Credentials updated (username: ${PANEL_USER:-$new_user})"
            restart_panel || true
            ;;
        *)
            error "Unknown settings action: $subcmd (use: show|set-port|set-listen|set-webpath|set-security|set-sub|reset-2fa|reset-credentials)"
            return 1
            ;;
    esac
}

manage_panel_settings() {
    require_deployed || return 1
    require_running  || return 1

    while true; do
        get_panel_info || true
        local ip
        ip=$(get_target_ip)
        local url
        url=$(format_panel_url "$ip")

        local sub_summary="disabled"
        if [[ "$SUB_ENABLE_DB" == "true" ]]; then
            sub_summary="${SUB_DOMAIN_DB:-${SUB_LISTEN_DB:-0.0.0.0}:${SUB_PORT_DB:-2096}}"
        fi
        local header_text="  Panel URL : ${BOLD}${url}${NC}\n  Username  : ${BOLD}${PANEL_USER:-admin}${NC}\n  Port/Path : ${PANEL_PORT}  ${PANEL_PATH}\n  Listen IP : ${PANEL_LISTEN:-0.0.0.0}  Domain: ${PANEL_DOMAIN:-(none)}\n  2FA/Sess  : 2FA=${PANEL_2FA:-false}  Session=${PANEL_SESSION_AGE:-default}m\n  Subs      : ${sub_summary}"
        if [[ "$PANEL_HAS_DEFAULT" == "true" ]]; then
            header_text+="\n  ${YELLOW}! Default credentials detected — change them!${NC}"
        fi

        local opts=(
            "Show full panel & subscription settings"
            "Change panel port"
            "Change panel listen IP (webListen)"
            "Change / randomize Web Base Path"
            "Configure subscription domain & network"
            "Harden auth, session & web domain"
            "Reset admin username & password"
            "Reset / Disable 2FA"
            "Back"
        )

        tui_select "Panel Settings & Security" "$header_text" "${opts[@]}"
        local sub=$?
        clear_screen
        case "$sub" in
            0)
                echo ""
                run_it "$(_xui_setting_cmd -show=true)"
                echo ""
                run_it "$(_xui_setting_cmd -getListen=true)"
                echo ""
                run_it "$(_xui_setting_cmd -getCert=true)"
                echo ""
                echo -e "  Effective URL : ${BOLD}${url}${NC}"
                echo -e "  webDomain     : ${PANEL_DOMAIN:-(none)}"
                echo -e "  2FA / Session : 2FA=${PANEL_2FA:-false}  sessionMaxAge=${PANEL_SESSION_AGE:-default}m"
                echo -e "  Subscription  : enable=${SUB_ENABLE_DB:-unset}  listen=${SUB_LISTEN_DB:-0.0.0.0}  port=${SUB_PORT_DB:-2096}  domain=${SUB_DOMAIN_DB:-(none)}"
                echo -e "  Sub URI/JSON  : ${SUB_URI_DB:-(auto)}  |  jsonEnable=${SUB_JSON_ENABLE_DB:-false}  ${SUB_JSON_URI_DB:-(auto)}"
                ;;
            1) change_panel_port ;;
            2) change_panel_listen_ip ;;
            3) change_panel_webpath ;;
            4) configure_subscription_settings ;;
            5) configure_panel_security ;;
            6) reset_credentials ;;
            7) reset_panel_2fa ;;
            8|255) _SKIP_PAUSE=true; return ;;
        esac
        echo ""
        read -rp "  Press Enter..."
    done
}

# ─── Version & Compose Generation ───────────────────────────────────────────
get_latest_version() {
    info "Fetching latest 3X-UI release tag..." >&2
    local tag=""
    local releases_url="https://github.com/mhsanaei/3x-ui/releases/latest"
    local api_url="https://api.github.com/repos/mhsanaei/3x-ui/releases/latest"

    if command -v curl &>/dev/null; then
        local effective_url
        effective_url=$(curl -fsSLI --proto '=https' --tlsv1.2 -o /dev/null -w '%{url_effective}' --max-time 10 "$releases_url" 2>/dev/null || true)
        if [[ "$effective_url" == */releases/tag/* ]]; then
            tag="${effective_url##*/}"
        fi
        if [[ -z "$tag" ]]; then
            tag=$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 10 "$api_url" 2>/dev/null \
                | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
        fi
    elif command -v wget &>/dev/null; then
        tag=$(wget -qO- --https-only --secure-protocol=TLSv1_2 --timeout=10 "$api_url" 2>/dev/null \
            | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
    fi

    if [[ -z "$tag" ]] || ! validate_tag "$tag"; then
        warn "Failed to fetch latest tag, defaulting to 'latest'" >&2
        tag="latest"
    fi
    printf '%s' "$tag"
}

_caddy_service_block() {
    cat <<'YAML'
  caddy:
    image: caddy:2-alpine
    container_name: 3xui_caddy
    network_mode: host
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    security_opt:
      - no-new-privileges:true
    volumes:
      - $PWD/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - $PWD/caddy/site/:/srv/site/:ro
      - $PWD/caddy/data/:/data/
      - $PWD/caddy/config/:/config/
      - $PWD/cert/:/root/cert/:ro
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped
YAML
}

generate_compose() {
    local db_type="${1:-sqlite}"
    local tag="${2:-latest}"
    local pg_user="${3:-xui}"
    local pg_pass="${4:-}"

    validate_tag "$tag" || tag="latest"

    local xui_env_file=""
    local xui_db_env=""
    local xui_depends=""
    local pg_service=""
    local caddy_service=""
    local env_content=""

    if run_q "test -f $(quote_sh "$INSTALL_DIR/caddy/Caddyfile")"; then
        caddy_service="
$(_caddy_service_block)"
    fi

    if [[ "$db_type" == "postgres" ]]; then
        local enc_pass
        enc_pass=$(urlencode "$pg_pass")
        env_content=$(printf 'POSTGRES_USER=%s\nPOSTGRES_PASSWORD=%s\nPOSTGRES_DB=xui\nXUI_DB_DSN=postgres://%s:%s@127.0.0.1:5432/xui?sslmode=disable\n' \
            "$pg_user" "$pg_pass" "$pg_user" "$enc_pass")
        xui_env_file="
    env_file:
      - .env"
        xui_db_env="
      XUI_DB_TYPE: \"postgres\""
        xui_depends="
    depends_on:
      postgres:
        condition: service_healthy"
        pg_service="

  postgres:
    image: postgres:16-alpine
    container_name: 3xui_postgres
    env_file:
      - .env
    environment:
      POSTGRES_INITDB_ARGS: \"--auth-host=scram-sha-256 --auth-local=scram-sha-256\"
    security_opt:
      - no-new-privileges:true
    volumes:
      - \$PWD/pgdata/:/var/lib/postgresql/data
    ports:
      - \"127.0.0.1:5432:5432\"
    healthcheck:
      test: [\"CMD-SHELL\", \"pg_isready -U \$\${POSTGRES_USER:-xui} -d \$\${POSTGRES_DB:-xui}\"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      driver: \"json-file\"
      options:
        max-size: \"10m\"
        max-file: \"3\"
    restart: unless-stopped"
    fi

    local compose_content
    compose_content=$(cat <<YAML
services:
  3xui:
    image: ghcr.io/mhsanaei/3x-ui:${tag}
    container_name: 3xui_app
    cap_add:
      - NET_ADMIN
      - NET_RAW
    security_opt:
      - no-new-privileges:true${xui_env_file}
    volumes:
      - \$PWD/db/:/etc/x-ui/
      - \$PWD/cert/:/root/cert/
    environment:
      XRAY_VMESS_AEAD_FORCED: "true"
      XUI_ENABLE_FAIL2BAN: "true"${xui_db_env}
    tty: true
    network_mode: host${xui_depends}
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped${pg_service}${caddy_service}
YAML
)

    run "mkdir -p $(quote_sh "$INSTALL_DIR")" || return 1

    if [[ -n "$env_content" ]]; then
        if $REMOTE; then
            printf '%s' "$env_content" | ssh_cmd "umask 077 && cat > $(quote_sh "$INSTALL_DIR/.env") && chmod 600 $(quote_sh "$INSTALL_DIR/.env")"
        else
            ( umask 077; printf '%s' "$env_content" > "$INSTALL_DIR/.env" )
            chmod 600 "$INSTALL_DIR/.env"
        fi
    fi

    if $REMOTE; then
        printf '%s\n' "$compose_content" | ssh_cmd "umask 077 && cat > $(quote_sh "$INSTALL_DIR/compose.yaml") && chmod 600 $(quote_sh "$INSTALL_DIR/compose.yaml")"
    else
        ( umask 077; printf '%s\n' "$compose_content" > "$INSTALL_DIR/compose.yaml" )
        chmod 600 "$INSTALL_DIR/compose.yaml"
    fi
}

_rollback_failed_update() {
    local target_tag="$1" prev_tag="$2" reason="$3"
    local q_cfg q_bak
    q_cfg=$(quote_sh "$INSTALL_DIR/compose.yaml")
    q_bak=$(quote_sh "$INSTALL_DIR/compose.yaml.bak")

    log_stage "update" "rollback" "Restoring previous version (${prev_tag:-backup}) after failed update to ${target_tag}..."
    if run_q "test -f $q_bak" && run "cp $q_bak $q_cfg && chmod 600 $q_cfg"; then
        compose up -d >/dev/null 2>&1 || true
        invalidate_status
        report_diagnostic "CRITICAL" "apply_version(${target_tag})" \
            "$reason" \
            "3xui_app / compose.yaml" \
            "Automatically rolled back compose.yaml to '${prev_tag:-previous}'. Check logs with 'manage.sh logs deploy'."
    else
        report_diagnostic "CRITICAL" "apply_version(${target_tag})" \
            "$reason (AND automatic rollback of compose.yaml.bak failed)" \
            "3xui_app / compose.yaml" \
            "Manually inspect $INSTALL_DIR/compose.yaml and restore from $BACKUP_DIR."
    fi
}

apply_version() {
    local new_tag="$1"
    if ! validate_tag "$new_tag"; then
        report_diagnostic "ERROR" "apply_version" \
            "Invalid version tag format: '${new_tag}'" \
            "compose.yaml" \
            "Provide a valid tag such as v2.6.0 or v3.0.0."
        return 1
    fi

    is_deployed || { error "compose.yaml not found at $INSTALL_DIR"; return 1; }
    detect_compose || { error "Docker Compose not found"; return 1; }

    echo ""
    log_stage "update" "classify" "Checking compatibility for target release ${new_tag}..."
    local cur_ver cls
    cur_ver=$(xui_detect_version || true)
    cls=$(xui_classify_version "$new_tag" "$cur_ver")
    info "Version check: current='${cur_ver:-unknown}' target='${new_tag}' classification='${cls}'"

    case "$cls" in
        unsupported_legacy|unsupported_major)
            report_diagnostic "CRITICAL" "apply_version(${new_tag})" \
                "Target 3x-ui version '${new_tag}' (${cls}) is outside tested compatibility range (v${XUI_COMPAT_MIN_VERSION}..v${XUI_COMPAT_MAX_TESTED_MAJOR}.x)." \
                "3xui_app" \
                "Update 3xui-deploy first or re-run with --force-compat if you want to bypass compatibility checks."
            if ! $FORCE_COMPAT; then
                return 1
            fi
            warn "Proceeding past unsupported version guard due to --force-compat."
            ;;
        major_upgrade)
            warn "Major 3x-ui version jump detected (${cur_ver:-unknown} -> ${new_tag}). Database or CLI changes may occur."
            if $INTERACTIVE && ! $AUTO_YES; then
                confirm "Continue major upgrade to ${new_tag}?" || { info "Cancelled"; return 0; }
            fi
            ;;
        unknown_tag)
            warn "Non-semver tag '${new_tag}' selected; explicit version tags (e.g., v3.x.y) are safer for reproducibility."
            if $INTERACTIVE && ! $AUTO_YES; then
                confirm "Continue applying '${new_tag}'?" || { info "Cancelled"; return 0; }
            fi
            ;;
    esac

    local target_image="ghcr.io/mhsanaei/3x-ui:${new_tag}"
    log_stage "update" "pull" "Pulling ${target_image} before modifying compose.yaml..."
    if ! run "docker pull $(quote_sh "$target_image")"; then
        report_diagnostic "ERROR" "apply_version(${new_tag})" \
            "Failed to pull container image ${target_image}" \
            "Docker registry / network" \
            "Existing deployment was NOT modified. Verify network access and tag name, then retry."
        return 1
    fi

    log_stage "update" "preflight" "Running read-only compatibility preflight on ${target_image}..."
    if ! xui_preflight_image "$new_tag"; then
        if ! $FORCE_COMPAT; then
            warn "Aborted before modifying live stack."
            return 1
        fi
        warn "Continuing despite preflight failure because --force-compat is set."
    fi

    local q_cfg q_bak q_tmp
    q_cfg=$(quote_sh "$INSTALL_DIR/compose.yaml")
    q_bak=$(quote_sh "$INSTALL_DIR/compose.yaml.bak")
    q_tmp=$(quote_sh "$INSTALL_DIR/compose.yaml.tmp")

    log_stage "update" "snapshot" "Creating pre-update configuration & data snapshot..."
    run "(umask 077 && cp $q_cfg $q_bak && chmod 600 $q_bak)" || { error "Failed to backup compose.yaml"; return 1; }
    _perform_backup "pre_update" || warn "Pre-update data backup failed; compose.yaml.bak is preserved."

    log_stage "update" "apply" "Updating compose.yaml to ${new_tag} and recreating containers..."
    if ! run "awk -v tag=$(quote_sh "$new_tag") 'index(\$0, \"image: ghcr.io/mhsanaei/3x-ui:\") > 0 { sub(/3x-ui:.*/, \"3x-ui:\" tag) } { print }' $q_cfg > $q_tmp && chmod 600 $q_tmp && mv $q_tmp $q_cfg"; then
        run_q "cp $q_bak $q_cfg && chmod 600 $q_cfg" || true
        error "Failed to update version tag in compose.yaml"
        return 1
    fi

    if ! compose up -d; then
        _rollback_failed_update "$new_tag" "$cur_ver" "Container recreation (compose up -d) failed"
        return 1
    fi

    invalidate_status
    log_stage "update" "verify" "Verifying container runtime, schema compatibility, and web endpoints..."
    local verify_err=""
    if ! is_running; then
        verify_err="3xui_app container did not stay running after upgrade"
    elif ! xui_probe_capabilities; then
        verify_err="Post-update capability/schema compatibility probe failed"
    elif ! verify_panel_loaded 12; then
        verify_err="3X-UI Web UI did not respond cleanly after upgrade (status=${PANEL_LOAD_STATUS})"
    fi

    if [[ -z "$verify_err" ]] && { [[ "$SUB_MODE" != "none" || "$SUB_ENABLE_DB" == "true" ]]; }; then
        if ! verify_subscription_endpoint 6; then
            verify_err="Subscription endpoint verification failed after upgrade (status=${SUB_VERIFY_STATUS})"
        fi
    fi

    if [[ -n "$verify_err" ]]; then
        _rollback_failed_update "$new_tag" "$cur_ver" "$verify_err"
        return 1
    fi

    success "Panel successfully updated and verified on version $new_tag"
    compose ps || true
}

# ─── Deployment & Lifecycle Actions ─────────────────────────────────────────
post_deploy_harden() {
    local wait_ok=false i
    for (( i=0; i<15; i++ )); do
        if run_q "$(_xui_setting_cmd -show=true)"; then
            wait_ok=true
            break
        fi
        sleep 1
    done
    $wait_ok || { warn "Container still initializing; use 'Panel settings & security' later to harden."; return 0; }

    echo ""
    confirm "Harden panel now? (customize port, Web Base Path, and admin credentials)" || return 0

    local h_port h_path h_user h_pass="" h_pass_confirm="" auto_pass=false
    read -rp "  Panel port [2053, or enter custom 1-65535]: " h_port
    h_port="${h_port:-2053}"
    if ! validate_port "$h_port"; then
        warn "Invalid port '$h_port'; keeping 2053"
        h_port="2053"
    fi

    read -rp "  Web Base Path [Enter to auto-generate random path]: " h_path
    if [[ -z "$h_path" ]]; then
        h_path="/$(generate_random_string 12)/"
    else
        [[ "$h_path" != /* ]] && h_path="/$h_path"
        [[ "$h_path" != */ ]] && h_path="${h_path}/"
        if ! validate_webpath "$h_path"; then
            warn "Invalid path; auto-generating random path"
            h_path="/$(generate_random_string 12)/"
        fi
    fi

    read -rp "  Admin username [admin]: " h_user
    h_user="${h_user:-admin}"
    if [[ "$h_user" =~ [[:space:]] || "$h_user" == -* ]] || has_control_chars "$h_user"; then
        warn "Invalid username; defaulting to 'admin'"
        h_user="admin"
    fi

    local pw_tries=0
    while (( pw_tries < 3 )); do
        read -rs -p "  Admin password [Enter to auto-generate 20-char password]: " h_pass
        echo ""
        if [[ -z "$h_pass" ]]; then
            h_pass=$(generate_random_string 20)
            auto_pass=true
            break
        fi
        if ! validate_strong_password "$h_pass"; then
            warn "Password must be >=12 chars, no control chars or common defaults, and >=16 chars or >=2 character classes."
            h_pass=""
            pw_tries=$(( pw_tries + 1 ))
            continue
        fi
        read -rs -p "  Confirm admin password: " h_pass_confirm
        echo ""
        if [[ "$h_pass" != "$h_pass_confirm" ]]; then
            warn "Passwords do not match."
            h_pass=""
            h_pass_confirm=""
            pw_tries=$(( pw_tries + 1 ))
            continue
        fi
        h_pass_confirm=""
        break
    done
    if [[ -z "$h_pass" ]]; then
        warn "Too many invalid attempts; auto-generating a strong 20-char password."
        h_pass=$(generate_random_string 20)
        auto_pass=true
    fi

    local hard_out="" hard_rc=0
    hard_out=$(_xui_set_credentials_stdin "$h_user" "$h_pass" "$h_port" "$h_path") || hard_rc=$?
    if (( hard_rc != 0 )) || printf '%s' "$hard_out" | grep -qiE '(failed|error)'; then
        h_pass=""
        warn "Could not apply settings automatically"
        return 0
    fi

    xui_db_set "sessionMaxAge" "60" >/dev/null 2>&1 || true

    info "Restarting container to apply hardened settings..."
    compose restart 3xui >/dev/null || compose restart >/dev/null || true
    for (( i=0; i<10; i++ )); do
        run_q "$(_xui_setting_cmd -show=true)" && break
        sleep 1
    done

    echo ""
    success "Panel hardened!"
    echo -e "  Username : ${BOLD}${h_user}${NC}"
    if $auto_pass; then
        echo -e "  Password : ${BOLD}${YELLOW}${h_pass}${NC}  (save this now!)"
    else
        echo -e "  Password : ${BOLD}(as entered)${NC}"
    fi
    h_pass=""
}

deploy() {
    local req_db="${1:-}" req_pg_user="${2:-}"
    if is_deployed; then
        warn "Already deployed at $INSTALL_DIR"
        confirm "Redeploy (overwrite compose.yaml)?" || return 0
    fi

    ensure_docker || { error "Could not install Docker"; return 1; }

    local db_type="sqlite"
    if [[ -n "$req_db" ]]; then
        case "$req_db" in
            sqlite|postgres) db_type="$req_db" ;;
            *) error "Unsupported database type '$req_db' (use: sqlite or postgres)"; return 1 ;;
        esac
    elif $INTERACTIVE; then
        tui_select "Database Selection" "Choose a backend for 3X-UI:" "SQLite (default)" "PostgreSQL" "Cancel"
        local sel=$?
        clear_screen
        case "$sel" in
            0) db_type="sqlite" ;;
            1) db_type="postgres" ;;
            2|255) info "Cancelled"; return 0 ;;
        esac
    fi

    local pg_user="${req_pg_user:-xui}" pg_pass="" pg_auto=false
    if [[ "$db_type" == "postgres" ]]; then
        if [[ -z "$req_pg_user" ]] && $INTERACTIVE; then
            echo ""
            read -rp "  Postgres user [xui]: " pg_user
            pg_user="${pg_user:-xui}"
        fi
        if ! validate_pg_ident "$pg_user"; then
            error "Invalid Postgres username (alphanumeric/_/-, starting with letter or _)"
            return 1
        fi
        if $INTERACTIVE; then
            read -rs -p "  Postgres password [Enter to auto-generate]: " pg_pass
            echo ""
        fi
        if [[ -z "$pg_pass" ]]; then
            pg_pass=$(generate_random_string 20)
            pg_auto=true
        elif has_control_chars "$pg_pass"; then
            error "Invalid characters in password"
            return 1
        fi
    fi

    local latest_tag
    latest_tag=$(get_latest_version)

    run "mkdir -p $(quote_sh "$INSTALL_DIR/db") $(quote_sh "$INSTALL_DIR/cert") && chmod 700 $(quote_sh "$INSTALL_DIR/db") $(quote_sh "$INSTALL_DIR/cert")" || return 1

    info "Generating configuration for version $latest_tag..."
    generate_compose "$db_type" "$latest_tag" "$pg_user" "$pg_pass" || { pg_pass=""; error "Failed to generate compose.yaml"; return 1; }

    info "Pulling images..."
    compose pull || { pg_pass=""; error "Image pull failed"; return 1; }

    info "Starting containers..."
    compose up -d || { pg_pass=""; error "Container start failed"; return 1; }

    $INTERACTIVE && post_deploy_harden
    if $INTERACTIVE && is_running; then
        echo ""
        confirm "Set up Caddy reverse proxy now? (custom domain + HTTPS + camouflage + subs)" && setup_reverse_proxy || true
    fi

    get_panel_info || true
    verify_panel_loaded 12 || true
    local panel_ip url
    panel_ip=$(get_target_ip)
    url=$(format_panel_url "$panel_ip")

    invalidate_status
    echo ""
    success "Deployed successfully!"
    echo -e "  Dir       : ${BOLD}$INSTALL_DIR${NC}"
    echo -e "  Version   : ${BOLD}$latest_tag${NC}"
    echo -e "  Database  : ${BOLD}$db_type${NC}"
    if $pg_auto && $INTERACTIVE; then
        echo -e "  PG Pass   : ${BOLD}${YELLOW}$pg_pass${NC}  (also stored in $INSTALL_DIR/.env)"
    elif [[ "$db_type" == "postgres" ]]; then
        echo -e "  PG Pass   : stored securely in $INSTALL_DIR/.env"
    fi
    pg_pass=""
    echo -e "  Panel URL : ${BOLD}$url${NC}"
    if $PROXY_ENABLED && is_caddy_running; then
        echo -e "  Backend   : ${PANEL_LISTEN:-127.0.0.1}:${PANEL_PORT}${PANEL_PATH}"
        [[ -n "$PROXY_SUB_URL" ]] && echo -e "  Subs URL  : ${BOLD}${PROXY_SUB_URL}${NC}"
    fi
    if [[ "$PANEL_HAS_DEFAULT" == "true" ]]; then
        echo -e "  ${YELLOW}Credentials: admin / admin (change immediately!)${NC}"
    fi
    echo ""
}

update_panel_latest() {
    require_deployed || return 1
    local target_tag="${1:-}"
    if [[ -z "$target_tag" ]]; then
        target_tag=$(get_latest_version)
    fi
    apply_version "$target_tag"
}

change_version_manually() {
    require_deployed || return 1
    echo ""
    echo "  Releases: https://github.com/mhsanaei/3x-ui/tags"
    local target_version
    read -rp "  Enter version tag (e.g., v2.5.0): " target_version
    if [[ -z "$target_version" ]] || ! validate_tag "$target_version"; then
        error "Invalid version tag"
        return 1
    fi
    apply_version "$target_version"
}

rollback_version() {
    require_deployed || return 1
    if ! run_q "test -f $(quote_sh "$INSTALL_DIR/compose.yaml.bak")"; then
        error "No backup compose.yaml.bak found. Cannot rollback."
        return 1
    fi

    local current_ver bak_ver
    current_ver=$(run_out "awk -F: '/image: ghcr\.io\/mhsanaei\/3x-ui:/ {print \$NF; exit}' $(quote_sh "$INSTALL_DIR/compose.yaml")" || true)
    bak_ver=$(run_out "awk -F: '/image: ghcr\.io\/mhsanaei\/3x-ui:/ {print \$NF; exit}' $(quote_sh "$INSTALL_DIR/compose.yaml.bak")" || true)

    echo ""
    echo -e "  Current version : ${BOLD}${current_ver:-unknown}${NC}"
    echo -e "  Backup version  : ${BOLD}${bak_ver:-unknown}${NC}"
    echo ""
    confirm "Rollback to ${bak_ver:-previous version}?" || return 0

    info "Restoring previous configuration..."
    run "cp $(quote_sh "$INSTALL_DIR/compose.yaml.bak") $(quote_sh "$INSTALL_DIR/compose.yaml") && chmod 600 $(quote_sh "$INSTALL_DIR/compose.yaml")" \
        || { error "Failed to restore compose.yaml.bak"; return 1; }

    info "Recreating containers with previous version..."
    compose up -d || { error "Container start failed"; return 1; }
    invalidate_status
    success "Successfully rolled back to ${bak_ver:-previous version}"
    compose ps || true
}

remove_panel() {
    is_deployed || { warn "Not deployed"; return 0; }
    detect_compose || { warn "Docker Compose not found"; return 1; }

    tui_select "Remove 3X-UI" "What would you like to remove?" "Containers only (keep data)" "Everything (containers + data)" "Cancel"
    local sel=$?
    clear_screen

    case "$sel" in
        0)
            compose down
            invalidate_status
            success "Containers removed (data kept in $INSTALL_DIR)"
            ;;
        1)
            validate_safe_dir "$INSTALL_DIR" || { error "Refusing to delete unsafe directory: $INSTALL_DIR"; return 1; }
            confirm "Delete ALL data at $INSTALL_DIR? Irreversible!" || { info "Cancelled"; return 0; }
            run "cd $(quote_sh "$INSTALL_DIR") && $COMPOSE_CMD down -v 2>/dev/null || true"
            run "rm -rf $(quote_sh "$INSTALL_DIR")"
            invalidate_status
            success "Everything removed"
            ;;
        2|255) info "Cancelled" ;;
    esac
}

start_panel() {
    require_deployed || return 1
    compose up -d || return 1
    invalidate_status
    success "Started"
    verify_panel_loaded 10 || true
}
stop_panel()    { require_deployed || return 1; compose stop    || return 1; invalidate_status; success "Stopped"; }
restart_panel() {
    require_deployed || return 1
    compose restart || return 1
    invalidate_status
    success "Restarted"
    verify_panel_loaded 10 || true
}

status_panel() {
    echo ""
    [[ -z "$_STATUS" ]] && refresh_status

    if [[ "$_STATUS" == "not_deployed" ]]; then
        echo -e "  Deployed: ${RED}No${NC}\n"
        return 0
    fi

    echo -e "  Deployed: ${GREEN}Yes${NC} ($INSTALL_DIR)"
    compose ps || true
    echo ""

    if [[ "$_STATUS" == "running" ]]; then
        get_panel_info || true
        local panel_ip url
        panel_ip=$(get_target_ip)
        url=$(format_panel_url "$panel_ip")
        echo -e "  Panel   : ${GREEN}Running${NC} ${ARROW} ${BOLD}${url}${NC}"
        if $PROXY_ENABLED && is_caddy_running; then
            echo -e "  Proxy   : ${GREEN}Caddy Active${NC} (backend ${PANEL_LISTEN:-127.0.0.1}:${PANEL_PORT}${PANEL_PATH})"
            [[ -n "$PROXY_SUB_URL" ]] && echo -e "  Subs    : ${BOLD}${PROXY_SUB_URL}${NC}"
        elif [[ -n "$PANEL_LISTEN" ]]; then
            echo -e "  Listen  : $(_format_host_port "$PANEL_LISTEN" "$PANEL_PORT")"
        fi
        if verify_panel_loaded 2 >/dev/null 2>&1; then
            echo -e "  Web UI  : ${GREEN}Reachable & serving 3X-UI${NC}"
        else
            echo -e "  Web UI  : ${YELLOW}Not verified ($PANEL_LOAD_STATUS)${NC}"
        fi
        if [[ "$PANEL_HAS_DEFAULT" == "true" ]]; then
            echo -e "  ${YELLOW}! Default credentials still active — change them in Panel Settings${NC}"
        fi
    else
        echo -e "  Panel   : ${RED}Stopped${NC}"
    fi
    echo ""
}

logs_panel() {
    local mode="${1:-}"
    if [[ "$mode" == "deploy" ]]; then
        local lf
        lf=$(_resolve_log_file)
        if run_q "test -f $(quote_sh "$lf")"; then
            run "tail -n 200 $(quote_sh "$lf")"
        else
            info "No deployment log file found yet at $lf"
        fi
        return 0
    fi
    require_deployed || return 1

    if [[ -n "$mode" ]]; then
        case "$mode" in
            follow|-f) run_it "cd $(quote_sh "$INSTALL_DIR") && $COMPOSE_CMD logs -f" ;;
            all|full)  compose logs ;;
            *)
                if [[ "$mode" =~ ^[0-9]+$ ]]; then
                    compose logs --tail="$mode"
                else
                    error "Invalid logs mode: $mode"
                    return 1
                fi
                ;;
        esac
        return
    fi

    tui_select "Logs Viewer" "Select log source/length:" "Live follow (containers)" "Last 100 lines" "Last 500 lines" "Full container logs" "3xui-deploy operation logs" "Cancel"
    local sel=$?
    clear_screen

    case "$sel" in
        0) run_it "cd $(quote_sh "$INSTALL_DIR") && $COMPOSE_CMD logs -f" ;;
        1) compose logs --tail=100 ;;
        2) compose logs --tail=500 ;;
        3) compose logs ;;
        4) logs_panel deploy ;;
        5|255) info "Cancelled" ;;
    esac
}

launch_lazydocker() {
    require_deployed || return 1

    local check_cmd="command -v lazydocker &>/dev/null || test -x /usr/local/bin/lazydocker || test -x ~/.local/bin/lazydocker"
    if ! run_q "$check_cmd"; then
        if $INTERACTIVE && ! $AUTO_YES; then
            confirm "Lazydocker not found. Download verified release binary from GitHub?" || return 0
        fi
        info "Fetching latest lazydocker release..."
        local lzd_tag="" lzd_ver=""
        lzd_tag=$(run_out "curl -fsSLI --proto '=https' --tlsv1.2 -o /dev/null -w '%{url_effective}' --max-time 10 https://github.com/jesseduffield/lazydocker/releases/latest" || true)
        if [[ "$lzd_tag" == */releases/tag/* ]]; then
            lzd_tag="${lzd_tag##*/}"
        else
            lzd_tag=""
        fi
        if [[ -z "$lzd_tag" ]] || ! validate_tag "$lzd_tag"; then
            error "Could not determine latest lazydocker release tag"
            return 1
        fi
        lzd_ver="${lzd_tag#v}"
        local install_lzd_cmd
        install_lzd_cmd=$(cat <<EOF
set -e
umask 077
os_name=\$(uname -s)
arch_raw=\$(uname -m)
case "\$arch_raw" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7) arch="armv7" ;;
    *) echo "Unsupported arch: \$arch_raw" >&2; exit 1 ;;
esac
case "\$os_name" in
    Linux|Darwin) ;;
    *) echo "Unsupported OS: \$os_name" >&2; exit 1 ;;
esac
fname="lazydocker_${lzd_ver}_\${os_name}_\${arch}.tar.gz"
base_url="https://github.com/jesseduffield/lazydocker/releases/download/$(quote_sh "$lzd_tag")"
tmp=\$(mktemp -d /tmp/3xui-lzd.XXXXXX)
trap 'rm -rf "\$tmp"' EXIT
chmod 700 "\$tmp"
curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "\${base_url}/\${fname}" -o "\$tmp/\${fname}"
curl -fsSL --proto '=https' --tlsv1.2 --max-time 15 "\${base_url}/checksums.txt" -o "\$tmp/checksums.txt"
expected=\$(awk -v f="\${fname}" '\$2 == f {print \$1; exit}' "\$tmp/checksums.txt")
[ -n "\$expected" ] || { echo "Checksum entry missing for \${fname}" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "\$expected" "\$tmp/\${fname}" | sha256sum -c - >/dev/null
elif command -v shasum >/dev/null 2>&1; then
    printf '%s  %s\n' "\$expected" "\$tmp/\${fname}" | shasum -a 256 -c - >/dev/null
else
    echo "sha256sum/shasum unavailable to verify lazydocker" >&2
    exit 1
fi
tar -xzf "\$tmp/\${fname}" -C "\$tmp" lazydocker
install -m 0755 "\$tmp/lazydocker" /usr/local/bin/lazydocker
EOF
)
        run "$install_lzd_cmd" || { error "Failed to install verified lazydocker"; return 1; }
        success "Lazydocker ${lzd_tag} verified & installed."
    fi

    local lzd_path="lazydocker"
    if run_q "test -x /usr/local/bin/lazydocker"; then
        lzd_path="/usr/local/bin/lazydocker"
    elif run_q "test -x ~/.local/bin/lazydocker"; then
        lzd_path="~/.local/bin/lazydocker"
    fi

    info "Starting lazydocker UI..."
    run_it "cd $(quote_sh "$INSTALL_DIR") && $lzd_path"
    _SKIP_PAUSE=true
}

# ─── Backup, Restore, Scheduling & Pruning ──────────────────────────────────
_perform_backup() {
    local prefix="${1:-backup}"
    is_deployed || { error "Not deployed"; return 1; }
    get_pg_env

    local ts stage_name archive q_inst q_bdir q_arch q_stage
    ts=$(date +%Y%m%d_%H%M%S)
    stage_name="${prefix}_${ts}"
    archive="$BACKUP_DIR/${stage_name}.tar.gz"

    q_inst=$(quote_sh "$INSTALL_DIR")
    q_bdir=$(quote_sh "$BACKUP_DIR")
    q_arch=$(quote_sh "$archive")

    run "mkdir -p $q_bdir && chmod 700 $q_bdir" || { error "Failed to create backup directory"; return 1; }

    local stage_parent
    stage_parent=$(run_out "mktemp -d $q_bdir/.stage.XXXXXX") || true
    [[ -n "$stage_parent" ]] || { error "Failed to create staging directory"; return 1; }
    q_stage=$(quote_sh "$stage_parent/$stage_name")
    local b_dst_sql="$stage_parent/$stage_name/db/x-ui.db"
    b_dst_sql="${b_dst_sql//\'/\'\'}"

    info "Creating backup in $archive..."

    local backup_script
    backup_script=$(cat <<EOF
set -e
umask 077
chmod 700 $(quote_sh "$stage_parent")
mkdir -p $q_stage
chmod 700 $q_stage

if [ -d $q_inst/db ]; then
    cp -a $q_inst/db $q_stage/db
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^3xui_app$' && docker exec 3xui_app sh -c 'command -v sqlite3 >/dev/null 2>&1' 2>/dev/null; then
        if [ -f $q_inst/db/x-ui.db ]; then
            docker exec 3xui_app sqlite3 -cmd '.timeout 5000' /etc/x-ui/x-ui.db ".backup '/etc/x-ui/.x-ui.db.backup'" 2>/dev/null || true
            if [ -f $q_inst/db/.x-ui.db.backup ]; then
                mv -f $q_inst/db/.x-ui.db.backup $q_stage/db/x-ui.db
                rm -f $q_stage/db/x-ui.db-wal $q_stage/db/x-ui.db-shm
            fi
        fi
    elif command -v sqlite3 >/dev/null 2>&1 && [ -f $q_inst/db/x-ui.db ]; then
        sqlite3 -cmd '.timeout 5000' $q_inst/db/x-ui.db $(quote_sh ".backup '${b_dst_sql}'") 2>/dev/null || true
        rm -f $q_stage/db/x-ui.db-wal $q_stage/db/x-ui.db-shm
    fi
fi

[ -d $q_inst/cert ] && cp -a $q_inst/cert $q_stage/cert
[ -d $q_inst/caddy ] && cp -a $q_inst/caddy $q_stage/caddy
if [ -d $q_inst/webpanel ]; then
    mkdir -p $q_stage/webpanel
    [ -f $q_inst/webpanel/webpanel.conf ] && cp -a $q_inst/webpanel/webpanel.conf $q_stage/webpanel/
    [ -f $q_inst/webpanel/auth.json ] && cp -a $q_inst/webpanel/auth.json $q_stage/webpanel/
fi
[ -f $q_inst/compose.yaml ] && cp -a $q_inst/compose.yaml $q_stage/compose.yaml
[ -f $q_inst/.env ] && cp -a $q_inst/.env $q_stage/.env

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^3xui_postgres$'; then
    docker exec 3xui_postgres pg_dump -U $(quote_sh "$PG_USER") $(quote_sh "$PG_DB") > $q_stage/postgres_dump.sql 2>/dev/null || true
fi
[ -d $q_inst/pgdata ] && cp -a $q_inst/pgdata $q_stage/pgdata

tar -czf $q_arch -C $(quote_sh "$stage_parent") $(quote_sh "$stage_name")
chmod 600 $q_arch
EOF
)

    local rc=0
    run "$backup_script" || rc=1
    run_q "rm -rf $(quote_sh "$stage_parent")" || true

    (( rc != 0 )) && { error "Backup failed"; return 1; }
    LAST_BACKUP_ARCHIVE="$archive"
    success "Saved: $archive"
}

backup_panel() {
    LAST_BACKUP_ARCHIVE=""
    _perform_backup "backup" || return 1

    if $REMOTE && $INTERACTIVE; then
        echo ""
        if confirm "Download backup to local machine?"; then
            local local_dir="./3xui-backups"
            mkdir -p "$local_dir" && chmod 700 "$local_dir"
            if ssh_download "$LAST_BACKUP_ARCHIVE" "$local_dir/"; then
                chmod 600 "$local_dir/$(basename "$LAST_BACKUP_ARCHIVE")" 2>/dev/null || true
                success "Downloaded to $local_dir/$(basename "$LAST_BACKUP_ARCHIVE")"
            else
                warn "Download failed"
            fi
        fi
    fi

    echo -e "\n  ${BOLD}Existing Backups:${NC}"
    run "ls -lh $(quote_sh "$BACKUP_DIR")/*.tar.gz 2>/dev/null || echo '  (none)'" || true
}

_list_backups() {
    run_out "ls -1t $(quote_sh "$BACKUP_DIR")/*.tar.gz 2>/dev/null" || true
}

_validate_tar_archive() {
    local archive="${1-}"
    [[ -n "$archive" ]] || return 1
    local q_arch
    q_arch=$(quote_sh "$archive")

    local tz_out tv_out entry
    tz_out=$(run_out "tar -tzf $q_arch") || return 1
    [[ -n "$tz_out" ]] || return 1
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if [[ "$entry" == /* ]] || [[ "$entry" =~ (^|/)\.\.(/|$) ]]; then
            return 1
        fi
    done <<< "$tz_out"

    tv_out=$(run_out "tar -tvzf $q_arch") || return 1
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if [[ "$entry" =~ ^[[:space:]]*[lhbcp] ]]; then
            return 1
        fi
    done <<< "$tv_out"
    return 0
}

restore_panel() {
    local chosen="${1:-}"
    local _cleanup_upload_dir=""

    if [[ -z "$chosen" ]]; then
        if $REMOTE && $INTERACTIVE; then
            tui_select "Restore Source" "Choose where to restore the backup from:" \
                "Remote backups ($BACKUP_DIR)" \
                "Upload local .tar.gz backup file" \
                "Cancel"
            local src_sel=$?
            clear_screen
            case "$src_sel" in
                0) ;;
                1)
                    echo ""
                    local local_file
                    read -rp "  Path to local .tar.gz backup: " local_file
                    local_file="${local_file/#\~/$HOME}"
                    if [[ ! -f "$local_file" ]]; then
                        error "Local file not found: $local_file"
                        return 1
                    fi
                    local upload_dir remote_tmp
                    upload_dir=$(run_out "mktemp -d /tmp/3xui-upload.XXXXXX")
                    [[ -z "$upload_dir" ]] && { error "Failed to allocate remote temp dir"; return 1; }
                    run_q "chmod 700 $(quote_sh "$upload_dir")" || true
                    remote_tmp="${upload_dir}/upload.tar.gz"
                    info "Uploading backup to remote host..."
                    if ! ssh_copy "$local_file" "$remote_tmp"; then
                        run_q "rm -rf $(quote_sh "$upload_dir")"
                        error "Upload failed"
                        return 1
                    fi
                    run_q "chmod 600 $(quote_sh "$remote_tmp")" || true
                    chosen="$remote_tmp"
                    _cleanup_upload_dir="$upload_dir"
                    ;;
                2|255) info "Cancelled"; return 0 ;;
            esac
        fi

        if [[ -z "$chosen" ]]; then
            local listing
            listing=$(_list_backups)
            if [[ -z "$listing" ]]; then
                error "No backups found in $BACKUP_DIR"
                return 1
            fi

            local backups=() opts=() f
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                backups+=("$f")
                opts+=("$(basename "$f")")
            done <<< "$listing"
            opts+=("Cancel")

            tui_select "Restore Panel" "Available backups (newest first):" "${opts[@]}"
            local sel=$?
            clear_screen
            if [[ $sel -eq 255 || "${opts[$sel]}" == "Cancel" ]]; then
                info "Cancelled."
                return 0
            fi
            chosen="${backups[$sel]}"
        fi
    fi

    if ! run_q "test -f $(quote_sh "$chosen")" || ! _validate_tar_archive "$chosen"; then
        [[ -n "$_cleanup_upload_dir" ]] && run_q "rm -rf $(quote_sh "$_cleanup_upload_dir")"
        error "Invalid, unsafe, or unreadable backup archive: $chosen"
        return 1
    fi

    confirm "Restore $(basename "$chosen") into $INSTALL_DIR (replaces active data)?" || {
        [[ -n "$_cleanup_upload_dir" ]] && run_q "rm -rf $(quote_sh "$_cleanup_upload_dir")"
        info "Cancelled"
        return 0
    }

    # Safety snapshot before overwriting live installation.
    if is_deployed; then
        info "Creating safety snapshot before restore..."
        _perform_backup "pre_restore" || warn "Pre-restore safety backup failed; continuing anyway."
    fi

    detect_compose || true
    local was_running=false
    if is_deployed && [[ -n "$COMPOSE_CMD" ]]; then
        if is_running || is_pg_running || is_caddy_running; then
            was_running=true
            compose down || warn "Failed to stop containers cleanly"
        fi
    fi

    local tmp_dir
    tmp_dir=$(run_out "mktemp -d /tmp/3xui-restore.XXXXXX")
    if [[ -z "$tmp_dir" ]]; then
        [[ -n "$_cleanup_upload_dir" ]] && run_q "rm -rf $(quote_sh "$_cleanup_upload_dir")"
        error "Failed to create secure temp directory"
        return 1
    fi

    info "Restoring $(basename "$chosen")..."
    local restore_script
    restore_script=$(cat <<EOF
set -e
umask 077
chmod 700 $(quote_sh "$tmp_dir")
(tar --no-same-owner --no-same-permissions -xzf $(quote_sh "$chosen") -C $(quote_sh "$tmp_dir") 2>/dev/null || tar -xzf $(quote_sh "$chosen") -C $(quote_sh "$tmp_dir"))

src=$(quote_sh "$tmp_dir")
if [ ! -d "\$src/db" ] && [ ! -f "\$src/compose.yaml" ]; then
    sub=\$(find "\$src" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    [ -n "\$sub" ] && src="\$sub"
fi

for chk in "\$src/compose.yaml" "\$src/.env" "\$src/caddy/proxy.conf" "\$src/caddy/probe.conf" "\$src/caddy/Caddyfile" "\$src/webpanel/webpanel.conf" "\$src/webpanel/auth.json" "\$src/db/x-ui.db" "\$src/postgres_dump.sql"; do
    if [ -L "\$chk" ]; then
        echo "Refusing symlink inside backup: \$chk" >&2
        exit 1
    fi
done

mkdir -p $(quote_sh "$INSTALL_DIR")
if [ -d "\$src/db" ]; then
    rm -rf $(quote_sh "$INSTALL_DIR/db")
    cp -a "\$src/db" $(quote_sh "$INSTALL_DIR/db")
    chmod 700 $(quote_sh "$INSTALL_DIR/db")
fi
if [ -d "\$src/cert" ]; then
    rm -rf $(quote_sh "$INSTALL_DIR/cert")
    cp -a "\$src/cert" $(quote_sh "$INSTALL_DIR/cert")
    chmod 700 $(quote_sh "$INSTALL_DIR/cert")
    find $(quote_sh "$INSTALL_DIR/cert") -name 'privkey.pem' -exec chmod 600 {} + 2>/dev/null || true
fi
if [ -d "\$src/caddy" ]; then
    rm -rf $(quote_sh "$INSTALL_DIR/caddy")
    cp -a "\$src/caddy" $(quote_sh "$INSTALL_DIR/caddy")
    chmod 755 $(quote_sh "$INSTALL_DIR/caddy")
    [ -d $(quote_sh "$INSTALL_DIR/caddy/data") ] && chmod 700 $(quote_sh "$INSTALL_DIR/caddy/data")
    [ -d $(quote_sh "$INSTALL_DIR/caddy/config") ] && chmod 700 $(quote_sh "$INSTALL_DIR/caddy/config")
    [ -f $(quote_sh "$INSTALL_DIR/caddy/proxy.conf") ] && chmod 600 $(quote_sh "$INSTALL_DIR/caddy/proxy.conf")
    [ -f $(quote_sh "$INSTALL_DIR/caddy/probe.conf") ] && chmod 600 $(quote_sh "$INSTALL_DIR/caddy/probe.conf")
fi
if [ -d "\$src/webpanel" ]; then
    mkdir -p $(quote_sh "$INSTALL_DIR/webpanel")
    [ -f "\$src/webpanel/webpanel.conf" ] && cp -a "\$src/webpanel/webpanel.conf" $(quote_sh "$INSTALL_DIR/webpanel/webpanel.conf") && chmod 600 $(quote_sh "$INSTALL_DIR/webpanel/webpanel.conf")
    [ -f "\$src/webpanel/auth.json" ] && cp -a "\$src/webpanel/auth.json" $(quote_sh "$INSTALL_DIR/webpanel/auth.json") && chmod 600 $(quote_sh "$INSTALL_DIR/webpanel/auth.json")
    chmod 700 $(quote_sh "$INSTALL_DIR/webpanel")
fi
if [ -f "\$src/compose.yaml" ]; then
    cp -a "\$src/compose.yaml" $(quote_sh "$INSTALL_DIR/compose.yaml")
    chmod 600 $(quote_sh "$INSTALL_DIR/compose.yaml")
fi
if [ -f "\$src/.env" ]; then
    cp -a "\$src/.env" $(quote_sh "$INSTALL_DIR/.env")
    chmod 600 $(quote_sh "$INSTALL_DIR/.env")
fi
if [ -d "\$src/pgdata" ]; then
    rm -rf $(quote_sh "$INSTALL_DIR/pgdata")
    cp -a "\$src/pgdata" $(quote_sh "$INSTALL_DIR/pgdata")
    chmod 700 $(quote_sh "$INSTALL_DIR/pgdata")
elif [ -f "\$src/postgres_dump.sql" ]; then
    cp -a "\$src/postgres_dump.sql" $(quote_sh "$INSTALL_DIR/.restore_dump.sql")
    chmod 600 $(quote_sh "$INSTALL_DIR/.restore_dump.sql")
fi
EOF
)

    local rc=0
    run "$restore_script" || rc=1
    run_q "rm -rf $(quote_sh "$tmp_dir")" || true
    [[ -n "$_cleanup_upload_dir" ]] && run_q "rm -rf $(quote_sh "$_cleanup_upload_dir")" || true

    (( rc != 0 )) && { error "Restore failed"; return 1; }

    if $was_running || confirm "Start containers now?"; then
        if detect_compose && compose up -d; then
            success "Containers started"
            if run_q "test -f $(quote_sh "$INSTALL_DIR/.restore_dump.sql")"; then
                if is_pg_running; then
                    get_pg_env
                    info "Restoring PostgreSQL logical dump..."
                    local i
                    for (( i=0; i<15; i++ )); do
                        run_q "docker exec 3xui_postgres pg_isready -U $(quote_sh "$PG_USER") -d $(quote_sh "$PG_DB")" && break
                        sleep 1
                    done
                    run "docker exec -i 3xui_postgres psql -v ON_ERROR_STOP=1 -U $(quote_sh "$PG_USER") -d $(quote_sh "$PG_DB") < $(quote_sh "$INSTALL_DIR/.restore_dump.sql") >/dev/null" \
                        && success "PostgreSQL dump restored" \
                        || warn "PostgreSQL dump restore encountered errors"
                fi
                run_q "rm -f $(quote_sh "$INSTALL_DIR/.restore_dump.sql")" || true
            fi
        else
            warn "Restore OK but container start failed"
        fi
    else
        run_q "rm -f $(quote_sh "$INSTALL_DIR/.restore_dump.sql")" || true
    fi
    invalidate_status
    success "Restore complete"
}

prune_backups() {
    local listing
    listing=$(_list_backups)
    [[ -z "$listing" ]] && { info "No backups in $BACKUP_DIR"; return 0; }

    local total
    total=$(printf '%s\n' "$listing" | wc -l | tr -d ' ')
    echo ""
    echo -e "  Total backups in $BACKUP_DIR: ${BOLD}${total}${NC}"
    local keep
    read -rp "  Number of newest backups to keep [5]: " keep
    keep="${keep:-5}"
    if ! [[ "$keep" =~ ^[0-9]+$ ]] || (( 10#$keep < 1 )); then
        error "Must keep at least 1 backup"
        return 1
    fi

    if (( total <= 10#$keep )); then
        info "Only $total backups exist; nothing to delete."
        return 0
    fi

    local to_delete=$(( total - 10#$keep ))
    confirm "Delete $to_delete older backup(s)?" || return 0
    run "ls -1t $(quote_sh "$BACKUP_DIR")/*.tar.gz | tail -n +$(( 10#$keep + 1 )) | while IFS= read -r f; do rm -f \"\$f\"; done" || return 1
    success "Pruned $to_delete old backup(s)"
}

_status_backup_cron() {
    local cron_file="/etc/cron.d/3xui-backup"
    if run_q "test -f $cron_file"; then
        local line
        line=$(run_out "grep -v '^#' $cron_file | head -n 1" || true)
        printf 'CRON_ENABLED=true\nCRON_LINE=%s\n' "$line"
        if [[ "$line" =~ ^0[[:space:]]+([0-9]+)[[:space:]] ]]; then
            printf 'CRON_HOUR=%s\n' "${BASH_REMATCH[1]}"
        fi
        local keep_val
        keep_val=$(run_out "awk -F= '/^KEEP=/{print \$2; exit}' /usr/local/bin/3xui-auto-backup.sh" || true)
        [[ -n "$keep_val" ]] && printf 'CRON_KEEP=%s\n' "$keep_val"
    else
        printf 'CRON_ENABLED=false\n'
    fi
}

_install_backup_cron() {
    local hour="${1:-3}" keep="${2:-7}"
    local cron_file="/etc/cron.d/3xui-backup"
    local helper_script="/usr/local/bin/3xui-auto-backup.sh"

    if ! [[ "$hour" =~ ^[0-9]+$ ]] || (( 10#$hour < 0 || 10#$hour > 23 )); then
        error "Invalid hour: $hour (must be 0-23)"
        return 1
    fi
    if ! [[ "$keep" =~ ^[0-9]+$ ]] || (( 10#$keep < 1 || 10#$keep > 365 )); then
        error "Invalid retention count: $keep (must be 1-365)"
        return 1
    fi

    get_pg_env
    local q_inst q_bdir
    q_inst=$(quote_sh "$INSTALL_DIR")
    q_bdir=$(quote_sh "$BACKUP_DIR")

    local script_body
    script_body=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
umask 077
INSTALL_DIR=$q_inst
BACKUP_DIR=$q_bdir
KEEP=$(( 10#$keep ))
PG_USER=$(quote_sh "$PG_USER")
PG_DB=$(quote_sh "$PG_DB")

[ -f "\$INSTALL_DIR/compose.yaml" ] || exit 0
mkdir -p "\$BACKUP_DIR" && chmod 700 "\$BACKUP_DIR"
ts=\$(date +%Y%m%d_%H%M%S)
stage_parent=\$(mktemp -d "\$BACKUP_DIR/.auto.\$ts.XXXXXX")
trap 'rm -rf "\$stage_parent"' EXIT
stage="\$stage_parent/backup_\$ts"
mkdir -p "\$stage"

if [ -d "\$INSTALL_DIR/db" ]; then
    cp -a "\$INSTALL_DIR/db" "\$stage/db"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^3xui_app$' && docker exec 3xui_app sh -c 'command -v sqlite3 >/dev/null 2>&1' 2>/dev/null; then
        if [ -f "\$INSTALL_DIR/db/x-ui.db" ]; then
            docker exec 3xui_app sqlite3 /etc/x-ui/x-ui.db ".backup '/etc/x-ui/.x-ui.db.backup'" 2>/dev/null || true
            if [ -f "\$INSTALL_DIR/db/.x-ui.db.backup" ]; then
                mv -f "\$INSTALL_DIR/db/.x-ui.db.backup" "\$stage/db/x-ui.db"
                rm -f "\$stage/db/x-ui.db-wal" "\$stage/db/x-ui.db-shm"
            fi
        fi
    fi
fi
[ -d "\$INSTALL_DIR/cert" ] && cp -a "\$INSTALL_DIR/cert" "\$stage/cert"
[ -d "\$INSTALL_DIR/caddy" ] && cp -a "\$INSTALL_DIR/caddy" "\$stage/caddy"
[ -f "\$INSTALL_DIR/compose.yaml" ] && cp -a "\$INSTALL_DIR/compose.yaml" "\$stage/compose.yaml"
[ -f "\$INSTALL_DIR/.env" ] && cp -a "\$INSTALL_DIR/.env" "\$stage/.env"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^3xui_postgres$'; then
    docker exec 3xui_postgres pg_dump -U "\$PG_USER" "\$PG_DB" > "\$stage/postgres_dump.sql" 2>/dev/null || true
fi
[ -d "\$INSTALL_DIR/pgdata" ] && cp -a "\$INSTALL_DIR/pgdata" "\$stage/pgdata"

tar -czf "\$BACKUP_DIR/backup_\$ts.tar.gz" -C "\$stage_parent" "backup_\$ts"
chmod 600 "\$BACKUP_DIR/backup_\$ts.tar.gz"
ls -1t "\$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | tail -n +\$((KEEP + 1)) | while IFS= read -r old_f; do rm -f "\$old_f"; done
EOF
)

    if $REMOTE; then
        printf '%s\n' "$script_body" | ssh_cmd "umask 077 && cat > $helper_script && chmod 700 $helper_script"
    else
        ( umask 077; printf '%s\n' "$script_body" > "$helper_script" )
        chmod 700 "$helper_script"
    fi

    local log_file="/var/log/3xui-backup.log"
    run "touch $log_file && chmod 600 $log_file" || true
    local cron_line="0 $(( 10#$hour )) * * * root $helper_script >> $log_file 2>&1"
    run "printf '%s\n' $(quote_sh "$cron_line") > $cron_file && chmod 644 $cron_file" || return 1
    success "Daily backup scheduled at $(printf '%02d:00' "$(( 10#$hour ))") (retaining last $(( 10#$keep )) backups, log: $log_file)"
}

_disable_backup_cron() {
    local cron_file="/etc/cron.d/3xui-backup"
    local helper_script="/usr/local/bin/3xui-auto-backup.sh"
    run "rm -f $cron_file $helper_script" || return 1
    success "Automated backup disabled"
}

setup_backup_cron() {
    local cron_file="/etc/cron.d/3xui-backup"

    local current_cron="Not configured"
    if run_q "test -f $cron_file"; then
        current_cron=$(run_out "grep -v '^#' $cron_file | head -n 1" || echo "Enabled")
    fi

    tui_select "Scheduled Backups" "Current schedule: ${current_cron}" \
        "Enable / Update daily automated backup" \
        "Disable automated backup" \
        "Back"
    local sel=$?
    clear_screen

    case "$sel" in
        0)
            local hour keep
            read -rp "  Hour of day to run (0-23) [3]: " hour
            hour="${hour:-3}"
            read -rp "  Backups to retain [7]: " keep
            keep="${keep:-7}"
            _install_backup_cron "$hour" "$keep"
            ;;
        1)
            _disable_backup_cron
            ;;
        2|255) _SKIP_PAUSE=true; return 0 ;;
    esac
}

manage_backups() {
    while true; do
        local listing count=0 total_size="0"
        listing=$(_list_backups)
        if [[ -n "$listing" ]]; then
            count=$(printf '%s\n' "$listing" | wc -l | tr -d ' ')
            total_size=$(run_out "du -sh $(quote_sh "$BACKUP_DIR") 2>/dev/null | awk '{print \$1}'" || echo "?")
        fi

        local cron_state="off"
        run_q "test -f /etc/cron.d/3xui-backup" && cron_state="${GREEN}on${NC}" || cron_state="${DIM}off${NC}"

        local header_text="  Directory : ${BACKUP_DIR}\n  Archives  : ${BOLD}${count}${NC} (${total_size})\n  Auto Cron : ${cron_state}"

        local opts=(
            "Create backup now"
            "Restore backup"
            "Scheduled daily backup (cron)"
            "Prune old backups"
            "List backups"
            "Back"
        )

        tui_select "Backup & Restore" "$header_text" "${opts[@]}"
        local sub=$?
        clear_screen
        case "$sub" in
            0) backup_panel ;;
            1) restore_panel ;;
            2) setup_backup_cron ;;
            3) prune_backups ;;
            4)
                echo ""
                run "ls -lh $(quote_sh "$BACKUP_DIR")/*.tar.gz 2>/dev/null || echo '  (none)'" || true
                ;;
            5|255) _SKIP_PAUSE=true; return ;;
        esac
        echo ""
        read -rp "  Press Enter..."
    done
}

# ─── Certificate Management ─────────────────────────────────────────────────
install_certbot_deploy_hook() {
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook_file="$hook_dir/3xui-cert-sync.sh"
    local hook_body
    hook_body=$(cat <<EOF
#!/bin/sh
set -eu
umask 077
INSTALL_DIR=$(quote_sh "$INSTALL_DIR")
if [ -n "\${RENEWED_DOMAINS:-}" ] && [ -n "\${RENEWED_LINEAGE:-}" ]; then
    for domain in \$RENEWED_DOMAINS; do
        case "\$domain" in
            ""|*..*|*/*) continue ;;
        esac
        printf '%s' "\$domain" | grep -Eq '^[a-zA-Z0-9.-]+\$' || continue
        dest="\$INSTALL_DIR/cert/\$domain"
        mkdir -p "\$dest"
        chmod 700 "\$dest"
        cp -L "\$RENEWED_LINEAGE/fullchain.pem" "\$dest/fullchain.pem"
        cp -L "\$RENEWED_LINEAGE/privkey.pem" "\$dest/privkey.pem"
        chmod 644 "\$dest/fullchain.pem"
        chmod 600 "\$dest/privkey.pem"
    done
    docker restart 3xui_app >/dev/null 2>&1 || true
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^3xui_caddy$'; then
        if docker exec 3xui_caddy test -S /config/admin.sock 2>/dev/null; then
            docker exec 3xui_caddy caddy reload --config /etc/caddy/Caddyfile --address unix//config/admin.sock >/dev/null 2>&1 || true
        else
            docker exec 3xui_caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
        fi
    fi
fi
EOF
)
    run "mkdir -p $hook_dir" || return 1
    if $REMOTE; then
        printf '%s\n' "$hook_body" | ssh_cmd "umask 077 && cat > $hook_file && chmod 755 $hook_file"
    else
        ( umask 077; printf '%s\n' "$hook_body" > "$hook_file" )
        chmod 755 "$hook_file"
    fi
}

sync_letsencrypt_certs() {
    local sync_cmd
    sync_cmd=$(cat <<EOF
umask 077
synced=0
if [ -d /etc/letsencrypt/live ] && [ -d $(quote_sh "$INSTALL_DIR/cert") ]; then
    for d in $(quote_sh "$INSTALL_DIR/cert")/*; do
        [ -d "\$d" ] || continue
        dom=\$(basename "\$d")
        if [ -f "/etc/letsencrypt/live/\$dom/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/\$dom/privkey.pem" ]; then
            cp -L "/etc/letsencrypt/live/\$dom/fullchain.pem" "\$d/fullchain.pem"
            cp -L "/etc/letsencrypt/live/\$dom/privkey.pem" "\$d/privkey.pem"
            chmod 644 "\$d/fullchain.pem"
            chmod 600 "\$d/privkey.pem"
            echo "Synced: \$dom"
            synced=\$(( synced + 1 ))
        fi
    done
fi
echo "SYNCED_COUNT=\$synced"
EOF
)
    run "$sync_cmd"
}

apply_panel_cert() {
    local domain="$1" target="${2:-panel}"
    local host_cert="$INSTALL_DIR/cert/$domain/fullchain.pem"
    local host_key="$INSTALL_DIR/cert/$domain/privkey.pem"
    if ! run_q "test -f $(quote_sh "$host_cert") && test -f $(quote_sh "$host_key")"; then
        error "Cert or key missing in $INSTALL_DIR/cert/$domain/"
        return 1
    fi

    if [[ "$target" == "caddy" ]]; then
        require_deployed || return 1
        load_proxy_conf
        if ! $PROXY_ENABLED || [[ -z "$PROXY_DOMAIN" ]]; then
            error "Caddy reverse proxy is not enabled; cannot bind certificate to Caddy"
            return 1
        fi
        get_panel_info || true
        local use_p_cert=false use_s_cert=false
        local cf="$INSTALL_DIR/caddy/Caddyfile"
        local cf_bak="$INSTALL_DIR/caddy/Caddyfile.bak"
        run_q "grep -q $(quote_sh "tls /root/cert/$PROXY_DOMAIN/") $(quote_sh "$cf")" && use_p_cert=true
        if [[ "$SUB_MODE" == "dedicated" && -n "$SUB_DOMAIN" ]]; then
            run_q "grep -q $(quote_sh "tls /root/cert/$SUB_DOMAIN/") $(quote_sh "$cf")" && use_s_cert=true
        fi
        if [[ "$domain" == "$PROXY_DOMAIN" ]]; then
            use_p_cert=true
        elif [[ "$SUB_MODE" == "dedicated" && "$domain" == "$SUB_DOMAIN" ]]; then
            use_s_cert=true
        else
            error "Certificate domain '$domain' does not match configured proxy domain ($PROXY_DOMAIN) or subscription domain (${SUB_DOMAIN:-none})"
            return 1
        fi

        local had_cf=false
        if run_q "test -f $(quote_sh "$cf")"; then
            had_cf=true
            run "cp $(quote_sh "$cf") $(quote_sh "$cf_bak") && chmod 644 $(quote_sh "$cf_bak")" || true
        fi
        if ! generate_caddyfile "$PROXY_DOMAIN" "$PROXY_PORT" "$PROXY_EMAIL" "$PANEL_PORT" "$PANEL_PATH" \
            "$SUB_MODE" "$SUB_DOMAIN" "$SUB_PORT" "$SUB_PATH" "$SUB_JSON_PATH" \
            "$use_p_cert" "$use_s_cert"; then
            $had_cf && run_q "mv -f $(quote_sh "$cf_bak") $(quote_sh "$cf")" || true
            error "Failed to update Caddyfile for certificate '$domain'"
            return 1
        fi
        if is_caddy_running; then
            if _caddy_reload; then
                run_q "rm -f $(quote_sh "$cf_bak")" || true
                success "Caddy configured to serve TLS certificate for $domain"
            else
                if $had_cf; then
                    run_q "mv -f $(quote_sh "$cf_bak") $(quote_sh "$cf")" || true
                    _caddy_reload >/dev/null 2>&1 || true
                fi
                error "Caddy rejected TLS configuration for $domain; rolled back"
                return 1
            fi
        else
            run_q "rm -f $(quote_sh "$cf_bak")" || true
            success "Saved Caddyfile TLS configuration for $domain"
        fi
        return 0
    fi

    require_running || return 1
    load_proxy_conf
    if $PROXY_ENABLED; then
        error "Caddy reverse proxy is active — keep 3X-UI panel HTTP on loopback and apply certificates to Caddy instead."
        return 1
    fi

    local cert_path="/root/cert/$domain/fullchain.pem"
    local key_path="/root/cert/$domain/privkey.pem"

    echo ""
    echo -e "  Cert: ${BOLD}$cert_path${NC}"
    echo -e "  Key : ${BOLD}$key_path${NC}"
    confirm "Configure panel to use these TLS paths?" || return 0

    run "$(_xui_setting_cmd -webCert "$cert_path" -webCertKey "$key_path")" \
        || { error "Failed to set TLS paths"; return 1; }
    success "TLS configured — restarting panel to apply..."
    if $INTERACTIVE; then
        confirm "Restart panel now?" && restart_panel || true
    else
        restart_panel || true
    fi
}

cert_issue() {
    local domain="${1:-}" email="${2:-}" apply_mode="${3:-}"
    local interactive_mode=false
    if [[ -z "$domain" ]]; then
        interactive_mode=true
        echo ""
        read -rp "  Domain: " domain
        read -rp "  Email for Let's Encrypt notices [blank to skip]: " email
    fi

    if ! validate_domain "$domain"; then
        error "Invalid domain name: $domain"
        return 1
    fi

    local email_args
    if [[ -n "$email" && "$email" != "-" ]]; then
        if ! validate_email "$email"; then
            error "Invalid email address: $email"
            return 1
        fi
        email_args="--email $(quote_sh "$email")"
    else
        email_args="--register-unsafely-without-email"
    fi

    if ! run_q "command -v certbot"; then
        info "Installing certbot..."
        if run_q "command -v apt-get"; then
            run "apt-get update -qq && apt-get install -y -qq certbot" || { error "Cannot install certbot"; return 1; }
        elif run_q "command -v dnf"; then
            run "dnf install -y certbot" || { error "Cannot install certbot"; return 1; }
        elif run_q "command -v apk"; then
            run "apk add --no-cache certbot" || { error "Cannot install certbot"; return 1; }
        elif run_q "command -v pacman"; then
            run "pacman -Sy --noconfirm certbot" || { error "Cannot install certbot"; return 1; }
        else
            error "Automatic certbot install is only supported on apt/dnf/apk/pacman systems."
            return 1
        fi
    fi

    local was_running=false
    if is_running || is_caddy_running; then
        was_running=true
        warn "Stack will be briefly stopped so certbot standalone can bind port 80."
        confirm "Continue?" || return 0
        compose stop || { error "Could not stop stack"; return 1; }
    fi

    info "Requesting Let's Encrypt cert for $domain (port 80 must be publicly reachable)..."
    local issued=false
    if run "certbot certonly --standalone --agree-tos $email_args -d $(quote_sh "$domain") --non-interactive"; then
        local dest="$INSTALL_DIR/cert/$domain"
        run "umask 077 && mkdir -p $(quote_sh "$dest") && chmod 700 $(quote_sh "$INSTALL_DIR/cert") $(quote_sh "$dest")"
        run "umask 077 && cp -L $(quote_sh "/etc/letsencrypt/live/$domain/fullchain.pem") $(quote_sh "$dest/fullchain.pem") && chmod 644 $(quote_sh "$dest/fullchain.pem")" || warn "Could not copy fullchain"
        run "umask 077 && cp -L $(quote_sh "/etc/letsencrypt/live/$domain/privkey.pem") $(quote_sh "$dest/privkey.pem") && chmod 600 $(quote_sh "$dest/privkey.pem")" || warn "Could not copy privkey"
        install_certbot_deploy_hook || warn "Could not install auto-renewal deploy hook"
        success "Cert saved to $dest (and deploy hook installed)"
        issued=true
    else
        error "Cert issuance failed — ensure port 80 is open and DNS resolves to this server."
    fi

    if $was_running; then
        compose up -d && success "Stack restarted" || warn "Stack restart failed"
        invalidate_status
    fi

    if $issued; then
        if [[ "$apply_mode" == "caddy" ]]; then
            apply_panel_cert "$domain" "caddy" || return 1
        elif [[ "$apply_mode" == "panel" ]]; then
            apply_panel_cert "$domain" "panel" || return 1
        elif $interactive_mode && is_running; then
            load_proxy_conf
            $PROXY_ENABLED || apply_panel_cert "$domain" "panel" || true
        fi
        return 0
    fi
    return 1
}

cert_renew() {
    local domain="${1:-}" force="${2:-false}"
    if [[ -n "$domain" && "$domain" != "all" && "$domain" != "-" ]]; then
        validate_domain "$domain" || { error "Invalid domain: $domain"; return 1; }
    else
        domain=""
    fi

    if ! run_q "command -v certbot"; then
        error "certbot not installed — issue a cert first"
        return 1
    fi

    local was_running=false
    if is_running || is_caddy_running; then
        if confirm "Stop stack briefly during renewal so standalone challenge can bind port 80?"; then
            was_running=true
            compose stop || { error "Could not stop stack"; return 1; }
        fi
    fi

    local renew_cmd="certbot renew --non-interactive"
    [[ -n "$domain" ]] && renew_cmd+=" --cert-name $(quote_sh "$domain")"
    [[ "$force" == "force" || "$force" == "true" ]] && renew_cmd+=" --force-renewal"

    info "Renewing certbot certificate(s)${domain:+ ($domain)}..."
    local rc=0
    run "$renew_cmd" || rc=1

    install_certbot_deploy_hook || true
    info "Syncing certificates into $INSTALL_DIR/cert/..."
    sync_letsencrypt_certs || true

    if $was_running; then
        compose up -d && success "Stack restarted" || warn "Stack restart failed"
        invalidate_status
    elif is_running; then
        confirm "Restart panel to load renewed certificates?" && restart_panel || true
    fi
    if is_caddy_running; then
        _caddy_reload || true
    fi

    if (( rc == 0 )); then
        success "Renewal & sync complete"
        return 0
    fi
    error "Renewal encountered errors — check certbot logs"
    return 1
}

cert_self_signed() {
    require_deployed || return 1
    if ! run_q "command -v openssl"; then
        error "openssl not found on target system"
        return 1
    fi

    local host="${1:-}" days="${2:-3650}" apply_mode="${3:-}"
    local interactive_mode=false
    if [[ -z "$host" ]]; then
        interactive_mode=true
        echo ""
        local default_host
        default_host=$(get_target_ip)
        read -rp "  Domain or IP for certificate [${default_host}]: " host
        host="${host:-$default_host}"
    fi
    if ! validate_domain_or_ip "$host"; then
        error "Invalid domain or IP address: $host"
        return 1
    fi
    if ! [[ "$days" =~ ^[0-9]+$ ]] || (( 10#$days < 1 || 10#$days > 3650 )); then
        error "Invalid validity days '$days' (must be 1-3650)"
        return 1
    fi

    local san_entry="DNS:${host}"
    ( validate_ipv4 "$host" || validate_ipv6 "$host" ) && san_entry="IP:${host}"

    local dest="$INSTALL_DIR/cert/$host"
    info "Generating ${days}-day ECDSA P-256 self-signed certificate for $host..."

    local gen_cmd
    gen_cmd=$(cat <<EOF
set -e
umask 077
mkdir -p $(quote_sh "$dest")
chmod 700 $(quote_sh "$INSTALL_DIR/cert") $(quote_sh "$dest")
cfg=\$(mktemp /tmp/3xui-ssl.XXXXXX)
trap 'rm -f "\$cfg"' EXIT
cat > "\$cfg" <<CFG
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = $host
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $san_entry
CFG
openssl ecparam -name prime256v1 -genkey -noout -out $(quote_sh "$dest/privkey.pem")
openssl req -new -x509 -sha256 -days $(( 10#$days )) -key $(quote_sh "$dest/privkey.pem") -out $(quote_sh "$dest/fullchain.pem") -config "\$cfg"
chmod 644 $(quote_sh "$dest/fullchain.pem")
chmod 600 $(quote_sh "$dest/privkey.pem")
EOF
)
    run "$gen_cmd" || { error "Certificate generation failed"; return 1; }
    success "Self-signed certificate saved to $dest"

    if [[ "$apply_mode" == "caddy" ]]; then
        apply_panel_cert "$host" "caddy" || return 1
    elif [[ "$apply_mode" == "panel" ]]; then
        apply_panel_cert "$host" "panel" || return 1
    elif $interactive_mode && is_running; then
        load_proxy_conf
        $PROXY_ENABLED || apply_panel_cert "$host" "panel" || true
    fi
}

cert_revoke() {
    require_deployed || return 1
    validate_safe_dir "$INSTALL_DIR" || { error "Unsafe install directory: $INSTALL_DIR"; return 1; }

    local domain="${1:-}" reason="${2:-unspecified}"
    if [[ -z "$domain" ]]; then
        echo ""
        read -rp "  Certificate domain or IP folder in $INSTALL_DIR/cert/ to revoke/remove: " domain
    fi
    if [[ "$domain" == *"/"* || "$domain" == *".."* ]] || ! validate_domain_or_ip "$domain"; then
        error "Invalid certificate domain or IP: $domain"
        return 1
    fi
    case "$reason" in
        unspecified|keycompromise|affiliationchanged|superseded|cessationofoperation) ;;
        *)
            error "Invalid revocation reason '$reason' (allowed: unspecified, keycompromise, affiliationchanged, superseded, cessationofoperation)"
            return 1
            ;;
    esac

    local dest="$INSTALL_DIR/cert/$domain"
    local le_cert="/etc/letsencrypt/live/$domain/fullchain.pem"
    local has_local=false has_le=false
    run_q "test -d $(quote_sh "$dest")" && has_local=true
    run_q "test -f $(quote_sh "$le_cert")" && has_le=true

    if ! $has_local && ! $has_le; then
        error "No certificate found for '$domain' in $INSTALL_DIR/cert/ or /etc/letsencrypt/live/"
        return 1
    fi

    confirm "Revoke and delete certificate for '${domain}' (reason: ${reason})?" || return 0

    if $has_le; then
        if ! run_q "command -v certbot"; then
            error "Let's Encrypt lineage exists at $le_cert but certbot is not installed"
            return 1
        fi
        info "Revoking Let's Encrypt certificate for $domain (reason=${reason})..."
        if ! run "certbot revoke --non-interactive --cert-path $(quote_sh "$le_cert") --reason $(quote_sh "$reason") --delete-after-revoke"; then
            report_diagnostic "ERROR" "cert_revoke" \
                "Let's Encrypt revocation failed for $domain" \
                "certbot ($le_cert)" \
                "Check network connectivity and Let's Encrypt rate limits/account state."
            return 1
        fi
        success "Revoked Let's Encrypt certificate for $domain"
    fi

    if $has_local; then
        run "rm -rf $(quote_sh "$dest")" || { error "Failed to delete $dest"; return 1; }
        success "Removed local certificate directory $dest"
    fi

    # Clear references in 3X-UI database if active
    local db_changed=false
    if is_running || is_pg_running || run_q "test -f $(quote_sh "$INSTALL_DIR/db/x-ui.db")"; then
        local cur_wcert cur_scert
        cur_wcert=$(xui_db_get "webCertFile" || true)
        cur_scert=$(xui_db_get "subCertFile" || true)
        if [[ "$cur_wcert" == *"/cert/${domain}/"* ]]; then
            xui_db_set "webCertFile" "" || true
            xui_db_set "webKeyFile" "" || true
            db_changed=true
            info "Cleared webCertFile/webKeyFile references for $domain"
        fi
        if [[ "$cur_scert" == *"/cert/${domain}/"* ]]; then
            xui_db_set "subCertFile" "" || true
            xui_db_set "subKeyFile" "" || true
            db_changed=true
            info "Cleared subCertFile/subKeyFile references for $domain"
        fi
    fi

    if $db_changed && is_running; then
        restart_panel || true
    fi

    load_proxy_conf
    if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
        if run_q "grep -q $(quote_sh "/root/cert/$domain/") $(quote_sh "$INSTALL_DIR/caddy/Caddyfile")"; then
            info "Updating Caddyfile after certificate removal..."
            get_panel_info >/dev/null 2>&1 || true
            _sync_caddy_if_active "$PANEL_PORT" "$PANEL_PATH" || warn "Caddy reload warning after cert removal"
        fi
    fi
    return 0
}

cert_list() {
    if ! run_q "test -d $(quote_sh "$INSTALL_DIR/cert")"; then
        info "No certificate directory at $INSTALL_DIR/cert"
        return 0
    fi
    local cert_files
    cert_files=$(run_out "find $(quote_sh "$INSTALL_DIR/cert") -name 'fullchain.pem' | sort" || true)
    if [[ -z "$cert_files" ]]; then
        info "No certificates found in $INSTALL_DIR/cert"
        return 0
    fi
    local cf dom exp
    while IFS= read -r cf; do
        [[ -z "$cf" ]] && continue
        dom=$(basename "$(dirname "$cf")")
        exp=$(run_out "openssl x509 -enddate -noout -in $(quote_sh "$cf") | cut -d= -f2" || echo "unknown")
        printf '%s\t%s\n' "$dom" "${exp:-unknown}"
    done <<< "$cert_files"
}

certs_cli_dispatch() {
    local subcmd="${1:-}"
    shift || true
    case "$subcmd" in
        list)        cert_list ;;
        issue)       cert_issue "${1:-}" "${2:-}" "${3:-none}" ;;
        renew)       cert_renew "${1:-}" "${2:-false}" ;;
        revoke)      cert_revoke "${1:-}" "${2:-unspecified}" ;;
        self-signed) cert_self_signed "${1:-}" "${2:-3650}" "${3:-none}" ;;
        apply)
            [[ -n "${1:-}" ]] || { error "Usage: manage.sh certs apply <domain> [caddy|panel]"; return 1; }
            validate_domain_or_ip "$1" || { error "Invalid domain/IP: $1"; return 1; }
            apply_panel_cert "$1" "${2:-caddy}"
            ;;
        *)
            error "Unknown certs action: $subcmd (use: list|issue|renew|revoke|self-signed|apply)"
            return 1
            ;;
    esac
}

cert_configure() {
    require_running || return 1
    local dirs
    dirs=$(run_out "find $(quote_sh "$INSTALL_DIR/cert") -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null" || true)

    local domain=""
    if [[ -n "$dirs" ]]; then
        local opts=() d
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            opts+=("$d")
        done <<< "$dirs"
        opts+=("Enter custom domain/name" "Cancel")
        tui_select "Select Certificate" "Found certificates in $INSTALL_DIR/cert/:" "${opts[@]}"
        local sel=$?
        clear_screen
        if [[ $sel -eq 255 || "${opts[$sel]}" == "Cancel" ]]; then
            return 0
        elif [[ "${opts[$sel]}" != "Enter custom domain/name" ]]; then
            domain="${opts[$sel]}"
        fi
    fi

    if [[ -z "$domain" ]]; then
        echo ""
        read -rp "  Domain / folder name in $INSTALL_DIR/cert/: " domain
    fi
    if ! validate_domain_or_ip "$domain"; then
        error "Invalid domain / name: $domain"
        return 1
    fi

    apply_panel_cert "$domain"
}

manage_certs() {
    require_deployed || return 1

    while true; do
        local header_text="  Host path   : $INSTALL_DIR/cert/<domain>/\n  In container: /root/cert/<domain>/\n"

        if run_q "test -d $(quote_sh "$INSTALL_DIR/cert")"; then
            local cert_files
            cert_files=$(run_out "find $(quote_sh "$INSTALL_DIR/cert") -name 'fullchain.pem'" || true)

            if [[ -n "$cert_files" ]]; then
                header_text+="\n  ${BOLD}Installed certificates:${NC}\n"
                local cf domain expiry
                while IFS= read -r cf; do
                    [[ -z "$cf" ]] && continue
                    domain=$(basename "$(dirname "$cf")")
                    expiry=$(run_out "openssl x509 -enddate -noout -in $(quote_sh "$cf") | cut -d= -f2" || echo "unknown")
                    header_text+="  ${DOT} $domain  (expires: ${expiry:-unknown})\n"
                done <<< "$cert_files"
            else
                header_text+="\n  ${YELLOW}No certificates found${NC}"
            fi
        else
            header_text+="\n  ${YELLOW}Cert directory not yet created${NC}"
        fi

        local opts=(
            "Issue Let's Encrypt cert (certbot standalone)"
            "Renew & sync all certbot certs"
            "Generate self-signed cert (ECDSA P-256)"
            "Set panel TLS cert"
            "Revoke / delete certificate"
            "List cert files"
            "Back"
        )

        tui_select "Certificate Management" "$header_text" "${opts[@]}"
        local sub=$?
        clear_screen
        case "$sub" in
            0) cert_issue ;;
            1) cert_renew ;;
            2) cert_self_signed ;;
            3) cert_configure ;;
            4) cert_revoke ;;
            5)
                echo ""
                if run_q "test -d $(quote_sh "$INSTALL_DIR/cert")"; then
                    run "find $(quote_sh "$INSTALL_DIR/cert") \\( -name '*.pem' -o -name '*.crt' -o -name '*.key' \\) 2>/dev/null || echo '  (none)'" || true
                else
                    echo "  (cert directory does not exist)"
                fi
                ;;
            6|255) _SKIP_PAUSE=true; return ;;
        esac

        echo ""
        read -rp "  Press Enter..."
    done
}

# ─── Inbound Discovery & Multi-Protocol Routing ─────────────────────────────
_parse_stream_settings() {
    local json="${1-}"
    local flat
    flat=$(printf '%s' "$json" | tr -d '\n\r\t')

    PARSED_NET=$(printf '%s' "$flat" | sed -nE 's/.*"network"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
    PARSED_SEC=$(printf '%s' "$flat" | sed -nE 's/.*"security"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
    PARSED_NET="${PARSED_NET:-tcp}"
    PARSED_SEC="${PARSED_SEC:-none}"
    PARSED_PATH=""

    local p=""
    case "$PARSED_NET" in
        grpc)
            p=$(printf '%s' "$flat" | sed -nE 's/.*"serviceName"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
            if [[ -n "$p" ]]; then
                [[ "$p" != /* ]] && p="/$p"
                PARSED_PATH="$p"
            fi
            ;;
        ws|httpupgrade|xhttp|splithttp)
            p=$(printf '%s' "$flat" | sed -nE 's/.*"path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
            p="${p%%\?*}"
            if [[ -n "$p" ]]; then
                [[ "$p" != /* ]] && p="/$p"
                PARSED_PATH="$p"
            fi
            ;;
    esac
}

_inbound_fw_proto() {
    local proto="${1-}" net="${2-tcp}"
    case "$proto" in
        wireguard|amneziawg|hysteria|hysteria2|tuic|masque)
            printf 'udp' ;;
        shadowsocks|dokodemo-door|mixed|socks)
            printf 'both' ;;
        *)
            case "$net" in
                kcp|mkcp|quic) printf 'udp' ;;
                *)             printf 'tcp' ;;
            esac
            ;;
    esac
}

_is_inbound_enabled() {
    local en="${1:-}"
    [[ "$en" == "1" || "$en" == "true" || "$en" == "t" ]]
}

_format_inbound_rows() {
    local raw_rows="${1-}"
    [[ -z "$raw_rows" ]] && return 0
    local line id en proto listen port remark stream fw_proto
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        line="${line//$'\t'/$'\x1f'}"
        IFS=$'\x1f' read -r id en proto listen port remark stream <<< "$line"
        [[ -z "$id" ]] && continue
        validate_port "$port" || continue
        _parse_stream_settings "$stream"
        fw_proto=$(_inbound_fw_proto "$proto" "$PARSED_NET")
        remark="${remark//|//}"
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$id" "$en" "$proto" "$listen" "$port" "$remark" \
            "$PARSED_NET" "$PARSED_SEC" "$PARSED_PATH" "$fw_proto"
    done <<< "$raw_rows"
}

get_xui_inbounds() {
    local raw_rows=""
    local stream_col="stream_settings"
    if _is_postgres_backend; then
        is_pg_running || return 0
        get_pg_env
        local sql="SELECT id, enable, protocol, COALESCE(NULLIF(listen,''), '0.0.0.0'), port, regexp_replace(COALESCE(remark,''), E'[\\r\\n\\t]+', ' ', 'g'), regexp_replace(COALESCE(stream_settings,''), E'[\\r\\n\\t]+', ' ', 'g') FROM inbounds ORDER BY id;"
        raw_rows=$(run_out "docker exec 3xui_postgres psql -U $(quote_sh "$PG_USER") -d $(quote_sh "$PG_DB") -F \$'\t' -tA -c $(quote_sh "$sql")" || true)
    else
        local sql="SELECT id, enable, protocol, COALESCE(NULLIF(listen,''), '0.0.0.0'), port, replace(replace(replace(COALESCE(remark,''), char(10), ' '), char(13), ''), char(9), ' '), replace(replace(replace(COALESCE(${stream_col},''), char(10), ' '), char(13), ''), char(9), ' ') FROM inbounds ORDER BY id;"
        raw_rows=$(_xui_sqlite_query "$sql" $'\t')
        if [[ -z "$raw_rows" ]]; then
            local cols
            cols=$(_xui_sqlite_query "PRAGMA table_info(inbounds);" "|" || true)
            if [[ -n "$cols" ]] && printf '%s\n' "$cols" | cut -d'|' -f2 | grep -qx 'streamSettings'; then
                sql="SELECT id, enable, protocol, COALESCE(NULLIF(listen,''), '0.0.0.0'), port, replace(replace(replace(COALESCE(remark,''), char(10), ' '), char(13), ''), char(9), ' '), replace(replace(replace(COALESCE(streamSettings,''), char(10), ' '), char(13), ''), char(9), ' ') FROM inbounds ORDER BY id;"
                raw_rows=$(_xui_sqlite_query "$sql" $'\t')
            fi
        fi
    fi
    _format_inbound_rows "$raw_rows"
}

_collect_caddy_inbound_blocks() {
    local panel_path="${1:-/}" sub_path="${2:-/sub/}" sub_json_path="${3:-/json/}"
    local wp_base=""
    $WEBPANEL_ENABLED && wp_base="${WEBPANEL_PATH%/}"
    local p_base="${panel_path%/}" s_base="${sub_path%/}" j_base="${sub_json_path%/}"
    local inbounds="${INBOUNDS_OVERRIDE:-}"
    [[ -z "$inbounds" ]] && inbounds=$(get_xui_inbounds || true)
    [[ -z "$inbounds" ]] && return 0

    local seen_paths="|${p_base}|${s_base}|${j_base}|${wp_base}|"
    local id en proto listen port remark net sec path fw_proto
    while IFS='|' read -r id en proto listen port remark net sec path fw_proto; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        _is_inbound_enabled "$en" || continue
        [[ "$listen" == "127.0.0.1" || "$listen" == "::1" || "$listen" == "localhost" ]] || continue
        [[ "$net" == "ws" || "$net" == "httpupgrade" || "$net" == "xhttp" || "$net" == "splithttp" || "$net" == "grpc" ]] || continue
        [[ -n "$path" && "$path" != "/" ]] || continue
        validate_webpath "$path" || continue

        local p_clean="${path%/}"
        [[ "$seen_paths" == *"|${p_clean}|"* ]] && continue
        seen_paths+="${p_clean}|"

        local safe_remark
        safe_remark=$(printf '%s' "${remark:-$proto/$net}" | tr -cd '[:alnum:] ._-')
        [[ -z "$safe_remark" ]] && safe_remark="${proto}/${net}"

        local up_target="127.0.0.1:${port}"
        local match_expr="${p_clean} ${p_clean}/*"
        if [[ "$net" == "grpc" ]]; then
            up_target="h2c://127.0.0.1:${port}"
            match_expr="${p_clean}/*"
        fi

        cat <<EOF

    # Inbound #${id} (${safe_remark})
    @inbound_${id} {
        path ${match_expr}
    }
    handle @inbound_${id} {
        reverse_proxy ${up_target} {
            header_up Host {http.request.hostport}
            header_up X-Forwarded-Host {http.request.host}
            header_up X-Forwarded-Port {http.request.port}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
EOF
    done <<< "$inbounds"
}

# ─── Reverse Proxy (Caddy) ──────────────────────────────────────────────────
inject_caddy_compose() {
    local cfg="$INSTALL_DIR/compose.yaml"
    local q_cfg q_tmp
    q_cfg=$(quote_sh "$cfg")
    q_tmp=$(quote_sh "${cfg}.tmp")

    local cur_yaml
    cur_yaml=$(run_out "cat $q_cfg") || return 1

    if printf '%s\n' "$cur_yaml" | grep -qE '^  caddy:'; then
        local caddy_hardened
        caddy_hardened=$(awk '
            BEGIN { in_c = 0; has_drop = 0; has_nnp = 0 }
            /^  caddy:[[:space:]]*$/ { in_c = 1; next }
            in_c && (/^  [a-zA-Z0-9_-]+:/ || /^[^[:space:]#]/) { in_c = 0 }
            in_c && /cap_drop:/ { has_drop = 1 }
            in_c && /no-new-privileges:true/ { has_nnp = 1 }
            END { if (has_drop && has_nnp) print "yes"; else print "no" }
        ' <<< "$cur_yaml")
        [[ "$caddy_hardened" == "yes" ]] && return 0
        remove_caddy_compose || return 1
        cur_yaml=$(run_out "cat $q_cfg") || return 1
    fi

    local block
    block=$(_caddy_service_block)
    local new_yaml
    new_yaml=$(CADDY_BLOCK="$block" awk '
        BEGIN { blk = ENVIRON["CADDY_BLOCK"]; in_svc = 0; done = 0 }
        /^services:[[:space:]]*$/ { in_svc = 1 }
        in_svc && /^[^[:space:]#]/ && $0 !~ /^services:/ && !done {
            print ""
            print blk
            done = 1
            in_svc = 0
        }
        { print }
        END {
            if (!done) {
                print ""
                print blk
            }
        }
    ' <<< "$cur_yaml") || return 1

    if $REMOTE; then
        printf '%s\n' "$new_yaml" | ssh_cmd "umask 077 && cat > $q_tmp && chmod 600 $q_tmp && mv $q_tmp $q_cfg"
    else
        ( umask 077; printf '%s\n' "$new_yaml" > "${cfg}.tmp" )
        chmod 600 "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    fi
}

remove_caddy_compose() {
    local cfg="$INSTALL_DIR/compose.yaml"
    local q_cfg q_tmp
    q_cfg=$(quote_sh "$cfg")
    q_tmp=$(quote_sh "${cfg}.tmp")

    run_q "test -f $q_cfg" || return 0
    run_q "grep -qE '^  caddy:' $q_cfg" || return 0

    local cur_yaml new_yaml
    cur_yaml=$(run_out "cat $q_cfg") || return 1
    new_yaml=$(awk '
        BEGIN { skip = 0 }
        /^  caddy:[[:space:]]*$/ { skip = 1; next }
        skip && (/^  [a-zA-Z0-9_-]+:/ || /^[^[:space:]#]/) { skip = 0 }
        !skip { print }
    ' <<< "$cur_yaml" | awk '{ lines[NR] = $0 } END { while (NR > 0 && lines[NR] ~ /^[[:space:]]*$/) NR--; for (i = 1; i <= NR; i++) print lines[i] }') || return 1

    if $REMOTE; then
        printf '%s\n' "$new_yaml" | ssh_cmd "umask 077 && cat > $q_tmp && chmod 600 $q_tmp && mv $q_tmp $q_cfg"
    else
        ( umask 077; printf '%s\n' "$new_yaml" > "${cfg}.tmp" )
        chmod 600 "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    fi
}

_html_escape() {
    local s="${1-}"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

generate_decoy_site() {
    local force="${1:-false}"
    local site_dir="$INSTALL_DIR/caddy/site"
    local index_file="$site_dir/index.html"

    run "mkdir -p $(quote_sh "$site_dir") $(quote_sh "$site_dir/assets") && chmod 755 $(quote_sh "$site_dir") $(quote_sh "$site_dir/assets")" || return 1
    if [[ "$force" != "true" ]] && run_q "test -f $(quote_sh "$index_file")"; then
        return 0
    fi

    if run_q "test -f $(quote_sh "$INSTALL_DIR/caddy/probe.conf")"; then
        load_probe_conf
    fi

    local theme="${DECOY_THEME:-cloud}"
    local brand tagline email accent accent_dark hero_eyebrow hero_title hero_desc
    local card1_t card1_d card2_t card2_d card3_t card3_d

    case "$theme" in
        studio)
            brand="${DECOY_SITE_NAME:-Northstar Digital Studio}"
            tagline="${DECOY_SITE_TAGLINE:-Product Architecture, Design Systems & Web Engineering}"
            email="${DECOY_CONTACT_EMAIL:-hello@northstarstudio.example}"
            accent="#0f766e"; accent_dark="#115e59"
            hero_eyebrow="Digital Product Engineering"
            hero_title="Resilient interfaces and scalable design systems for modern teams."
            hero_desc="We partner with product organizations to design, benchmark, and ship accessible web platforms built on measurable performance standards."
            card1_t="Design Systems"; card1_d="Tokenized UI libraries, WCAG AA accessibility audits, and cohesive cross-product component architecture."
            card2_t="Frontend Engineering"; card2_d="Zero-bloat static and server-rendered web applications engineered for sub-second Core Web Vitals."
            card3_t="Platform Reliability"; card3_d="Automated visual regression pipelines, semantic release workflows, and edge caching governance."
            ;;
        docs)
            brand="${DECOY_SITE_NAME:-Atlas Engineering Docs}"
            tagline="${DECOY_SITE_TAGLINE:-Platform Architecture Reference, API Standards & Runbooks}"
            email="${DECOY_CONTACT_EMAIL:-docs@atlaseng.example}"
            accent="#1d4ed8"; accent_dark="#1e40af"
            hero_eyebrow="Engineering Knowledge Base"
            hero_title="Technical standards, service runbooks, and architecture documentation."
            hero_desc="Centralized reference specifications covering service boundaries, observability schemas, change control, and operational readiness."
            card1_t="API Governance"; card1_d="Versioned OpenAPI contracts, idempotency semantics, and structured error envelopes across services."
            card2_t="Observability"; card2_d="Unified telemetry taxonomy for structured logs, latency histograms, and SLO burn-rate alerts."
            card3_t="Release Operations"; card3_d="Blue-green deployment checklists, schema migration rules, and automated rollback verification."
            ;;
        *)
            brand="${DECOY_SITE_NAME:-Meridian Cloud Systems}"
            tagline="${DECOY_SITE_TAGLINE:-Managed Edge Infrastructure & Reliability Engineering}"
            email="${DECOY_CONTACT_EMAIL:-hello@meridiancloud.example}"
            accent="#0f4c81"; accent_dark="#0b3a63"
            hero_eyebrow="Distributed Infrastructure"
            hero_title="Predictable edge compute and reliability engineering at global scale."
            hero_desc="We build fault-tolerant telemetry pipelines, regional failover automation, and low-latency delivery infrastructure for engineering teams."
            card1_t="Regional Edge Compute"; card1_d="Deterministic request routing across regional availability zones with automated health-based traffic draining."
            card2_t="Zero-Downtime Releases"; card2_d="Pre-flight schema verification, staged canary rollouts, and instant configuration rollback safeguards."
            card3_t="Compliance & Auditing"; card3_d="Tamper-evident operational logs, strict TLS posture, and automated security baseline validation."
            ;;
    esac

    local e_brand e_tagline e_email
    e_brand=$(_html_escape "$brand")
    e_tagline=$(_html_escape "$tagline")
    e_email=$(_html_escape "$email")

    local tmp_site
    tmp_site=$(mktemp -d "${TMPDIR:-/tmp}/3xui-site.XXXXXX") || return 1
    mkdir -p "$tmp_site/assets"

    local nav_block footer_block
    nav_block=$(cat <<EOF
  <header class="site-header">
    <div class="container nav-inner">
      <a class="brand" href="index.html">
        <span class="brand-badge" aria-hidden="true">M</span>
        <span>${e_brand}</span>
      </a>
      <button id="nav-toggle" class="nav-toggle" type="button" aria-expanded="false" aria-label="Toggle navigation">Menu</button>
      <nav id="site-nav" class="site-nav" aria-label="Main Navigation">
        <a href="index.html">Home</a>
        <a href="services.html">Services</a>
        <a href="docs.html">Documentation</a>
        <a href="about.html">About</a>
        <a href="contact.html" class="nav-cta">Contact</a>
      </nav>
    </div>
  </header>
EOF
)
    footer_block=$(cat <<EOF
  <footer class="site-footer">
    <div class="container footer-grid">
      <div>
        <strong>${e_brand}</strong>
        <p class="muted">${e_tagline}</p>
      </div>
      <div class="footer-links">
        <a href="services.html">Services</a>
        <a href="docs.html">Documentation</a>
        <a href="about.html">About</a>
        <a href="contact.html">Contact</a>
        <button id="open-legal-modal" class="link-btn" type="button">Privacy &amp; Terms</button>
      </div>
    </div>
    <div class="container footer-bottom">
      <span>&copy; 2026 ${e_brand}. All rights reserved.</span>
      <span class="muted">Contact: ${e_email}</span>
    </div>
  </footer>
  <div id="legal-modal" class="modal-backdrop hidden" role="dialog" aria-modal="true" aria-labelledby="legal-title">
    <div class="modal-box">
      <h3 id="legal-title">Privacy &amp; Acceptable Use</h3>
      <p class="muted">${e_brand} collects zero third-party advertising trackers on this public informational site. Contact submissions are processed locally in your browser unless explicitly integrated.</p>
      <button id="close-legal-modal" class="btn btn-primary" type="button">Close</button>
    </div>
  </div>
  <script src="assets/app.js"></script>
EOF
)

    cat > "$tmp_site/favicon.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="14" fill="${accent}"/>
  <path d="M18 44V20h7l7 12 7-12h7v24h-6V30l-8 13-8-13v14h-6z" fill="#ffffff"/>
</svg>
EOF

    cat > "$tmp_site/robots.txt" <<'EOF'
User-agent: *
Allow: /
Sitemap: /sitemap.xml
EOF

    cat > "$tmp_site/sitemap.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>/</loc></url>
  <url><loc>/services.html</loc></url>
  <url><loc>/docs.html</loc></url>
  <url><loc>/about.html</loc></url>
  <url><loc>/contact.html</loc></url>
</urlset>
EOF

    cat > "$tmp_site/assets/style.css" <<EOF
:root {
  --bg: #f8fafc;
  --surface: #ffffff;
  --surface-alt: #f1f5f9;
  --border: #e2e8f0;
  --text: #0f172a;
  --muted: #475569;
  --accent: ${accent};
  --accent-dark: ${accent_dark};
  --ok: #059669;
  --radius: 10px;
}
*, *::before, *::after { box-sizing: border-box; }
body {
  margin: 0;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  background: var(--bg);
  color: var(--text);
  line-height: 1.6;
}
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
.hidden { display: none !important; }
.muted { color: var(--muted); }
.container { width: 100%; max-width: 1120px; margin: 0 auto; padding: 0 1.25rem; }

.site-header {
  background: var(--surface);
  border-bottom: 1px solid var(--border);
  position: sticky;
  top: 0;
  z-index: 20;
}
.nav-inner {
  min-height: 64px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
}
.brand {
  display: inline-flex;
  align-items: center;
  gap: 0.6rem;
  font-weight: 700;
  font-size: 1.05rem;
  color: var(--text);
}
.brand:hover { text-decoration: none; }
.brand-badge {
  width: 30px;
  height: 30px;
  border-radius: 8px;
  background: var(--accent);
  color: #ffffff;
  display: grid;
  place-items: center;
  font-size: 0.9rem;
}
.site-nav { display: flex; align-items: center; gap: 1.25rem; }
.site-nav a { color: var(--muted); font-weight: 500; font-size: 0.95rem; }
.site-nav a:hover, .site-nav a.active { color: var(--text); text-decoration: none; }
.site-nav .nav-cta {
  padding: 0.42rem 0.85rem;
  background: var(--accent);
  color: #ffffff;
  border-radius: 7px;
}
.site-nav .nav-cta:hover { background: var(--accent-dark); color: #ffffff; }
.nav-toggle {
  display: none;
  background: var(--surface-alt);
  border: 1px solid var(--border);
  border-radius: 7px;
  padding: 0.4rem 0.75rem;
  cursor: pointer;
  font-weight: 600;
}

.hero {
  padding: 4rem 0 3rem;
  background: linear-gradient(180deg, #ffffff 0%, var(--bg) 100%);
  border-bottom: 1px solid var(--border);
}
.eyebrow {
  display: inline-block;
  font-size: 0.8rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--accent);
  margin-bottom: 0.6rem;
}
.hero h1 { margin: 0 0 1rem; font-size: clamp(1.85rem, 3.6vw, 2.75rem); line-height: 1.18; max-width: 760px; }
.hero p { margin: 0 0 1.5rem; font-size: 1.06rem; color: var(--muted); max-width: 660px; }
.actions { display: flex; gap: 0.75rem; flex-wrap: wrap; }

.btn {
  display: inline-block;
  padding: 0.62rem 1.15rem;
  border-radius: 8px;
  font-weight: 600;
  font-size: 0.94rem;
  border: 1px solid var(--border);
  cursor: pointer;
  background: var(--surface);
  color: var(--text);
}
.btn-primary { background: var(--accent); color: #ffffff; border-color: var(--accent); }
.btn-primary:hover { background: var(--accent-dark); text-decoration: none; }
.btn-ghost:hover { border-color: var(--accent); text-decoration: none; }

.section { padding: 3rem 0; }
.section-alt { background: var(--surface); border-top: 1px solid var(--border); border-bottom: 1px solid var(--border); }
.section-title { margin: 0 0 0.4rem; font-size: 1.55rem; }
.section-lead { margin: 0 0 1.75rem; color: var(--muted); max-width: 680px; }

.metrics-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
  gap: 1rem;
  margin-top: 2.25rem;
}
.metric {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 1rem 1.15rem;
}
.metric strong { display: block; font-size: 1.45rem; color: var(--text); }
.metric span { font-size: 0.86rem; color: var(--muted); }

.cards-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
  gap: 1.15rem;
}
.card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 1.35rem;
}
.card h3 { margin: 0 0 0.5rem; font-size: 1.1rem; }
.card p { margin: 0; color: var(--muted); font-size: 0.95rem; }

.filter-tabs { display: flex; gap: 0.5rem; flex-wrap: wrap; margin-bottom: 1.5rem; }
.tab-btn {
  padding: 0.42rem 0.9rem;
  border-radius: 999px;
  border: 1px solid var(--border);
  background: var(--surface);
  cursor: pointer;
  font-weight: 500;
}
.tab-btn.active { background: var(--accent); color: #ffffff; border-color: var(--accent); }

.search-input {
  width: 100%;
  max-width: 440px;
  padding: 0.62rem 0.85rem;
  border: 1px solid var(--border);
  border-radius: 8px;
  font-size: 0.96rem;
  margin-bottom: 1.5rem;
}

.faq-list { display: flex; flex-direction: column; gap: 0.75rem; max-width: 780px; }
.faq-item {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  overflow: hidden;
}
.faq-q {
  width: 100%;
  text-align: left;
  background: transparent;
  border: 0;
  padding: 1rem 1.15rem;
  font-weight: 600;
  font-size: 0.98rem;
  cursor: pointer;
  display: flex;
  justify-content: space-between;
}
.faq-a { padding: 0 1.15rem 1rem; color: var(--muted); font-size: 0.94rem; }

.form-card {
  max-width: 620px;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 1.5rem;
  display: flex;
  flex-direction: column;
  gap: 1rem;
}
.field { display: flex; flex-direction: column; gap: 0.3rem; font-size: 0.9rem; font-weight: 500; }
.field input, .field select, .field textarea {
  padding: 0.58rem 0.75rem;
  border: 1px solid var(--border);
  border-radius: 7px;
  font-family: inherit;
  font-size: 0.95rem;
}
.status-banner {
  padding: 0.75rem 1rem;
  border-radius: 8px;
  background: rgba(5, 150, 105, 0.1);
  border: 1px solid rgba(5, 150, 105, 0.35);
  color: var(--ok);
  font-weight: 500;
}

.site-footer {
  border-top: 1px solid var(--border);
  background: var(--surface);
  padding: 2.25rem 0 1.5rem;
  margin-top: 2rem;
}
.footer-grid { display: flex; justify-content: space-between; gap: 1.5rem; flex-wrap: wrap; }
.footer-links { display: flex; gap: 1.1rem; flex-wrap: wrap; align-items: center; }
.footer-links a, .link-btn { color: var(--muted); font-size: 0.9rem; background: none; border: 0; padding: 0; cursor: pointer; font-family: inherit; }
.footer-bottom {
  margin-top: 1.5rem;
  padding-top: 1rem;
  border-top: 1px solid var(--border);
  display: flex;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.5rem;
  font-size: 0.84rem;
}

.modal-backdrop {
  position: fixed;
  inset: 0;
  background: rgba(15, 23, 42, 0.6);
  display: grid;
  place-items: center;
  padding: 1rem;
  z-index: 40;
}
.modal-box {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  max-width: 460px;
  padding: 1.5rem;
}

@media (max-width: 760px) {
  .nav-toggle { display: inline-block; }
  .site-nav {
    display: none;
    position: absolute;
    top: 64px;
    left: 0;
    right: 0;
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    flex-direction: column;
    align-items: flex-start;
    padding: 1rem 1.25rem;
  }
  .site-nav.open { display: flex; }
}
EOF

    cat > "$tmp_site/assets/app.js" <<'EOF'
(function () {
  "use strict";

  var navBtn = document.getElementById("nav-toggle");
  var navMenu = document.getElementById("site-nav");
  if (navBtn && navMenu) {
    navBtn.addEventListener("click", function () {
      var expanded = navMenu.classList.toggle("open");
      navBtn.setAttribute("aria-expanded", expanded ? "true" : "false");
    });
  }

  var openModal = document.getElementById("open-legal-modal");
  var closeModal = document.getElementById("close-legal-modal");
  var modal = document.getElementById("legal-modal");
  if (openModal && closeModal && modal) {
    openModal.addEventListener("click", function () { modal.classList.remove("hidden"); });
    closeModal.addEventListener("click", function () { modal.classList.add("hidden"); });
  }

  document.querySelectorAll(".faq-q").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var answer = btn.nextElementSibling;
      if (answer) {
        var hidden = answer.classList.toggle("hidden");
        btn.setAttribute("aria-expanded", hidden ? "false" : "true");
      }
    });
  });

  document.querySelectorAll(".tab-btn").forEach(function (tab) {
    tab.addEventListener("click", function () {
      var filter = tab.getAttribute("data-filter");
      document.querySelectorAll(".tab-btn").forEach(function (t) { t.classList.remove("active"); });
      tab.classList.add("active");
      document.querySelectorAll("[data-category]").forEach(function (card) {
        var cat = card.getAttribute("data-category");
        card.classList.toggle("hidden", filter !== "all" && cat !== filter);
      });
    });
  });

  var docSearch = document.getElementById("doc-search");
  if (docSearch) {
    docSearch.addEventListener("input", function () {
      var q = docSearch.value.trim().toLowerCase();
      document.querySelectorAll("[data-doc-item]").forEach(function (item) {
        var text = (item.textContent || "").toLowerCase();
        item.classList.toggle("hidden", q !== "" && text.indexOf(q) === -1);
      });
    });
  }

  var contactForm = document.getElementById("contact-form");
  if (contactForm) {
    contactForm.addEventListener("submit", function (e) {
      e.preventDefault();
      var nameEl = document.getElementById("c-name");
      var emailEl = document.getElementById("c-email");
      var msgEl = document.getElementById("c-message");
      var outEl = document.getElementById("contact-status");
      if (!nameEl.value.trim() || !emailEl.value.trim() || msgEl.value.trim().length < 10) {
        outEl.textContent = "Please complete all fields (message must be at least 10 characters).";
        outEl.classList.remove("hidden");
        return;
      }
      outEl.textContent = "Thank you, " + nameEl.value.trim() + ". Your inquiry reference #" + Math.floor(10000 + Math.random() * 89999) + " has been recorded.";
      outEl.classList.remove("hidden");
      contactForm.reset();
    });
  }
})();
EOF

    cat > "$tmp_site/index.html" <<EOF
<!DOCTYPE html>
<!-- static-site-template:v2 -->
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${e_brand} — ${e_tagline}</title>
  <link rel="icon" href="favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="assets/style.css">
</head>
<body>
${nav_block}
  <main>
    <section class="hero">
      <div class="container">
        <span class="eyebrow">${hero_eyebrow}</span>
        <h1>${hero_title}</h1>
        <p>${hero_desc}</p>
        <div class="actions">
          <a class="btn btn-primary" href="services.html">Explore Services</a>
          <a class="btn btn-ghost" href="docs.html">Read Documentation</a>
        </div>
        <div class="metrics-grid">
          <div class="metric"><strong>99.98%</strong><span>Measured quarterly availability</span></div>
          <div class="metric"><strong>&lt; 28 ms</strong><span>Median regional edge response</span></div>
          <div class="metric"><strong>24 / 7</strong><span>Automated telemetry &amp; failover</span></div>
          <div class="metric"><strong>ISO-27001</strong><span>Aligned operational controls</span></div>
        </div>
      </div>
    </section>

    <section class="section">
      <div class="container">
        <h2 class="section-title">Core Capabilities</h2>
        <p class="section-lead">Structured engineering practices built for predictability, maintainability, and clear audit trails.</p>
        <div class="cards-grid">
          <article class="card"><h3>${card1_t}</h3><p>${card1_d}</p></article>
          <article class="card"><h3>${card2_t}</h3><p>${card2_d}</p></article>
          <article class="card"><h3>${card3_t}</h3><p>${card3_d}</p></article>
        </div>
      </div>
    </section>

    <section class="section section-alt">
      <div class="container">
        <h2 class="section-title">Frequently Asked Questions</h2>
        <p class="section-lead">Common operational questions from engineering and security teams.</p>
        <div class="faq-list">
          <div class="faq-item">
            <button class="faq-q" type="button" aria-expanded="false">How are maintenance windows communicated? <span>+</span></button>
            <div class="faq-a hidden">Planned upgrades run during low-traffic regional windows with pre-flight verification and automatic rollback checks.</div>
          </div>
          <div class="faq-item">
            <button class="faq-q" type="button" aria-expanded="false">What SLA targets apply to managed infrastructure? <span>+</span></button>
            <div class="faq-a hidden">Production tiers include 99.95% uptime commitments backed by multi-region health monitoring and automated failover.</div>
          </div>
          <div class="faq-item">
            <button class="faq-q" type="button" aria-expanded="false">How can teams request an architecture review? <span>+</span></button>
            <div class="faq-a hidden">Reach out via our <a href="contact.html">contact page</a> or review our published standards in the <a href="docs.html">documentation hub</a>.</div>
          </div>
        </div>
      </div>
    </section>
  </main>
${footer_block}
</body>
</html>
EOF

    cat > "$tmp_site/services.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Services — ${e_brand}</title>
  <link rel="icon" href="favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="assets/style.css">
</head>
<body>
${nav_block}
  <main class="section">
    <div class="container">
      <span class="eyebrow">Solutions Catalog</span>
      <h1 class="section-title">Managed Services &amp; Architecture Practice</h1>
      <p class="section-lead">Filter by practice area to review deliverables and operational scope.</p>
      <div class="filter-tabs" role="tablist">
        <button class="tab-btn active" type="button" data-filter="all">All</button>
        <button class="tab-btn" type="button" data-filter="infra">Infrastructure</button>
        <button class="tab-btn" type="button" data-filter="reliability">Reliability</button>
        <button class="tab-btn" type="button" data-filter="security">Security</button>
      </div>
      <div class="cards-grid">
        <article class="card" data-category="infra"><h3>${card1_t}</h3><p>${card1_d}</p></article>
        <article class="card" data-category="reliability"><h3>${card2_t}</h3><p>${card2_d}</p></article>
        <article class="card" data-category="security"><h3>${card3_t}</h3><p>${card3_d}</p></article>
        <article class="card" data-category="infra"><h3>TLS &amp; Edge Routing</h3><p>Automated certificate lifecycle governance, HTTP/2 &amp; HTTP/3 termination, and strict transport policy headers.</p></article>
        <article class="card" data-category="reliability"><h3>Disaster Recovery Drills</h3><p>Scheduled point-in-time archive verification and automated cross-host restore testing.</p></article>
        <article class="card" data-category="security"><h3>Baseline Auditing</h3><p>Continuous verification of least-privilege permissions, credential hygiene, and host firewall rules.</p></article>
      </div>
    </div>
  </main>
${footer_block}
</body>
</html>
EOF

    cat > "$tmp_site/docs.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Documentation — ${e_brand}</title>
  <link rel="icon" href="favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="assets/style.css">
</head>
<body>
${nav_block}
  <main class="section">
    <div class="container">
      <span class="eyebrow">Reference Hub</span>
      <h1 class="section-title">Technical Documentation &amp; Guides</h1>
      <p class="section-lead">Search platform standards, reliability playbooks, and integration checklists.</p>
      <input id="doc-search" class="search-input" type="search" placeholder="Filter documentation topics (e.g., TLS, backup, SLA)...">
      <div class="cards-grid">
        <article class="card" data-doc-item><h3>Edge TLS &amp; HSTS Standard</h3><p>Configuration baseline requiring TLS 1.2+, strict transport headers, and automated certificate renewal verification.</p></article>
        <article class="card" data-doc-item><h3>Backup &amp; Recovery Policy</h3><p>Online consistent database snapshots paired with pre-restore safety archives and checksum validation.</p></article>
        <article class="card" data-doc-item><h3>Change Management &amp; Rollback</h3><p>Pre-flight artifact validation, staged release rollout, and automated health-checked rollback gates.</p></article>
        <article class="card" data-doc-item><h3>Incident Response SLA</h3><p>Severity classification matrix (INFO, WARN, ERROR, CRITICAL) with root-cause diagnostics and resolution playbooks.</p></article>
      </div>
    </div>
  </main>
${footer_block}
</body>
</html>
EOF

    cat > "$tmp_site/about.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>About — ${e_brand}</title>
  <link rel="icon" href="favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="assets/style.css">
</head>
<body>
${nav_block}
  <main class="section">
    <div class="container">
      <span class="eyebrow">Organization</span>
      <h1 class="section-title">About ${e_brand}</h1>
      <p class="section-lead">${e_tagline}</p>
      <div class="cards-grid">
        <article class="card"><h3>Engineering Philosophy</h3><p>Every production system deserves clear failure boundaries, reproducible builds, and transparent diagnostics without brittle shortcuts.</p></article>
        <article class="card"><h3>Regional Presence</h3><p>Operational support spanning European, North American, and Asia-Pacific availability zones with consistent observability.</p></article>
        <article class="card"><h3>Security Commitment</h3><p>Least-privilege defaults, minimal runtime attack surfaces, and regular independent configuration verification.</p></article>
      </div>
    </div>
  </main>
${footer_block}
</body>
</html>
EOF

    cat > "$tmp_site/contact.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Contact — ${e_brand}</title>
  <link rel="icon" href="favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="assets/style.css">
</head>
<body>
${nav_block}
  <main class="section">
    <div class="container">
      <span class="eyebrow">Get In Touch</span>
      <h1 class="section-title">Contact ${e_brand}</h1>
      <p class="section-lead">Questions about infrastructure engineering, SLAs, or documentation? Send a note below or email ${e_email}.</p>
      <form id="contact-form" class="form-card" novalidate>
        <div id="contact-status" class="status-banner hidden" role="status"></div>
        <label class="field"><span>Full Name</span><input id="c-name" type="text" required placeholder="Alex Rivera"></label>
        <label class="field"><span>Work Email</span><input id="c-email" type="email" required placeholder="alex@company.example"></label>
        <label class="field"><span>Topic</span><select id="c-topic"><option>Infrastructure Review</option><option>Reliability Consulting</option><option>Documentation Feedback</option></select></label>
        <label class="field"><span>Message</span><textarea id="c-message" rows="4" required placeholder="Tell us about your workload and timeline..."></textarea></label>
        <button class="btn btn-primary" type="submit">Send Inquiry</button>
      </form>
    </div>
  </main>
${footer_block}
</body>
</html>
EOF

    cat > "$tmp_site/404.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Page Not Found — ${e_brand}</title>
  <link rel="icon" href="favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="assets/style.css">
</head>
<body>
${nav_block}
  <main class="section">
    <div class="container">
      <span class="eyebrow">404 Not Found</span>
      <h1 class="section-title">The requested page could not be found.</h1>
      <p class="section-lead">Check the URL or return to the homepage to browse services and documentation.</p>
      <a class="btn btn-primary" href="index.html">Back to Home</a>
    </div>
  </main>
${footer_block}
</body>
</html>
EOF

    if $REMOTE; then
        tar -cf - -C "$tmp_site" . | ssh_cmd "mkdir -p $(quote_sh "$site_dir") && chmod 755 $(quote_sh "$site_dir") && tar --no-same-owner -xf - -C $(quote_sh "$site_dir") && find $(quote_sh "$site_dir") -type d -exec chmod 755 {} + && find $(quote_sh "$site_dir") -type f -exec chmod 644 {} +"
    else
        mkdir -p "$site_dir/assets"
        cp -a "$tmp_site/." "$site_dir/"
        find "$site_dir" -type d -exec chmod 755 {} + 2>/dev/null || true
        find "$site_dir" -type f -exec chmod 644 {} + 2>/dev/null || true
    fi
    rm -rf "$tmp_site"
}

_caddy_tls_block() {
    local domain="$1" port="$2" use_existing="${3:-false}"
    if [[ "$use_existing" == "true" ]]; then
        printf '    tls /root/cert/%s/fullchain.pem /root/cert/%s/privkey.pem\n' "$domain" "$domain"
    elif [[ "$port" != "443" ]]; then
        cat <<'TLS'
    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
TLS
    fi
}

_caddy_sub_routes() {
    local sub_no_slash="$1" sub_json_no_slash="$2" sub_port="$3"
    cat <<EOF

    @sub {
        path ${sub_no_slash} ${sub_no_slash}/*
    }
    handle @sub {
        request_body {
            max_size 64KB
        }
        header Cache-Control "no-store"
        reverse_proxy 127.0.0.1:${sub_port} {
            header_up Host {http.request.hostport}
            header_up X-Forwarded-Host {http.request.host}
            header_up X-Forwarded-Port {http.request.port}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    @subjson {
        path ${sub_json_no_slash} ${sub_json_no_slash}/*
    }
    handle @subjson {
        request_body {
            max_size 64KB
        }
        header Cache-Control "no-store"
        reverse_proxy 127.0.0.1:${sub_port} {
            header_up Host {http.request.hostport}
            header_up X-Forwarded-Host {http.request.host}
            header_up X-Forwarded-Port {http.request.port}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
EOF
}

_regex_escape_caddy() {
    local s="${1-}"
    printf '%s' "$s" | sed -E 's/[][(){}.+*?^$|\\]/\\&/g; s/[[:space:]]+/\\s+/g'
}

_caddy_probe_redirect_blocks() {
    local panel_path="${1:-/}" webpanel_path="${2:-/deploy/}" sub_path="${3:-/sub/}" sub_json_path="${4:-/json/}"
    local inbound_paths_csv="${5:-}"

    $PROBE_REDIRECT_ENABLED || return 0

    local active_state="${PROBE_ACTIVE_STATE:-primary}"
    local effective_mode="redirect"
    local dest="${PROBE_REDIRECT_TARGET:-https://www.cloudflare.com}"
    local status="${PROBE_REDIRECT_STATUS:-302}"

    case "$active_state" in
        disabled|fallback_decoy)
            return 0
            ;;
        fallback_404)
            effective_mode="not_found"
            ;;
        fallback_secondary)
            if validate_redirect_url "${PROBE_FALLBACK_URL:-}"; then
                dest="$PROBE_FALLBACK_URL"
            else
                return 0
            fi
            ;;
        *)
            validate_redirect_url "$dest" || return 0
            ;;
    esac

    local allow_ips="127.0.0.1 ::1"
    if [[ -n "${PROBE_ALLOW_CIDRS:-}" ]]; then
        local a_item a_trimmed
        local IFS=','
        for a_item in $PROBE_ALLOW_CIDRS; do
            a_trimmed=$(printf '%s' "$a_item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            [[ -n "$a_trimmed" ]] && validate_cidr_entry "$a_trimmed" && allow_ips+=" ${a_trimmed}"
        done
    fi

    local action_block=""
    if [[ "$effective_mode" == "not_found" ]]; then
        action_block=$(cat <<'ACT'
        root * /srv/site
        header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
        rewrite * /404.html
        file_server {
            status 404
        }
ACT
)
    else
        action_block="        redir ${dest} ${status}"
    fi

    # 1. Blocked CIDRs
    if [[ -n "${PROBE_BLOCK_CIDRS:-}" ]]; then
        local block_ips="" b_item b_trimmed
        local IFS=','
        for b_item in $PROBE_BLOCK_CIDRS; do
            b_trimmed=$(printf '%s' "$b_item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            [[ -n "$b_trimmed" ]] && validate_cidr_entry "$b_trimmed" && block_ips+="${block_ips:+ }${b_trimmed}"
        done
        if [[ -n "$block_ips" ]]; then
            cat <<EOF

    @probe_cidr {
        remote_ip ${block_ips}
        not remote_ip ${allow_ips}
    }
    handle @probe_cidr {
${action_block}
    }
EOF
        fi
    fi

    # 2. Unusual HTTP methods
    if [[ "${PROBE_DETECT_BAD_METHODS:-true}" == "true" ]]; then
        cat <<EOF

    @probe_method {
        not remote_ip ${allow_ips}
        not method GET HEAD OPTIONS
    }
    handle @probe_method {
${action_block}
    }
EOF
    fi

    # 3. Missing or empty User-Agent (Caddy v2 requires `not header User-Agent *`)
    if [[ "${PROBE_DETECT_EMPTY_UA:-true}" == "true" ]]; then
        cat <<EOF

    @probe_missing_ua {
        not remote_ip ${allow_ips}
        not header User-Agent *
    }
    handle @probe_missing_ua {
${action_block}
    }

    @probe_empty_ua {
        not remote_ip ${allow_ips}
        header User-Agent ""
    }
    handle @probe_empty_ua {
${action_block}
    }
EOF
    fi

    # 4. Suspicious User-Agent patterns (scanners / CLI / crawlers / custom)
    local ua_parts=()
    [[ "${PROBE_DETECT_SCANNERS:-true}" == "true" ]] && ua_parts+=("nikto|sqlmap|nmap|masscan|zgrab|gobuster|dirbuster|nuclei|ffuf|wpscan|acunetix|nessus|openvas|censys|shodan|httpx|feroxbuster|wfuzz|hydra|jaeles")
    [[ "${PROBE_DETECT_CLI:-true}" == "true" ]] && ua_parts+=("curl/|wget/|python-requests|python-urllib|aiohttp|go-http-client|libwww-perl|httpie|okhttp|axios/|java/")
    [[ "${PROBE_DETECT_CRAWLERS:-false}" == "true" ]] && ua_parts+=("ahrefsbot|semrushbot|mj12bot|dotbot|petalbot|bytespider|gptbot|ccbot|claudebot|yandexbot|bingbot|googlebot|baiduspider")
    if [[ -n "${PROBE_CUSTOM_UA:-}" ]]; then
        local c_item c_trimmed c_esc
        local IFS=','
        for c_item in $PROBE_CUSTOM_UA; do
            c_trimmed=$(printf '%s' "$c_item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            [[ -n "$c_trimmed" ]] || continue
            [[ "$c_trimmed" =~ [\{\}\;\<\>\"\'\\\`] ]] && continue
            c_esc=$(_regex_escape_caddy "$c_trimmed")
            [[ -n "$c_esc" ]] && ua_parts+=("$c_esc")
        done
    fi
    if (( ${#ua_parts[@]} > 0 )); then
        local ua_joined="" part
        for part in "${ua_parts[@]}"; do
            ua_joined+="${ua_joined:+|}${part}"
        done
        cat <<EOF

    @probe_ua {
        not remote_ip ${allow_ips}
        header_regexp User-Agent (?i)(${ua_joined})
    }
    handle @probe_ua {
${action_block}
    }
EOF
    fi

    # 5. Suspicious exploit/scanner paths (filtered against ALL protected service routes)
    local candidate_paths=()
    if [[ "${PROBE_DETECT_PATHS:-true}" == "true" ]]; then
        candidate_paths+=(
            "/.env" "/.env.*" "/.git" "/.git/*" "/.svn/*"
            "/wp-admin" "/wp-admin/*" "/wp-login.php" "/xmlrpc.php"
            "/phpmyadmin" "/phpmyadmin/*" "/admin.php" "/config.php"
            "/cgi-bin/*" "/actuator" "/actuator/*" "/server-status"
            "/vendor/phpunit/*" "/boaform/*" "/HNAP1" "/shell" "/sdk"
        )
    fi
    if [[ -n "${PROBE_CUSTOM_PATHS:-}" ]]; then
        local cp_item cp_trimmed
        local IFS=','
        for cp_item in $PROBE_CUSTOM_PATHS; do
            cp_trimmed=$(printf '%s' "$cp_item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            [[ -n "$cp_trimmed" ]] || continue
            [[ "$cp_trimmed" != /* ]] && cp_trimmed="/$cp_trimmed"
            [[ "$cp_trimmed" == "/" || "$cp_trimmed" == "/*" || "$cp_trimmed" == *".."* || "$cp_trimmed" == *"//"* ]] && continue
            [[ "$cp_trimmed" =~ [[:space:]\{\}\;\<\>\"\'\\\`] ]] && continue
            candidate_paths+=("$cp_trimmed")
        done
    fi

    if (( ${#candidate_paths[@]} > 0 )); then
        local protected_list=() p_cand
        [[ -n "$panel_path" && "$panel_path" != "/" ]] && protected_list+=("$panel_path")
        [[ -n "$webpanel_path" && "$webpanel_path" != "/" ]] && protected_list+=("$webpanel_path")
        [[ -n "$sub_path" && "$sub_path" != "/" ]] && protected_list+=("$sub_path")
        [[ -n "$sub_json_path" && "$sub_json_path" != "/" ]] && protected_list+=("$sub_json_path")
        if [[ -n "$inbound_paths_csv" ]]; then
            local ip_tok
            local IFS=','
            for ip_tok in $inbound_paths_csv; do
                [[ -n "$ip_tok" && "$ip_tok" != "/" ]] && protected_list+=("$ip_tok")
            done
        fi

        local safe_paths="" cand cand_base prot_p overlaps
        for cand in "${candidate_paths[@]}"; do
            cand_base="${cand%\*}"
            overlaps=false
            for prot_p in "${protected_list[@]:-}"; do
                [[ -n "$prot_p" ]] || continue
                if _paths_overlap "$cand_base" "$prot_p"; then
                    overlaps=true
                    break
                fi
            done
            $overlaps || safe_paths+="${safe_paths:+ }${cand}"
        done

        if [[ -n "$safe_paths" ]]; then
            cat <<EOF

    @probe_path {
        not remote_ip ${allow_ips}
        path ${safe_paths}
    }
    handle @probe_path {
${action_block}
    }
EOF
        fi
    fi
}

_caddy_decoy_handlers() {
    cat <<'DECOY'

    @decoy_exists {
        file {
            root /srv/site
            try_files {path} {path}.html {path}/index.html
        }
    }
    handle @decoy_exists {
        root * /srv/site
        header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
        rewrite * {http.matchers.file.relative}
        file_server
    }

    handle {
        root * /srv/site
        header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
        rewrite * /404.html
        file_server {
            status 404
        }
    }
DECOY
}

_caddy_reload() {
    is_caddy_running || { error "Container 3xui_caddy is not running"; return 1; }
    run "docker exec 3xui_caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null" || return 1
    if run_q "docker exec 3xui_caddy test -S /config/admin.sock"; then
        run "docker exec 3xui_caddy caddy reload --config /etc/caddy/Caddyfile --address unix//config/admin.sock >/dev/null" && return 0
    fi
    if run_q "docker exec 3xui_caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null"; then
        return 0
    fi
    warn "Recreating Caddy container to apply listener/admin configuration..."
    compose up -d --force-recreate caddy >/dev/null
}

generate_caddyfile() {
    local panel_domain="$1"
    local https_port="$2"
    local acme_email="$3"
    local panel_port="$4"
    local panel_path="$5"
    local sub_mode="$6"
    local sub_domain="$7"
    local sub_port="$8"
    local sub_path="$9"
    local sub_json_path="${10}"
    local use_existing_panel_cert="${11:-false}"
    local use_existing_sub_cert="${12:-false}"

    if run_q "test -f $(quote_sh "$INSTALL_DIR/caddy/probe.conf")"; then
        load_probe_conf
    elif run_q "test -f $(quote_sh "$INSTALL_DIR/caddy/probe-state.json")"; then
        local st_raw st_val
        st_raw=$(run_out "cat $(quote_sh "$INSTALL_DIR/caddy/probe-state.json")" || true)
        st_val=$(printf '%s' "$st_raw" | sed -nE 's/.*"active_state"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)
        case "$st_val" in
            primary|fallback_secondary|fallback_decoy|fallback_404|disabled) PROBE_ACTIVE_STATE="$st_val" ;;
        esac
    fi
    if run_q "test -f $(quote_sh "$INSTALL_DIR/webpanel/webpanel.conf")"; then
        load_webpanel_conf
    fi

    local base_no_slash="${panel_path%/}"
    [[ -z "$base_no_slash" ]] && base_no_slash="/"

    local wp_path_norm wp_no_slash
    wp_path_norm=$(_normalize_webpath "${WEBPANEL_PATH:-/deploy/}")
    wp_no_slash="${wp_path_norm%/}"
    [[ -z "$wp_no_slash" ]] && wp_no_slash="/deploy"

    local sub_no_slash="${sub_path%/}"
    local sub_json_no_slash="${sub_json_path%/}"

    local needs_acme=false
    [[ "$use_existing_panel_cert" != "true" ]] && needs_acme=true
    [[ "$sub_mode" == "dedicated" && "$use_existing_sub_cert" != "true" ]] && needs_acme=true

    local global_lines="    admin unix//config/admin.sock"$'\n'
    if $needs_acme && [[ -n "$acme_email" ]]; then
        global_lines+="    email ${acme_email}"$'\n'
    elif ! $needs_acme; then
        global_lines+="    auto_https disable_redirects"$'\n'
    fi

    local global_opts=""
    printf -v global_opts '{\n%s}\n\n' "$global_lines"

    local panel_addr="$panel_domain"
    [[ "$https_port" != "443" ]] && panel_addr="${panel_domain}:${https_port}"

    local panel_tls=""
    panel_tls=$(_caddy_tls_block "$panel_domain" "$https_port" "$use_existing_panel_cert")

    local webpanel_redir="" webpanel_block="" effective_wp_path=""
    if $WEBPANEL_ENABLED && [[ "$base_no_slash" != "/" ]] && ! _paths_overlap "$wp_path_norm" "$panel_path"; then
        local wp_sub_conflict=false
        if [[ "$sub_mode" == "same" ]] && { _paths_overlap "$wp_path_norm" "$sub_path" || _paths_overlap "$wp_path_norm" "$sub_json_path"; }; then
            wp_sub_conflict=true
        fi
        if ! $wp_sub_conflict; then
            effective_wp_path="$wp_path_norm"
            webpanel_redir=$'\n'"    redir ${wp_no_slash} ${wp_no_slash}/ 308"
            webpanel_block=$(cat <<EOF

    @webpanel {
        path ${wp_no_slash}/*
    }
    handle @webpanel {
        uri strip_prefix ${wp_no_slash}
        request_body {
            max_size 16MB
        }
        reverse_proxy ${WEBPANEL_BIND:-127.0.0.1}:${WEBPANEL_PORT:-2059} {
            header_up Host {http.request.hostport}
            header_up X-Forwarded-Host {http.request.host}
            header_up X-Forwarded-Port {http.request.port}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            header_up X-Forwarded-Prefix ${wp_no_slash}
        }
    }
EOF
)
        else
            warn "WebPanel path '$wp_path_norm' overlaps subscription path; skipping @webpanel route."
        fi
    fi

    local same_sub_block=""
    if [[ "$sub_mode" == "same" ]]; then
        same_sub_block=$(_caddy_sub_routes "$sub_no_slash" "$sub_json_no_slash" "$sub_port")
    fi

    local caddy_inbound_blocks="" inbound_paths_csv=""
    caddy_inbound_blocks=$(_collect_caddy_inbound_blocks "$panel_path" "$sub_path" "$sub_json_path" || true)
    local inbounds_raw="${INBOUNDS_OVERRIDE:-}"
    [[ -z "$inbounds_raw" ]] && inbounds_raw=$(get_xui_inbounds || true)
    if [[ -n "$inbounds_raw" ]]; then
        local i_id i_en i_proto i_listen i_port i_rem i_net i_sec i_path i_fw
        while IFS='|' read -r i_id i_en i_proto i_listen i_port i_rem i_net i_sec i_path i_fw; do
            _is_inbound_enabled "$i_en" || continue
            _is_loopback_addr "${i_listen:-}" || continue
            [[ -n "$i_path" && "$i_path" != "/" ]] && inbound_paths_csv+="${inbound_paths_csv:+,}${i_path}"
        done <<< "$inbounds_raw"
    fi

    local panel_probe_blocks=""
    panel_probe_blocks=$(_caddy_probe_redirect_blocks "$panel_path" "$effective_wp_path" "$([[ "$sub_mode" == "same" ]] && printf '%s' "$sub_path")" "$([[ "$sub_mode" == "same" ]] && printf '%s' "$sub_json_path")" "$inbound_paths_csv" || true)

    local decoy_handlers=""
    decoy_handlers=$(_caddy_decoy_handlers)

    local dedicated_sub_block=""
    if [[ "$sub_mode" == "dedicated" && -n "$sub_domain" ]]; then
        local sub_addr="$sub_domain"
        [[ "$https_port" != "443" ]] && sub_addr="${sub_domain}:${https_port}"
        local sub_tls=""
        sub_tls=$(_caddy_tls_block "$sub_domain" "$https_port" "$use_existing_sub_cert")
        local sub_routes=""
        sub_routes=$(_caddy_sub_routes "$sub_no_slash" "$sub_json_no_slash" "$sub_port")
        local sub_probe_blocks=""
        sub_probe_blocks=$(_caddy_probe_redirect_blocks "$panel_path" "$effective_wp_path" "$sub_path" "$sub_json_path" "$inbound_paths_csv" || true)
        dedicated_sub_block=$(cat <<EOF

${sub_addr} {
${sub_tls}
    encode gzip zstd

    header {
        -Server
        -X-Powered-By
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=()"
        X-Robots-Tag "noindex, nofollow, noarchive"
    }${sub_routes}${sub_probe_blocks}${decoy_handlers}
}
EOF
)
    fi

    local caddyfile_body
    caddyfile_body=$(cat <<EOF
${global_opts}${panel_addr} {
${panel_tls}
    encode gzip zstd

    header {
        -Server
        -X-Powered-By
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=()"
        X-Robots-Tag "noindex, nofollow, noarchive"
    }$(
        if [[ "$base_no_slash" != "/" ]]; then
            printf '\n\n    redir %s %s/ 308' "$base_no_slash" "$base_no_slash"
        fi
    )${webpanel_redir}

    @panel {
        path $( [[ "$base_no_slash" == "/" ]] && printf '*' || printf '%s/*' "$base_no_slash" )
    }
    handle @panel {
        request_body {
            max_size 32MB
        }
        reverse_proxy 127.0.0.1:${panel_port} {
            header_up Host {http.request.hostport}
            header_up X-Forwarded-Host {http.request.host}
            header_up X-Forwarded-Port {http.request.port}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }${webpanel_block}${same_sub_block}${caddy_inbound_blocks}${panel_probe_blocks}${decoy_handlers}
}${dedicated_sub_block}
EOF
)

    local cdir="$INSTALL_DIR/caddy"
    local cfile="$cdir/Caddyfile"
    run "mkdir -p $(quote_sh "$cdir") $(quote_sh "$cdir/data") $(quote_sh "$cdir/config") && chmod 755 $(quote_sh "$cdir") && chmod 700 $(quote_sh "$cdir/data") $(quote_sh "$cdir/config")" || return 1
    if $REMOTE; then
        printf '%s\n' "$caddyfile_body" | ssh_cmd "cat > $(quote_sh "$cfile") && chmod 644 $(quote_sh "$cfile")"
    else
        printf '%s\n' "$caddyfile_body" > "$cfile"
        chmod 644 "$cfile"
    fi
}

setup_reverse_proxy() {
    require_deployed || return 1
    require_running  || return 1

    get_panel_info || true
    local prev_sub_mode="$SUB_MODE"

    echo ""
    echo -e "  ${BOLD}${MAGENTA}Caddy Reverse Proxy Setup${NC}"
    echo -e "  ${DIM}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${NC}"
    echo "  Places 3X-UI behind HTTPS (Caddy), locks the panel to 127.0.0.1,"
    echo "  and serves a decoy website on '/'."
    echo ""

    # 1. Ensure non-root webBasePath so '/' belongs to the decoy site.
    local panel_path="$PANEL_PATH"
    if [[ "$panel_path" == "/" ]]; then
        warn "Panel Web Base Path is currently '/' — a dedicated path is required behind a decoy site."
        local new_base
        read -rp "  Web Base Path (e.g. /panel/) [Enter to auto-generate random path]: " new_base
        if [[ -z "$new_base" ]]; then
            new_base="/$(generate_random_string 12)/"
        else
            [[ "$new_base" != /* ]] && new_base="/$new_base"
            [[ "$new_base" != */ ]] && new_base="${new_base}/"
        fi
        if [[ "$new_base" == "/" ]] || ! validate_webpath "$new_base"; then
            error "Invalid non-root Web Base Path"
            return 1
        fi
        run "$(_xui_setting_cmd -webBasePath "$new_base")" || return 1
        panel_path="$new_base"
        success "Panel Web Base Path set to ${BOLD}${panel_path}${NC}"
    fi

    # 2. Panel domain, HTTPS port, ACME email.
    local panel_domain https_port acme_email
    read -rp "  Panel domain (e.g. panel.example.com)${PROXY_DOMAIN:+ [$PROXY_DOMAIN]}: " panel_domain
    panel_domain="${panel_domain:-$PROXY_DOMAIN}"
    if ! validate_domain "$panel_domain"; then
        error "Valid domain required (e.g. panel.example.com)"
        return 1
    fi

    read -rp "  HTTPS listen port (use e.g. 8443 if Xray Reality uses 443) [${PROXY_PORT:-443}]: " https_port
    https_port="${https_port:-${PROXY_PORT:-443}}"
    if ! validate_port "$https_port"; then
        error "Invalid HTTPS port: $https_port"
        return 1
    fi
    if [[ "$https_port" == "$PANEL_PORT" ]]; then
        error "Caddy HTTPS port cannot equal internal panel port ($PANEL_PORT)"
        return 1
    fi

    local use_existing_panel_cert=false
    if run_q "test -f $(quote_sh "$INSTALL_DIR/cert/$panel_domain/fullchain.pem") && test -f $(quote_sh "$INSTALL_DIR/cert/$panel_domain/privkey.pem")"; then
        confirm "Found existing cert in $INSTALL_DIR/cert/$panel_domain/. Use it instead of Caddy ACME?" && use_existing_panel_cert=true
    fi

    # 3. Subscription proxy configuration.
    tui_select "Subscription Server Proxy" "How should 3X-UI subscription links be proxied?" \
        "Dedicated subscription domain (e.g. sub.example.com)" \
        "Same domain as panel (${panel_domain}/sub/)" \
        "Do not proxy subscriptions (panel only)" \
        "Cancel"
    local sub_sel=$?
    clear_screen

    local sub_mode="none" sub_domain="" sub_port="${SUB_PORT:-2096}" sub_path="${SUB_PATH:-/sub/}" sub_json_path="${SUB_JSON_PATH:-/json/}"
    local use_existing_sub_cert=false
    case "$sub_sel" in
        0) sub_mode="dedicated" ;;
        1) sub_mode="same" ;;
        2) sub_mode="none" ;;
        3|255) info "Cancelled"; return 0 ;;
    esac

    if [[ "$sub_mode" != "none" ]]; then
        validate_port "${SUB_PORT_DB:-}" && sub_port="$SUB_PORT_DB"
        [[ -n "${SUB_PATH_DB:-}" ]] && sub_path=$(_normalize_webpath "$SUB_PATH_DB")
        [[ -n "${SUB_JSON_PATH_DB:-}" ]] && sub_json_path=$(_normalize_webpath "$SUB_JSON_PATH_DB")

        if [[ "$sub_mode" == "dedicated" ]]; then
            local def_sdom="${SUB_DOMAIN:-$SUB_DOMAIN_DB}"
            [[ "$def_sdom" == "$panel_domain" ]] && def_sdom=""
            read -rp "  Subscription domain (e.g. sub.example.com)${def_sdom:+ [$def_sdom]}: " sub_domain
            sub_domain="${sub_domain:-$def_sdom}"
            if ! validate_domain "$sub_domain" || [[ "$sub_domain" == "$panel_domain" ]]; then
                error "Valid subscription domain different from $panel_domain is required"
                return 1
            fi
            if run_q "test -f $(quote_sh "$INSTALL_DIR/cert/$sub_domain/fullchain.pem") && test -f $(quote_sh "$INSTALL_DIR/cert/$sub_domain/privkey.pem")"; then
                confirm "Found existing cert for $sub_domain. Use it instead of Caddy ACME?" && use_existing_sub_cert=true
            fi
        fi

        read -rp "  Internal 3X-UI subscription port [${sub_port}]: " input_sp
        sub_port="${input_sp:-$sub_port}"
        validate_port "$sub_port" || { error "Invalid subscription port"; return 1; }
        [[ "$sub_port" == "$PANEL_PORT" ]] && { error "Subscription port must differ from panel port ($PANEL_PORT)"; return 1; }
        [[ "$sub_port" == "$https_port" ]] && { error "Internal subscription port cannot equal Caddy HTTPS port ($https_port)"; return 1; }

        read -rp "  Subscription path [${sub_path}]: " input_spath
        sub_path=$(_normalize_webpath "${input_spath:-$sub_path}")
        if [[ "$sub_path" == "/" ]] || ! validate_webpath "$sub_path"; then
            error "Invalid subscription path (cannot be '/')"
            return 1
        fi
        if [[ "$sub_mode" == "same" ]] && _paths_overlap "$sub_path" "$panel_path"; then
            error "Subscription path '$sub_path' overlaps panel path '$panel_path'"
            return 1
        fi

        read -rp "  JSON subscription path [${sub_json_path}]: " input_jpath
        sub_json_path=$(_normalize_webpath "${input_jpath:-$sub_json_path}")
        if [[ "$sub_json_path" == "/" ]] || ! validate_webpath "$sub_json_path" || _paths_overlap "$sub_path" "$sub_json_path"; then
            error "Invalid or overlapping JSON subscription path"
            return 1
        fi
        if [[ "$sub_mode" == "same" ]] && _paths_overlap "$sub_json_path" "$panel_path"; then
            error "JSON subscription path '$sub_json_path' overlaps panel path '$panel_path'"
            return 1
        fi
    fi

    local needs_acme=false
    ! $use_existing_panel_cert && needs_acme=true
    [[ "$sub_mode" == "dedicated" ]] && ! $use_existing_sub_cert && needs_acme=true
    if [[ "$sub_mode" != "none" ]] && $needs_acme && [[ "$sub_port" == "80" ]]; then
        error "Internal subscription port cannot be 80 while ACME HTTP-01 uses port 80"
        return 1
    fi

    if $needs_acme; then
        read -rp "  Email for ACME TLS notices [${PROXY_EMAIL:-blank to skip}]: " acme_email
        [[ "$acme_email" == "blank to skip" ]] && acme_email=""
        acme_email="${acme_email:-$PROXY_EMAIL}"
        if [[ -n "$acme_email" ]] && ! validate_email "$acme_email"; then
            error "Invalid email address: $acme_email"
            return 1
        fi
    else
        acme_email=""
    fi

    local port_sfx=""
    [[ "$https_port" != "443" ]] && port_sfx=":${https_port}"
    local ext_panel_url="https://${panel_domain}${port_sfx}${panel_path}"
    local ext_sub_url="" ext_sub_json_url="" sub_host=""
    if [[ "$sub_mode" == "dedicated" ]]; then
        sub_host="$sub_domain"
        ext_sub_url="https://${sub_domain}${port_sfx}${sub_path}"
        ext_sub_json_url="https://${sub_domain}${port_sfx}${sub_json_path}"
    elif [[ "$sub_mode" == "same" ]]; then
        sub_host="$panel_domain"
        ext_sub_url="https://${panel_domain}${port_sfx}${sub_path}"
        ext_sub_json_url="https://${panel_domain}${port_sfx}${sub_json_path}"
    fi

    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo -e "    Panel URL    : ${BOLD}${ext_panel_url}${NC} -> 127.0.0.1:${PANEL_PORT}"
    echo -e "    Camouflage   : https://${panel_domain}${port_sfx}/ -> /srv/site/"
    if [[ -n "$ext_sub_url" ]]; then
        echo -e "    Sub Domain   : ${BOLD}${sub_host}${NC}"
        echo -e "    Sub URL      : ${BOLD}${ext_sub_url}${NC} -> 127.0.0.1:${sub_port}"
        echo -e "    Sub JSON URL : ${BOLD}${ext_sub_json_url}${NC} -> 127.0.0.1:${sub_port}"
    fi

    echo ""
    _check_domain_dns "$panel_domain" || true
    [[ "$sub_mode" == "dedicated" ]] && { _check_domain_dns "$sub_domain" || true; }

    confirm "Apply reverse proxy configuration?" || { info "Cancelled"; return 0; }

    # Check if HTTPS port, ACME port 80, or internal sub_port conflicts with inbounds or host sockets.
    local inbound_conflicts=""
    local inbounds_list=""
    inbounds_list=$(get_xui_inbounds || true)
    if [[ -n "$inbounds_list" ]]; then
        local i_id i_en i_proto i_listen i_port i_rem i_net i_sec i_path i_fw
        while IFS='|' read -r i_id i_en i_proto i_listen i_port i_rem i_net i_sec i_path i_fw; do
            _is_inbound_enabled "$i_en" || continue
            if [[ "$sub_mode" != "none" && "$i_port" == "$sub_port" ]]; then
                error "Inbound #${i_id} (${i_rem:-unnamed}, ${i_proto}/${i_net}) already uses port ${sub_port} — choose a different subscription port."
                return 1
            fi
            _is_loopback_addr "${i_listen:-}" && continue
            if [[ "$i_port" == "$https_port" ]] || ( $needs_acme && [[ "$i_port" == "80" ]] ); then
                inbound_conflicts+="\n    * Inbound #${i_id} (${i_rem:-unnamed}, ${i_proto}/${i_net}) on port ${i_port}"
            fi
        done <<< "$inbounds_list"
    fi
    if [[ -n "$inbound_conflicts" ]]; then
        warn "Public 3X-UI inbound(s) conflict with Caddy port(s):${inbound_conflicts}"
        echo "  Tip: Use a custom HTTPS port (e.g. 8443) for Caddy so port 443 remains free for Xray Reality/VLESS."
        confirm "Continue with Caddy on port ${https_port} anyway?" || { info "Cancelled"; return 0; }
    fi

    local busy_ports=""
    if ! is_caddy_running; then
        local check_p
        for check_p in $https_port $($needs_acme && echo 80); do
            if run_q "ss -tuln 2>/dev/null | grep -qE ':${check_p}[[:space:]]'"; then
                busy_ports+=" ${check_p}"
            fi
        done
        if [[ -n "$busy_ports" ]]; then
            warn "Port(s)${busy_ports} appear to already be listening on this host!"
            confirm "Continue anyway?" || { info "Cancelled"; return 0; }
        fi
    fi

    PROXY_ENABLED=true
    PROXY_DOMAIN="$panel_domain"
    PROXY_PORT="$https_port"
    PROXY_EMAIL="$acme_email"
    SUB_MODE="$sub_mode"
    SUB_DOMAIN="$sub_domain"
    SUB_PORT="$sub_port"
    SUB_PATH="$sub_path"
    SUB_JSON_PATH="$sub_json_path"

    load_webpanel_conf
    WEBPANEL_ENABLED=true
    WEBPANEL_DOMAIN="$panel_domain"
    WEBPANEL_BIND="127.0.0.1"
    WEBPANEL_PORT=$(_find_free_webpanel_port "$PANEL_PORT" "$sub_port" "$https_port")
    WEBPANEL_PATH=$(_choose_exclusive_webpanel_path "$panel_path" "$sub_path" "$sub_json_path")

    info "Generating decoy site, Caddyfile, and updating compose.yaml..."
    generate_decoy_site false || return 1
    generate_caddyfile "$panel_domain" "$https_port" "$acme_email" "$PANEL_PORT" "$panel_path" \
        "$sub_mode" "$sub_domain" "$sub_port" "$sub_path" "$sub_json_path" \
        "$use_existing_panel_cert" "$use_existing_sub_cert" || return 1
    save_proxy_conf || return 1
    save_webpanel_conf || warn "Could not save webpanel.conf"
    inject_caddy_compose || return 1

    info "Pulling and starting Caddy container..."
    compose up -d || { error "Failed to start Caddy container (3X-UI listenIP not yet changed)"; return 1; }
    if is_caddy_running; then
        _caddy_reload || warn "Caddy reload reported an error — check 'View Caddy logs'."
    fi

    info "Locking 3X-UI panel to loopback (127.0.0.1)..."
    run "$(_xui_setting_cmd -listenIP 127.0.0.1)" >/dev/null || true
    xui_db_set "webListen" "127.0.0.1" || return 1
    xui_db_set "webDomain" "$panel_domain" || return 1
    xui_db_set "webCertFile" "" || return 1
    xui_db_set "webKeyFile" "" || return 1

    if [[ "$sub_mode" != "none" ]]; then
        info "Configuring 3X-UI subscription server for proxy..."
        local sub_enc="${SUB_ENCRYPT_DB:-true}"
        [[ "$sub_enc" != "true" && "$sub_enc" != "false" ]] && sub_enc="true"
        _apply_subscription_db_settings "true" "127.0.0.1" "$sub_host" "$sub_port" "$sub_path" \
            "true" "$sub_json_path" "$sub_enc" "" "" \
            "$ext_sub_url" "$ext_sub_json_url" || return 1
    elif [[ "$prev_sub_mode" != "none" ]] || _is_loopback_addr "${SUB_LISTEN_DB:-}"; then
        info "Clearing previous reverse-proxy subscription overrides..."
        _clear_subscription_proxy_db
    fi

    info "Restarting 3X-UI to apply loopback & subscription settings..."
    compose restart 3xui >/dev/null || true

    local wp_init_pass=""
    info "Enabling standalone Web Management Panel on https://${panel_domain}${port_sfx}${WEBPANEL_PATH}..."
    if enable_webpanel auto; then
        wp_init_pass="${_LAST_WEBPANEL_INIT_PASS:-}"
        _LAST_WEBPANEL_INIT_PASS=""
    else
        warn "Web Management Panel setup encountered a warning; run 'manage.sh webpanel enable' later."
    fi

    invalidate_status
    verify_panel_loaded 12 || true
    if [[ "$sub_mode" != "none" ]]; then
        verify_subscription_endpoint 8 || true
    fi
    echo ""
    success "Caddy reverse proxy is active!"
    echo -e "  Panel URL    : ${BOLD}${ext_panel_url}${NC}"
    echo -e "  WebPanel URL : ${BOLD}https://${panel_domain}${port_sfx}${WEBPANEL_PATH}${NC}"
    if [[ -n "$wp_init_pass" ]]; then
        echo -e "  WebPanel Auth: ${BOLD}${WEBPANEL_USER}${NC} / ${BOLD}${YELLOW}${wp_init_pass}${NC}  (save this now!)"
        wp_init_pass=""
    fi
    echo -e "  Decoy URL    : ${BOLD}https://${panel_domain}${port_sfx}/${NC}"
    [[ -n "$ext_sub_url" ]] && echo -e "  Sub URL      : ${BOLD}${ext_sub_url}${NC}"
    echo -e "  ${DIM}Ensure DNS points to this server and firewall allows 80/tcp + ${https_port}/tcp+udp.${NC}"
}

configure_reverse_proxy_cli() {
    require_deployed || return 1
    require_running  || return 1
    get_panel_info || true
    load_webpanel_conf

    local prev_sub_mode="$SUB_MODE"
    local panel_domain="${PROXY_DOMAIN:-}" https_port="${PROXY_PORT:-443}" acme_email="${PROXY_EMAIL:-}"
    local sub_mode="${SUB_MODE:-none}" sub_domain="${SUB_DOMAIN:-}" sub_port="${SUB_PORT_DB:-${SUB_PORT:-2096}}"
    local sub_path="${SUB_PATH_DB:-${SUB_PATH:-/sub/}}" sub_json_path="${SUB_JSON_PATH_DB:-${SUB_JSON_PATH:-/json/}}"
    local use_existing_panel_cert=false use_existing_sub_cert=false
    if [[ -n "$panel_domain" ]]; then
        run_q "grep -q $(quote_sh "tls /root/cert/$panel_domain/") $(quote_sh "$INSTALL_DIR/caddy/Caddyfile")" && use_existing_panel_cert=true
    fi
    if [[ -n "$sub_domain" ]]; then
        run_q "grep -q $(quote_sh "tls /root/cert/$sub_domain/") $(quote_sh "$INSTALL_DIR/caddy/Caddyfile")" && use_existing_sub_cert=true
    fi

    local kv k v
    for kv in "$@"; do
        [[ "$kv" == *=* ]] || continue
        k="${kv%%=*}"
        v="${kv#*=}"
        case "$k" in
            domain)         panel_domain="$v" ;;
            port)           https_port="$v" ;;
            email)          acme_email="$v" ;;
            sub_mode)       sub_mode="$v" ;;
            sub_domain)     sub_domain="$v" ;;
            sub_port)       sub_port="$v" ;;
            sub_path)       sub_path="$v" ;;
            sub_json_path)  sub_json_path="$v" ;;
            use_panel_cert) [[ "$v" == "true" ]] && use_existing_panel_cert=true || use_existing_panel_cert=false ;;
            use_sub_cert)   [[ "$v" == "true" ]] && use_existing_sub_cert=true || use_existing_sub_cert=false ;;
            *)              error "Unknown proxy configure parameter: $k"; return 1 ;;
        esac
    done

    validate_domain "$panel_domain" || { error "Valid panel domain required (e.g. panel.example.com)"; return 1; }
    validate_port "$https_port" || { error "Invalid HTTPS port: $https_port"; return 1; }
    [[ "$https_port" == "$PANEL_PORT" ]] && { error "Caddy HTTPS port cannot equal internal panel port ($PANEL_PORT)"; return 1; }
    [[ -n "$acme_email" ]] && ! validate_email "$acme_email" && { error "Invalid ACME email: $acme_email"; return 1; }
    [[ "$sub_mode" =~ ^(none|same|dedicated)$ ]] || { error "sub_mode must be none, same, or dedicated"; return 1; }

    local panel_path="$PANEL_PATH"
    if [[ "$panel_path" == "/" ]]; then
        local gen_path="/$(generate_random_string 12)/"
        run "$(_xui_setting_cmd -webBasePath "$gen_path")" || { error "Failed to assign non-root Web Base Path"; return 1; }
        panel_path="$gen_path"
        info "Assigned non-root panel Web Base Path: ${panel_path}"
    fi

    if [[ "$sub_mode" != "none" ]]; then
        validate_port "$sub_port" || { error "Invalid subscription port: $sub_port"; return 1; }
        [[ "$sub_port" == "$PANEL_PORT" ]] && { error "Subscription port must differ from panel port ($PANEL_PORT)"; return 1; }
        [[ "$sub_port" == "$https_port" ]] && { error "Internal subscription port cannot equal Caddy HTTPS port ($https_port)"; return 1; }
        sub_path=$(_normalize_webpath "$sub_path")
        sub_json_path=$(_normalize_webpath "$sub_json_path")
        if [[ "$sub_path" == "/" ]] || ! validate_webpath "$sub_path"; then
            error "Invalid subscription path: $sub_path"
            return 1
        fi
        if [[ "$sub_json_path" == "/" ]] || ! validate_webpath "$sub_json_path" || _paths_overlap "$sub_path" "$sub_json_path"; then
            error "Invalid or overlapping JSON subscription path: $sub_json_path"
            return 1
        fi
        if [[ "$sub_mode" == "same" ]]; then
            if _paths_overlap "$sub_path" "$panel_path" || _paths_overlap "$sub_json_path" "$panel_path"; then
                error "Subscription paths overlap panel path '$panel_path'"
                return 1
            fi
        elif [[ "$sub_mode" == "dedicated" ]]; then
            if ! validate_domain "$sub_domain" || [[ "$sub_domain" == "$panel_domain" ]]; then
                error "Valid subscription domain different from $panel_domain is required"
                return 1
            fi
        fi
    else
        sub_domain=""
    fi

    if $use_existing_panel_cert && ! run_q "test -f $(quote_sh "$INSTALL_DIR/cert/$panel_domain/fullchain.pem") && test -f $(quote_sh "$INSTALL_DIR/cert/$panel_domain/privkey.pem")"; then
        error "Existing certificate requested for $panel_domain, but files are missing in $INSTALL_DIR/cert/$panel_domain/"
        return 1
    fi
    if [[ "$sub_mode" == "dedicated" ]] && $use_existing_sub_cert && ! run_q "test -f $(quote_sh "$INSTALL_DIR/cert/$sub_domain/fullchain.pem") && test -f $(quote_sh "$INSTALL_DIR/cert/$sub_domain/privkey.pem")"; then
        error "Existing certificate requested for $sub_domain, but files are missing in $INSTALL_DIR/cert/$sub_domain/"
        return 1
    fi

    # Snapshot proxy.conf, Caddyfile, webpanel.conf for transactional rollback
    local pconf="$INSTALL_DIR/caddy/proxy.conf" pconf_bak="$INSTALL_DIR/caddy/proxy.conf.bak"
    local cf="$INSTALL_DIR/caddy/Caddyfile" cf_bak="$INSTALL_DIR/caddy/Caddyfile.bak"
    local wpconf="$INSTALL_DIR/webpanel/webpanel.conf" wpconf_bak="$INSTALL_DIR/webpanel/webpanel.conf.bak"
    local had_pconf=false had_cf=false had_wpconf=false
    run_q "test -f $(quote_sh "$pconf")" && { had_pconf=true; run "cp $(quote_sh "$pconf") $(quote_sh "$pconf_bak")" || true; }
    run_q "test -f $(quote_sh "$cf")" && { had_cf=true; run "cp $(quote_sh "$cf") $(quote_sh "$cf_bak")" || true; }
    run_q "test -f $(quote_sh "$wpconf")" && { had_wpconf=true; run "cp $(quote_sh "$wpconf") $(quote_sh "$wpconf_bak")" || true; }

    _restore_proxy_snapshot() {
        $had_pconf && run_q "mv -f $(quote_sh "$pconf_bak") $(quote_sh "$pconf")" || run_q "rm -f $(quote_sh "$pconf_bak")" || true
        $had_cf && run_q "mv -f $(quote_sh "$cf_bak") $(quote_sh "$cf")" || run_q "rm -f $(quote_sh "$cf_bak")" || true
        $had_wpconf && run_q "mv -f $(quote_sh "$wpconf_bak") $(quote_sh "$wpconf")" || run_q "rm -f $(quote_sh "$wpconf_bak")" || true
        load_proxy_conf
        load_webpanel_conf
    }

    PROXY_ENABLED=true
    PROXY_DOMAIN="$panel_domain"
    PROXY_PORT="$https_port"
    PROXY_EMAIL="$acme_email"
    SUB_MODE="$sub_mode"
    SUB_DOMAIN="$sub_domain"
    SUB_PORT="$sub_port"
    SUB_PATH="$sub_path"
    SUB_JSON_PATH="$sub_json_path"

    WEBPANEL_DOMAIN="$panel_domain"
    WEBPANEL_BIND="127.0.0.1"
    validate_port "$WEBPANEL_PORT" || WEBPANEL_PORT=$(_find_free_webpanel_port "$PANEL_PORT" "$sub_port" "$https_port")
    if ! $WEBPANEL_ENABLED; then
        WEBPANEL_ENABLED=true
    fi
    if _paths_overlap "$WEBPANEL_PATH" "$panel_path" \
        || { [[ "$sub_mode" == "same" ]] && { _paths_overlap "$WEBPANEL_PATH" "$sub_path" || _paths_overlap "$WEBPANEL_PATH" "$sub_json_path"; }; }; then
        WEBPANEL_PATH=$(_choose_exclusive_webpanel_path "$panel_path" "$sub_path" "$sub_json_path")
    fi

    generate_decoy_site false || { _restore_proxy_snapshot; return 1; }
    if ! generate_caddyfile "$panel_domain" "$https_port" "$acme_email" "$PANEL_PORT" "$panel_path" \
        "$sub_mode" "$sub_domain" "$sub_port" "$sub_path" "$sub_json_path" \
        "$use_existing_panel_cert" "$use_existing_sub_cert"; then
        _restore_proxy_snapshot
        error "Failed to generate Caddyfile; rolled back"
        return 1
    fi
    save_proxy_conf || { _restore_proxy_snapshot; return 1; }
    save_webpanel_conf || true
    inject_caddy_compose || { _restore_proxy_snapshot; return 1; }

    compose up -d || { _restore_proxy_snapshot; error "Failed to start Caddy container; rolled back"; return 1; }
    if is_caddy_running; then
        if ! _caddy_reload; then
            _restore_proxy_snapshot
            _caddy_reload >/dev/null 2>&1 || true
            error "Caddy rejected updated configuration; rolled back"
            return 1
        fi
    fi

    run_q "rm -f $(quote_sh "$pconf_bak") $(quote_sh "$cf_bak") $(quote_sh "$wpconf_bak")" || true

    info "Locking 3X-UI panel to loopback (127.0.0.1) & updating webDomain..."
    run "$(_xui_setting_cmd -listenIP 127.0.0.1)" >/dev/null || true
    xui_db_set "webListen" "127.0.0.1" || return 1
    xui_db_set "webDomain" "$panel_domain" || return 1
    xui_db_set "webCertFile" "" || true
    xui_db_set "webKeyFile" "" || true

    local port_sfx=""
    [[ "$https_port" != "443" ]] && port_sfx=":${https_port}"
    local ext_sub_url="" ext_sub_json_url="" sub_host=""
    if [[ "$sub_mode" == "dedicated" ]]; then
        sub_host="$sub_domain"
        ext_sub_url="https://${sub_domain}${port_sfx}${sub_path}"
        ext_sub_json_url="https://${sub_domain}${port_sfx}${sub_json_path}"
    elif [[ "$sub_mode" == "same" ]]; then
        sub_host="$panel_domain"
        ext_sub_url="https://${panel_domain}${port_sfx}${sub_path}"
        ext_sub_json_url="https://${panel_domain}${port_sfx}${sub_json_path}"
    fi

    if [[ "$sub_mode" != "none" ]]; then
        local sub_enc="${SUB_ENCRYPT_DB:-true}"
        [[ "$sub_enc" != "true" && "$sub_enc" != "false" ]] && sub_enc="true"
        _apply_subscription_db_settings "true" "127.0.0.1" "$sub_host" "$sub_port" "$sub_path" \
            "true" "$sub_json_path" "$sub_enc" "" "" \
            "$ext_sub_url" "$ext_sub_json_url" || return 1
    elif [[ "$prev_sub_mode" != "none" ]] || _is_loopback_addr "${SUB_LISTEN_DB:-}"; then
        _clear_subscription_proxy_db
    fi

    compose restart 3xui >/dev/null || true
    if [[ "${WEBPANEL_NO_SELF_RESTART:-0}" != "1" ]]; then
        enable_webpanel auto || warn "WebPanel service update warning"
    fi

    invalidate_status
    verify_panel_loaded 10 || true
    [[ "$sub_mode" != "none" ]] && { verify_subscription_endpoint 6 || true; }
    printf 'WEBPANEL_NEW_URL=https://%s%s%s\n' "$panel_domain" "$port_sfx" "$WEBPANEL_PATH"
    success "Caddy reverse proxy configured for https://${panel_domain}${port_sfx}/"
}

_print_protected_paths() {
    get_panel_info >/dev/null 2>&1 || true
    load_webpanel_conf >/dev/null 2>&1 || true
    local p
    for p in "$PANEL_PATH" "$WEBPANEL_PATH" "$SUB_PATH" "$SUB_JSON_PATH"; do
        [[ -n "$p" && "$p" != "/" ]] && printf '%s\n' "$p"
    done
    local inbounds_raw="${INBOUNDS_OVERRIDE:-}"
    [[ -z "$inbounds_raw" ]] && inbounds_raw=$(get_xui_inbounds || true)
    if [[ -n "$inbounds_raw" ]]; then
        local i_id i_en i_proto i_listen i_port i_rem i_net i_sec i_path i_fw
        while IFS='|' read -r i_id i_en i_proto i_listen i_port i_rem i_net i_sec i_path i_fw; do
            _is_inbound_enabled "$i_en" || continue
            _is_loopback_addr "${i_listen:-}" || continue
            [[ -n "$i_path" && "$i_path" != "/" ]] && printf '%s\n' "$i_path"
        done <<< "$inbounds_raw"
    fi
}

_probe_url_health() {
    local url="${1-}"
    validate_redirect_url "$url" || return 1
    local code
    code=$(run_out "curl -ksSL -o /dev/null -w '%{http_code}' --proto '=http,https' --max-time 4 -I $(quote_sh "$url") 2>/dev/null" || echo "000")
    if [[ "$code" == "403" || "$code" == "405" || "$code" == "501" || "$code" == "000" ]]; then
        code=$(run_out "curl -ksSL -o /dev/null -w '%{http_code}' --proto '=http,https' --max-time 4 $(quote_sh "$url") 2>/dev/null" || echo "000")
    fi
    [[ "$code" =~ ^[1-4][0-9]{2}$ ]]
}

check_redirect_target_health() {
    local explicit_url="${1:-}"
    load_probe_conf
    if [[ -n "$explicit_url" ]]; then
        explicit_url=$(_normalize_redirect_url "$explicit_url")
        if ! validate_redirect_url "$explicit_url"; then
            error "Invalid redirect URL: $explicit_url"
            return 1
        fi
        if _probe_url_health "$explicit_url"; then
            success "Redirect target is reachable: $explicit_url"
            return 0
        fi
        warn "Redirect target is currently unreachable: $explicit_url"
        return 1
    fi

    if ! $PROBE_REDIRECT_ENABLED; then
        info "Probe redirection is disabled."
        return 0
    fi

    local prev_state="$PROBE_ACTIVE_STATE"
    local next_state="primary" effective_target="$PROBE_REDIRECT_TARGET" reason="Primary redirect destination is reachable."
    local primary_ok=true secondary_ok=false

    if ! _probe_url_health "$PROBE_REDIRECT_TARGET"; then
        primary_ok=false
        case "$PROBE_FALLBACK_MODE" in
            secondary_url)
                if validate_redirect_url "$PROBE_FALLBACK_URL" && _probe_url_health "$PROBE_FALLBACK_URL"; then
                    secondary_ok=true
                    next_state="fallback_secondary"
                    effective_target="$PROBE_FALLBACK_URL"
                    reason="Primary unreachable; switched to secondary fallback URL."
                else
                    next_state="fallback_decoy"
                    effective_target=""
                    reason="Primary and secondary targets unreachable; safely serving decoy site."
                fi
                ;;
            not_found)
                next_state="fallback_404"
                effective_target=""
                reason="Primary unreachable; fallback serving 404 page for probes."
                ;;
            *)
                next_state="fallback_decoy"
                effective_target=""
                reason="Primary unreachable; safely serving decoy website."
                ;;
        esac
    fi

    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
    local state_json
    state_json=$(cat <<EOF
{
  "active_state": "${next_state}",
  "effective_target": "${effective_target}",
  "reason": "${reason}",
  "last_checked": "${now_iso}",
  "primary_ok": ${primary_ok},
  "secondary_ok": ${secondary_ok}
}
EOF
)
    run "mkdir -p $(quote_sh "$INSTALL_DIR/caddy") && chmod 755 $(quote_sh "$INSTALL_DIR/caddy")" || true
    if $REMOTE; then
        printf '%s\n' "$state_json" | ssh_cmd "umask 077 && cat > $(quote_sh "$INSTALL_DIR/caddy/probe-state.json") && chmod 600 $(quote_sh "$INSTALL_DIR/caddy/probe-state.json")"
    else
        ( umask 077; printf '%s\n' "$state_json" > "$INSTALL_DIR/caddy/probe-state.json" )
        chmod 600 "$INSTALL_DIR/caddy/probe-state.json"
    fi

    PROBE_ACTIVE_STATE="$next_state"
    if [[ "$prev_state" != "$next_state" ]]; then
        warn "Probe redirect state changed: ${prev_state} -> ${next_state} (${reason})"
        get_panel_info >/dev/null 2>&1 || true
        _sync_caddy_if_active "$PANEL_PORT" "$PANEL_PATH" || true
    else
        info "Probe redirect active state: ${next_state} (${reason})"
    fi
}

configure_probe_redirect() {
    require_deployed || return 1
    load_probe_conf

    echo ""
    echo -e "  ${BOLD}${MAGENTA}Probe & Scanner Redirection Setup${NC}"
    echo -e "  ${DIM}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${NC}"
    echo "  Redirects detected scanners, CLI bots, and active probes on non-panel routes"
    echo "  while keeping legitimate browsers and 3X-UI/WebPanel/subscription routes untouched."
    echo ""
    echo -e "  Current state : $($PROBE_REDIRECT_ENABLED && echo "${GREEN}enabled${NC}" || echo "${DIM}disabled${NC}") (${PROBE_ACTIVE_STATE})"
    echo -e "  Target URL    : ${PROBE_REDIRECT_TARGET}"
    echo -e "  Fallback Mode : ${PROBE_FALLBACK_MODE}"
    echo ""

    if ! confirm "Enable probe & scanner redirection?"; then
        PROBE_REDIRECT_ENABLED=false
        save_probe_conf || return 1
        get_panel_info >/dev/null 2>&1 || true
        _sync_caddy_if_active "$PANEL_PORT" "$PANEL_PATH" || true
        success "Probe redirection disabled (serving decoy site for all non-panel traffic)."
        return 0
    fi

    local raw_target norm_target
    read -rp "  Redirect destination (e.g. www.cloudflare.com, www.speedtest.net) [${PROBE_REDIRECT_TARGET}]: " raw_target
    norm_target=$(_normalize_redirect_url "${raw_target:-$PROBE_REDIRECT_TARGET}")
    if ! validate_redirect_url "$norm_target"; then
        error "Invalid or unsafe redirect destination: $norm_target"
        return 1
    fi

    if ! _probe_url_health "$norm_target"; then
        warn "Destination '${norm_target}' did not respond during health check."
        confirm "Use '${norm_target}' anyway (safe fallback will activate if unreachable)?" || return 0
    else
        success "Destination reachable: ${norm_target}"
    fi

    local r_status fb_mode fb_url=""
    read -rp "  HTTP redirect status (301/302/307) [${PROBE_REDIRECT_STATUS}]: " r_status
    r_status="${r_status:-$PROBE_REDIRECT_STATUS}"
    [[ "$r_status" =~ ^(301|302|307)$ ]] || { error "Invalid status (choose 301, 302, or 307)"; return 1; }

    tui_select "Safe Fallback Behavior" "If '${norm_target}' becomes unreachable, how should Caddy respond?" \
        "Serve legitimate decoy website (Recommended)" \
        "Redirect to secondary fallback URL" \
        "Serve decoy 404 Not Found page"
    case $? in
        1)
            fb_mode="secondary_url"
            read -rp "  Secondary fallback URL [${PROBE_FALLBACK_URL:-https://www.speedtest.net}]: " fb_url
            fb_url=$(_normalize_redirect_url "${fb_url:-${PROBE_FALLBACK_URL:-https://www.speedtest.net}}")
            validate_redirect_url "$fb_url" || { error "Invalid secondary fallback URL"; return 1; }
            ;;
        2) fb_mode="not_found" ;;
        *) fb_mode="decoy" ;;
    esac

    confirm "Detect vulnerability scanners (nikto, sqlmap, nuclei, nmap, etc.)?" && PROBE_DETECT_SCANNERS=true || PROBE_DETECT_SCANNERS=false
    confirm "Detect CLI/script tools (curl, wget, python-requests, go-http)?" && PROBE_DETECT_CLI=true || PROBE_DETECT_CLI=false
    confirm "Detect missing or empty User-Agent headers?" && PROBE_DETECT_EMPTY_UA=true || PROBE_DETECT_EMPTY_UA=false
    confirm "Detect unusual HTTP methods (non-GET/HEAD/OPTIONS)?" && PROBE_DETECT_BAD_METHODS=true || PROBE_DETECT_BAD_METHODS=false
    confirm "Detect common exploit probe paths (/.env, /.git, /wp-admin, etc.)?" && PROBE_DETECT_PATHS=true || PROBE_DETECT_PATHS=false
    confirm "Also redirect aggressive SEO/AI crawlers (ahrefs, semrush, gptbot)?" && PROBE_DETECT_CRAWLERS=true || PROBE_DETECT_CRAWLERS=false

    PROBE_REDIRECT_ENABLED=true
    PROBE_REDIRECT_TARGET="$norm_target"
    PROBE_REDIRECT_STATUS="$r_status"
    PROBE_FALLBACK_MODE="$fb_mode"
    PROBE_FALLBACK_URL="$fb_url"

    save_probe_conf || return 1
    check_redirect_target_health || true
    get_panel_info >/dev/null 2>&1 || true
    _sync_caddy_if_active "$PANEL_PORT" "$PANEL_PATH" || return 1
    success "Probe redirection configured and active (${PROBE_REDIRECT_TARGET})."
}

status_reverse_proxy() {
    load_proxy_conf
    load_probe_conf
    load_webpanel_conf
    echo ""
    if ! $PROXY_ENABLED || [[ -z "$PROXY_DOMAIN" ]]; then
        echo -e "  Reverse Proxy : ${DIM}Not configured${NC}\n"
        return 0
    fi

    get_panel_info || true
    local caddy_state="${RED}Stopped${NC}"
    is_caddy_running && caddy_state="${GREEN}Running${NC}"
    local port_sfx=""
    [[ "$PROXY_PORT" != "443" ]] && port_sfx=":${PROXY_PORT}"

    echo -e "  Caddy Status  : $caddy_state"
    echo -e "  Panel Domain  : ${BOLD}https://${PROXY_DOMAIN}${port_sfx}${PANEL_PATH}${NC} (webDomain=${PANEL_DOMAIN:-(unset)})"
    if $WEBPANEL_ENABLED; then
        local wp_state="${RED}Stopped${NC}"
        is_webpanel_running && wp_state="${GREEN}Running${NC}"
        echo -e "  WebPanel URL  : ${BOLD}https://${PROXY_DOMAIN}${port_sfx}${WEBPANEL_PATH}${NC} ($wp_state)"
    fi
    echo -e "  Decoy Root    : https://${PROXY_DOMAIN}${port_sfx}/ (theme=${DECOY_THEME})"
    echo -e "  Probe Redir   : $($PROBE_REDIRECT_ENABLED && echo "${GREEN}enabled${NC} -> ${PROBE_REDIRECT_TARGET} (state=${PROBE_ACTIVE_STATE}, fallback=${PROBE_FALLBACK_MODE})" || echo "${DIM}disabled${NC}")"
    echo -e "  Backend Bind  : ${PANEL_LISTEN:-0.0.0.0}:${PANEL_PORT}"
    echo -e "  Sub Proxy     : ${SUB_MODE}  (subEnable=${SUB_ENABLE_DB:-unset}, jsonEnable=${SUB_JSON_ENABLE_DB:-unset})"
    if [[ "$SUB_MODE" != "none" || "$SUB_ENABLE_DB" == "true" ]]; then
        echo -e "  Sub Backend   : ${SUB_LISTEN_DB:-0.0.0.0}:${SUB_PORT_DB:-$SUB_PORT}  (subDomain=${SUB_DOMAIN_DB:-(unset)})"
        [[ -n "${SUB_URI_DB:-$PROXY_SUB_URL}" ]] && echo -e "  Sub URI       : ${BOLD}${SUB_URI_DB:-$PROXY_SUB_URL}${NC}"
        [[ -n "${SUB_JSON_URI_DB:-}" ]] && echo -e "  Sub JSON URI  : ${BOLD}${SUB_JSON_URI_DB}${NC}"
        if is_running; then
            verify_subscription_endpoint 2 || true
        fi
    fi
    echo ""
}

verify_reverse_proxy() {
    require_deployed || return 1
    require_running  || return 1
    get_panel_info || true

    echo ""
    echo -e "  ${BOLD}${MAGENTA}Proxy, Subscription & DNS Verification${NC}"
    echo -e "  ${DIM}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${NC}"
    local rc=0
    verify_panel_loaded 4 || rc=1
    if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
        _check_domain_dns "$PROXY_DOMAIN" || true
    fi
    if [[ "$SUB_MODE" != "none" || "$SUB_ENABLE_DB" == "true" ]]; then
        verify_subscription_endpoint 4 || rc=1
    fi
    echo ""
    return $rc
}

reload_reverse_proxy() {
    require_deployed || return 1
    _caddy_reload || return 1
    success "Caddy configuration validated & reloaded"
}

customize_decoy_site() {
    require_deployed || return 1
    load_probe_conf
    local index_file="$INSTALL_DIR/caddy/site/index.html"

    tui_select "Camouflage Decoy Site" "Theme: ${DECOY_THEME} (${DECOY_SITE_NAME})" \
        "Select built-in multi-page theme (Cloud / Studio / Docs)" \
        "Edit index.html interactively (nano / vi)" \
        "Upload custom local HTML file" \
        "Reset to default multi-page static website" \
        "Back"
    local sel=$?
    clear_screen

    case "$sel" in
        0)
            tui_select "Decoy Website Theme" "Choose a realistic website template:" \
                "Meridian Cloud Systems (Infrastructure & Edge)" \
                "Northstar Digital Studio (Product & Design)" \
                "Atlas Engineering Docs (Technical Portal)" \
                "Cancel"
            local tsel=$?
            clear_screen
            case "$tsel" in
                0) DECOY_THEME="cloud"; DECOY_SITE_NAME="Meridian Cloud Systems"; DECOY_SITE_TAGLINE="Managed Edge Infrastructure & Reliability Engineering"; DECOY_CONTACT_EMAIL="hello@meridiancloud.example" ;;
                1) DECOY_THEME="studio"; DECOY_SITE_NAME="Northstar Digital Studio"; DECOY_SITE_TAGLINE="Product Architecture, Design Systems & Web Engineering"; DECOY_CONTACT_EMAIL="hello@northstarstudio.example" ;;
                2) DECOY_THEME="docs"; DECOY_SITE_NAME="Atlas Engineering Docs"; DECOY_SITE_TAGLINE="Platform Architecture Reference, API Standards & Runbooks"; DECOY_CONTACT_EMAIL="docs@atlaseng.example" ;;
                *) return 0 ;;
            esac
            local custom_name custom_tag
            read -rp "  Site name [${DECOY_SITE_NAME}]: " custom_name
            [[ -n "$custom_name" ]] && DECOY_SITE_NAME="$custom_name"
            read -rp "  Tagline [${DECOY_SITE_TAGLINE}]: " custom_tag
            [[ -n "$custom_tag" ]] && DECOY_SITE_TAGLINE="$custom_tag"
            save_probe_conf || return 1
            generate_decoy_site true && success "Applied multi-page decoy site theme '${DECOY_THEME}'"
            ;;
        1)
            generate_decoy_site false || return 1
            if run_q "command -v nano || command -v vi"; then
                run_it "ed=\$(command -v nano || command -v vi); \"\$ed\" $(quote_sh "$index_file")"
                success "Edited $index_file"
            else
                error "Neither nano nor vi is installed on the target host"
            fi
            ;;
        2)
            echo ""
            local src_html
            read -rp "  Path to local HTML file: " src_html
            src_html="${src_html/#\~/$HOME}"
            [[ -f "$src_html" ]] || { error "File not found: $src_html"; return 1; }
            run "mkdir -p $(quote_sh "$INSTALL_DIR/caddy/site") && chmod 755 $(quote_sh "$INSTALL_DIR/caddy/site")"
            if $REMOTE; then
                ssh_copy "$src_html" "$index_file" && run "chmod 644 $(quote_sh "$index_file")"
            else
                cp "$src_html" "$index_file" && chmod 644 "$index_file"
            fi
            success "Uploaded custom decoy site"
            ;;
        3)
            generate_decoy_site true && success "Decoy site reset to default multi-page website"
            ;;
        4|255) return 0 ;;
    esac
}

disable_reverse_proxy() {
    require_deployed || return 1
    get_panel_info || true

    confirm "Stop Caddy reverse proxy, disable the Web Management Panel, and revert 3X-UI to direct access?" || { info "Cancelled"; return 0; }

    disable_webpanel >/dev/null 2>&1 || true

    info "Reverting 3X-UI listen IP & subscription URI overrides..."
    if is_running || is_pg_running || run_q "command -v sqlite3 && test -f $(quote_sh "$INSTALL_DIR/db/x-ui.db")"; then
        xui_db_set "webListen" "" || {
            is_running && run "$(_xui_setting_cmd -listenIP 0.0.0.0)" >/dev/null 2>&1 || warn "Could not clear webListen"
        }
        xui_db_set "webDomain" "" || true
        if [[ "$SUB_MODE" != "none" ]] || _is_loopback_addr "${SUB_LISTEN_DB:-}"; then
            _clear_subscription_proxy_db
        fi
    else
        warn "Panel/DB unavailable to reset webListen automatically — reset listenIP in Panel settings once started."
    fi

    info "Removing Caddy service from compose.yaml..."
    run_q "docker rm -f 3xui_caddy" || true
    remove_caddy_compose || warn "Could not strip caddy from compose.yaml"

    PROXY_ENABLED=false
    save_proxy_conf || true

    compose up -d --remove-orphans || true
    is_running && compose restart 3xui >/dev/null || true
    invalidate_status
    success "Reverse proxy & Web Management Panel disabled; 3X-UI restored to direct access."
}

manage_reverse_proxy() {
    require_deployed || return 1

    while true; do
        load_proxy_conf
        load_probe_conf
        local proxy_state="${DIM}not configured${NC}"
        if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
            if is_caddy_running; then
                proxy_state="${GREEN}active${NC} (${PROXY_DOMAIN}:${PROXY_PORT})"
            else
                proxy_state="${YELLOW}configured, stopped${NC} (${PROXY_DOMAIN}:${PROXY_PORT})"
            fi
        fi

        local redir_state="${DIM}disabled${NC}"
        $PROBE_REDIRECT_ENABLED && redir_state="${GREEN}on${NC} -> ${PROBE_REDIRECT_TARGET} (${PROBE_ACTIVE_STATE})"

        local header_text="  Proxy Status : ${proxy_state}\n  Sub Mode     : ${SUB_MODE}\n  Decoy Theme  : ${DECOY_THEME} (${DECOY_SITE_NAME})\n  Probe Redir  : ${redir_state}\n  Config Dir   : $INSTALL_DIR/caddy/"

        local opts=(
            "Setup / Reconfigure Caddy reverse proxy"
            "Reverse proxy status & URLs"
            "Verify panel, subscription & DNS routing"
            "Configure probe & bot redirection"
            "Check redirect target health"
            "Customize decoy site (themes / HTML)"
            "View Caddy logs (last 100 lines)"
            "Reload Caddy configuration"
            "Disable reverse proxy & revert to direct access"
            "Back"
        )

        tui_select "Reverse Proxy (Caddy)" "$header_text" "${opts[@]}"
        local sub=$?
        clear_screen
        case "$sub" in
            0) setup_reverse_proxy ;;
            1) status_reverse_proxy ;;
            2) verify_reverse_proxy || true ;;
            3) configure_probe_redirect ;;
            4) check_redirect_target_health || true ;;
            5) customize_decoy_site ;;
            6) run "docker logs --tail=100 3xui_caddy 2>/dev/null || echo '  (3xui_caddy not running)'" || true ;;
            7) reload_reverse_proxy ;;
            8) disable_reverse_proxy ;;
            9|255) _SKIP_PAUSE=true; return ;;
        esac
        echo ""
        read -rp "  Press Enter..."
    done
}

# ─── Standalone Web Management Panel (3xui-deploy-web) ──────────────────────
_find_free_webpanel_port() {
    local p_port="${1:-2053}" s_port="${2:-2096}" px_port="${3:-443}"
    local cand
    for cand in 2059 2060 2061 2062 2063 2064 2065 2066 2067 2068 2069 2070; do
        [[ "$cand" == "$p_port" || "$cand" == "$s_port" || "$cand" == "$px_port" ]] && continue
        if ! run_q "ss -tuln 2>/dev/null | grep -qE ':${cand}[[:space:]]'"; then
            printf '%s' "$cand"
            return 0
        fi
    done
    printf '2059'
}

_choose_exclusive_webpanel_path() {
    local panel_path="${1:-/}" sub_path="${2:-/sub/}" sub_json_path="${3:-/json/}"
    local candidates=("/deploy/" "/deploy-mgr/" "/3xui-deploy/" "/ops-console/")
    local cand
    for cand in "${candidates[@]}"; do
        _paths_overlap "$cand" "$panel_path" && continue
        _paths_overlap "$cand" "$sub_path" && continue
        _paths_overlap "$cand" "$sub_json_path" && continue
        printf '%s' "$cand"
        return 0
    done
    printf '/deploy-mgr/'
}

_ensure_python3() {
    if run_q "command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,9) else 1)'"; then
        return 0
    fi
    info "Installing Python 3 for standalone Web Management Panel..."
    if run_q "command -v apt-get"; then
        run "apt-get update -qq && apt-get install -y -qq python3" || return 1
    elif run_q "command -v dnf"; then
        run "dnf install -y python3" || return 1
    elif run_q "command -v apk"; then
        run "apk add --no-cache python3" || return 1
    else
        error "Python 3.9+ is required for the Web Management Panel."
        return 1
    fi
}

_install_webpanel_files() {
    local dst="$INSTALL_DIR/webpanel"
    run "mkdir -p $(quote_sh "$dst/static") && chmod 700 $(quote_sh "$dst") && chmod 755 $(quote_sh "$dst/static")" || return 1

    local script_dir=""
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
    fi

    if [[ -n "$script_dir" && -f "$script_dir/webpanel/server.py" && -f "$script_dir/webpanel/static/index.html" ]]; then
        if $REMOTE; then
            tar -cf - -C "$script_dir/webpanel" . | ssh_cmd "tar --no-same-owner -xf - -C $(quote_sh "$dst")" || return 1
        else
            cp -a "$script_dir/webpanel/." "$dst/" || return 1
        fi
    else
        local files=(
            "webpanel/__init__.py"
            "webpanel/auth.py"
            "webpanel/probe.py"
            "webpanel/ops.py"
            "webpanel/server.py"
            "webpanel/static/index.html"
            "webpanel/static/app.css"
            "webpanel/static/app.js"
        )
        local rel url target
        for rel in "${files[@]}"; do
            url="${REPO_RAW_BASE}/${rel}"
            target="${INSTALL_DIR}/${rel}"
            run "curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 $(quote_sh "$url") -o $(quote_sh "$target")" || {
                error "Failed to download ${rel} for Web Management Panel"
                return 1
            }
        done
    fi

    # Install a synchronized executable manage.sh inside $INSTALL_DIR/webpanel/manage.sh for ops.py
    if [[ -n "$script_dir" && -f "$script_dir/manage.sh" ]]; then
        if $REMOTE; then
            ssh_copy "$script_dir/manage.sh" "$dst/manage.sh" && run "chmod 755 $(quote_sh "$dst/manage.sh")" || return 1
        else
            cp "$script_dir/manage.sh" "$dst/manage.sh" && chmod 755 "$dst/manage.sh" || return 1
        fi
    else
        run "curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 $(quote_sh "$REPO_RAW_URL") -o $(quote_sh "$dst/manage.sh") && bash -n $(quote_sh "$dst/manage.sh") && chmod 755 $(quote_sh "$dst/manage.sh")" || return 1
    fi

    run "chmod 700 $(quote_sh "$dst") && chmod 755 $(quote_sh "$dst/static") && chmod 644 $(quote_sh "$dst")/*.py $(quote_sh "$dst/static")/*" || true
    run "python3 -m py_compile $(quote_sh "$dst/__init__.py") $(quote_sh "$dst/auth.py") $(quote_sh "$dst/probe.py") $(quote_sh "$dst/ops.py") $(quote_sh "$dst/server.py")" || {
        report_diagnostic "ERROR" "install_webpanel" \
            "WebPanel Python syntax verification failed" \
            "Web Management Panel ($dst)" \
            "Ensure Python 3.9+ is installed and re-run 'manage.sh webpanel enable'."
        return 1
    }
}

_setup_webpanel_service() {
    local svc_path="/etc/systemd/system/3xui-deploy-web.service"
    local unit_body
    unit_body=$(cat <<EOF
[Unit]
Description=3xui-deploy Standalone Web Management Panel
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=PYTHONPATH=${INSTALL_DIR}
Environment=XUI_INSTALL_DIR=${INSTALL_DIR}
Environment=XUI_BACKUP_DIR=${BACKUP_DIR}
ExecStart=/usr/bin/env python3 -m webpanel.server --install-dir ${INSTALL_DIR} --backup-dir ${BACKUP_DIR}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
)
    if run_q "command -v systemctl && [ -d /run/systemd/system ]"; then
        if $REMOTE; then
            printf '%s\n' "$unit_body" | ssh_cmd "cat > $(quote_sh "$svc_path") && chmod 644 $(quote_sh "$svc_path")" || return 1
        else
            printf '%s\n' "$unit_body" > "$svc_path"
            chmod 644 "$svc_path"
        fi
        run "systemctl daemon-reload && systemctl enable 3xui-deploy-web >/dev/null 2>&1 && systemctl restart 3xui-deploy-web" || return 1
        return 0
    fi

    # Fallback daemon launch when systemd is absent (e.g., containers)
    local pid_file="$INSTALL_DIR/webpanel/server.pid"
    local log_out="$INSTALL_DIR/logs/webpanel-server.log"
    run "mkdir -p $(quote_sh "$INSTALL_DIR/logs") && chmod 700 $(quote_sh "$INSTALL_DIR/logs")" || true
    run "if [ -f $(quote_sh "$pid_file") ]; then kill \$(cat $(quote_sh "$pid_file")) 2>/dev/null || true; fi"
    run "cd $(quote_sh "$INSTALL_DIR") && nohup env PYTHONPATH=$(quote_sh "$INSTALL_DIR") python3 -m webpanel.server --install-dir $(quote_sh "$INSTALL_DIR") --backup-dir $(quote_sh "$BACKUP_DIR") >$(quote_sh "$log_out") 2>&1 < /dev/null & echo \$! > $(quote_sh "$pid_file") && chmod 600 $(quote_sh "$pid_file")"
}

is_webpanel_running() {
    if run_q "systemctl is-active --quiet 3xui-deploy-web 2>/dev/null"; then
        return 0
    fi
    local pid_file="$INSTALL_DIR/webpanel/server.pid"
    run_q "test -f $(quote_sh "$pid_file") && kill -0 \$(cat $(quote_sh "$pid_file")) 2>/dev/null"
}

enable_webpanel() {
    local mode="${1:-interactive}"
    require_deployed || return 1
    load_proxy_conf
    load_webpanel_conf

    if ! $PROXY_ENABLED || [[ -z "$PROXY_DOMAIN" ]]; then
        error "A configured panel domain + Caddy reverse proxy is required before enabling the Web Management Panel."
        info "Run 'manage.sh proxy setup' first — the Web Management Panel is automatically enabled once a domain is configured."
        return 1
    fi

    get_panel_info >/dev/null 2>&1 || true
    if [[ "$PANEL_PATH" == "/" ]]; then
        error "3X-UI Web Base Path cannot be '/' when serving the Web Management Panel on ${PROXY_DOMAIN}."
        return 1
    fi

    _ensure_python3 || return 1
    _install_webpanel_files || return 1

    WEBPANEL_ENABLED=true
    WEBPANEL_DOMAIN="$PROXY_DOMAIN"
    WEBPANEL_BIND="127.0.0.1"
    validate_port "$WEBPANEL_PORT" || WEBPANEL_PORT=$(_find_free_webpanel_port "$PANEL_PORT" "$SUB_PORT" "$PROXY_PORT")
    WEBPANEL_PATH=$(_choose_exclusive_webpanel_path "$PANEL_PATH" "$SUB_PATH" "$SUB_JSON_PATH")
    save_webpanel_conf || return 1

    _LAST_WEBPANEL_INIT_PASS=""
    if ! run_q "test -s $(quote_sh "$INSTALL_DIR/webpanel/auth.json")"; then
        local init_pw
        init_pw=$(generate_random_string 20)
        local auth_cmd="PYTHONPATH=$(quote_sh "$INSTALL_DIR") python3 -m webpanel.auth init-admin $(quote_sh "$INSTALL_DIR/webpanel/auth.json") $(quote_sh "$WEBPANEL_USER")"
        if $REMOTE; then
            printf '%s\n' "$init_pw" | ssh_cmd "$auth_cmd" >/dev/null || { init_pw=""; error "Failed to initialize WebPanel admin credentials"; return 1; }
        else
            printf '%s\n' "$init_pw" | bash -c "$auth_cmd" >/dev/null || { init_pw=""; error "Failed to initialize WebPanel admin credentials"; return 1; }
        fi
        _LAST_WEBPANEL_INIT_PASS="$init_pw"
        init_pw=""
    fi

    _setup_webpanel_service || { error "Failed to start Web Management Panel service"; return 1; }
    _sync_caddy_if_active "$PANEL_PORT" "$PANEL_PATH" || warn "Failed to sync Caddy route for Web Management Panel"

    local port_sfx=""
    [[ "$PROXY_PORT" != "443" ]] && port_sfx=":${PROXY_PORT}"
    local wp_url="https://${PROXY_DOMAIN}${port_sfx}${WEBPANEL_PATH}"

    if [[ "$mode" != "auto" ]]; then
        success "Standalone Web Management Panel is active!"
        echo -e "  URL      : ${BOLD}${wp_url}${NC}"
        echo -e "  Username : ${BOLD}${WEBPANEL_USER}${NC}"
        if [[ -n "$_LAST_WEBPANEL_INIT_PASS" ]]; then
            echo -e "  Password : ${BOLD}${YELLOW}${_LAST_WEBPANEL_INIT_PASS}${NC}  (save this now!)"
            _LAST_WEBPANEL_INIT_PASS=""
        fi
    fi
    return 0
}

disable_webpanel() {
    load_webpanel_conf
    if run_q "command -v systemctl && systemctl list-unit-files 2>/dev/null | grep -q 3xui-deploy-web"; then
        run "systemctl disable --now 3xui-deploy-web >/dev/null 2>&1 || true"
    fi
    local pid_file="$INSTALL_DIR/webpanel/server.pid"
    run_q "if [ -f $(quote_sh "$pid_file") ]; then kill \$(cat $(quote_sh "$pid_file")) 2>/dev/null || true; rm -f $(quote_sh "$pid_file"); fi" || true

    WEBPANEL_ENABLED=false
    if run_q "test -d $(quote_sh "$INSTALL_DIR/webpanel")"; then
        save_webpanel_conf || true
    fi
    load_proxy_conf
    if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
        get_panel_info >/dev/null 2>&1 || true
        _sync_caddy_if_active "$PANEL_PORT" "$PANEL_PATH" || true
    fi
    success "Web Management Panel disabled"
}

status_webpanel() {
    load_proxy_conf
    load_webpanel_conf
    echo ""
    local port_sfx=""
    [[ "$PROXY_PORT" != "443" ]] && port_sfx=":${PROXY_PORT}"
    echo -e "  Enabled    : $($WEBPANEL_ENABLED && echo "${GREEN}Yes${NC}" || echo "${DIM}No${NC}")"
    echo -e "  Service    : $(is_webpanel_running && echo "${GREEN}Running${NC}" || echo "${RED}Stopped${NC}")"
    echo -e "  Bind       : ${WEBPANEL_BIND:-127.0.0.1}:${WEBPANEL_PORT}"
    echo -e "  Path       : ${WEBPANEL_PATH}"
    echo -e "  Domain     : ${WEBPANEL_DOMAIN:-${PROXY_DOMAIN:-(none)}}"
    local wp_ver
    wp_ver=$(_deploy_read_installed_webpanel_version || true)
    [[ -n "$wp_ver" ]] && echo -e "  Version    : v${wp_ver}"
    if $WEBPANEL_ENABLED && [[ -n "${PROXY_DOMAIN}" ]]; then
        echo -e "  URL        : ${BOLD}https://${PROXY_DOMAIN}${port_sfx}${WEBPANEL_PATH}${NC}"
    fi
    echo ""
}

reset_webpanel_password() {
    require_deployed || return 1
    load_webpanel_conf
    run_q "test -f $(quote_sh "$INSTALL_DIR/webpanel/auth.py")" || { error "WebPanel is not installed; run enable first."; return 1; }

    local new_user new_pw new_pw2 auto_pw=false
    read -rp "  WebPanel username [${WEBPANEL_USER}]: " new_user
    new_user="${new_user:-$WEBPANEL_USER}"
    [[ "$new_user" =~ ^[a-zA-Z0-9._-]{1,64}$ ]] || { error "Invalid username"; return 1; }

    read -rs -p "  New WebPanel password [Enter to auto-generate 20-char]: " new_pw
    echo ""
    if [[ -z "$new_pw" ]]; then
        new_pw=$(generate_random_string 20)
        auto_pw=true
    else
        validate_strong_password "$new_pw" || { error "Password does not meet security requirements"; return 1; }
        read -rs -p "  Confirm password: " new_pw2
        echo ""
        [[ "$new_pw" == "$new_pw2" ]] || { new_pw=""; new_pw2=""; error "Passwords do not match"; return 1; }
        new_pw2=""
    fi

    local auth_cmd="PYTHONPATH=$(quote_sh "$INSTALL_DIR") python3 -m webpanel.auth set-password $(quote_sh "$INSTALL_DIR/webpanel/auth.json") $(quote_sh "$new_user")"
    if $REMOTE; then
        printf '%s\n' "$new_pw" | ssh_cmd "$auth_cmd" || { new_pw=""; error "Failed to update WebPanel credentials"; return 1; }
    else
        printf '%s\n' "$new_pw" | bash -c "$auth_cmd" || { new_pw=""; error "Failed to update WebPanel credentials"; return 1; }
    fi

    WEBPANEL_USER="$new_user"
    save_webpanel_conf || true
    success "WebPanel credentials updated for '${new_user}'"
    $auto_pw && echo -e "  Generated password: ${BOLD}${YELLOW}${new_pw}${NC}  (save this now!)"
    new_pw=""
}

webpanel_update_settings() {
    require_deployed || return 1
    load_webpanel_conf
    local kv k v
    for kv in "$@"; do
        [[ "$kv" == *=* ]] || continue
        k="${kv%%=*}"
        v="${kv#*=}"
        case "$k" in
            idle)
                if ! [[ "$v" =~ ^[0-9]+$ ]] || (( 10#$v < 5 || 10#$v > 1440 )); then
                    error "Session idle timeout must be 5..1440 minutes"
                    return 1
                fi
                WEBPANEL_SESSION_IDLE="$(( 10#$v ))"
                ;;
            *)
                error "Unknown webpanel setting: $k"
                return 1
                ;;
        esac
    done
    save_webpanel_conf || return 1
    success "WebPanel settings updated (idle=${WEBPANEL_SESSION_IDLE}m)"
}

manage_webpanel() {
    require_deployed || return 1
    while true; do
        load_proxy_conf
        load_webpanel_conf
        local wp_state="${DIM}disabled${NC}"
        if $WEBPANEL_ENABLED; then
            is_webpanel_running && wp_state="${GREEN}active${NC} (${WEBPANEL_PATH})" || wp_state="${YELLOW}enabled, stopped${NC}"
        fi
        local header_text="  Status : ${wp_state}\n  Domain : ${WEBPANEL_DOMAIN:-${PROXY_DOMAIN:-(none)}}\n  Bind   : ${WEBPANEL_BIND}:${WEBPANEL_PORT}"
        local opts=(
            "Enable / Restart Web Management Panel"
            "Show Web Management Panel status & URL"
            "Reset Web Management Panel password"
            "View WebPanel audit log"
            "Disable Web Management Panel"
            "Back"
        )
        tui_select "Standalone Web Management Panel" "$header_text" "${opts[@]}"
        local sub=$?
        clear_screen
        case "$sub" in
            0) enable_webpanel ;;
            1) status_webpanel ;;
            2) reset_webpanel_password ;;
            3) run "tail -n 100 $(quote_sh "$INSTALL_DIR/logs/webpanel-audit.log") 2>/dev/null || echo '  (no audit entries yet)'" || true ;;
            4) disable_webpanel ;;
            5|255) _SKIP_PAUSE=true; return ;;
        esac
        echo ""
        read -rp "  Press Enter..."
    done
}

# ─── Multi-Protocol Inbounds Discovery, Proxy & Firewall Sync ───────────────
_is_loopback_addr() {
    local addr="${1:-}"
    [[ "$addr" == "127.0.0.1" || "$addr" == "::1" || "$addr" == "[::1]" || "$addr" == "localhost" ]]
}

list_inbounds_report() {
    echo ""
    echo -e "${BOLD}── Xray Inbounds & Protocol Routing ──${NC}"
    echo ""
    if ! is_running; then
        warn "Container is stopped; reading database directly if available."
    fi

    get_panel_info || true
    local rows ss_out proxy_active=false
    rows=$(get_xui_inbounds || true)
    if [[ -z "$rows" ]]; then
        info "No inbounds configured in 3x-ui database."
        echo ""
        return 0
    fi

    ss_out=$(run_out "ss -tulnp 2>/dev/null" || true)
    if $PROXY_ENABLED && is_caddy_running; then
        proxy_active=true
    fi

    printf "  %-3s %-4s %-12s %-15s %-6s %-13s %-5s %-11s %-22s %s\n" \
        "ID" "ON" "Proto" "Listen" "Port" "Net/Sec" "FW" "Live" "Route" "Remark"
    printf "  %-3s %-4s %-12s %-15s %-6s %-13s %-5s %-11s %-22s %s\n" \
        "---" "----" "------------" "---------------" "------" "-------------" "-----" "-----------" "----------------------" "------"

    local total=0 enabled=0 loopback_cnt=0
    local id en proto listen port remark net sec path fw_proto
    local state_str listen_disp net_sec live_str route_str
    while IFS='|' read -r id en proto listen port remark net sec path fw_proto; do
        [[ -z "$id" ]] && continue
        total=$((total + 1))
        listen_disp="${listen:-0.0.0.0}"
        net_sec="${net}/${sec}"

        if _is_inbound_enabled "$en"; then
            enabled=$((enabled + 1))
            state_str="${GREEN}ON${NC}  "
            if [[ -z "$ss_out" ]]; then
                live_str="unknown"
            elif [[ "$fw_proto" == "both" ]]; then
                local has_t=false has_u=false
                echo "$ss_out" | grep -qE "^tcp[[:space:]].*:${port}([^0-9]|$)" && has_t=true
                echo "$ss_out" | grep -qE "^udp[[:space:]].*:${port}([^0-9]|$)" && has_u=true
                if $has_t && $has_u; then
                    live_str="${GREEN}LISTEN(T+U)${NC}"
                elif $has_t; then
                    live_str="${YELLOW}TCP-ONLY${NC}   "
                elif $has_u; then
                    live_str="${YELLOW}UDP-ONLY${NC}   "
                else
                    live_str="${RED}DOWN${NC}       "
                fi
            elif echo "$ss_out" | grep -qE "^${fw_proto}[[:space:]].*:${port}([^0-9]|$)"; then
                live_str="${GREEN}LISTEN${NC}     "
            else
                live_str="${RED}DOWN${NC}       "
            fi
        else
            state_str="${DIM}OFF${NC} "
            live_str="${DIM}disabled${NC}   "
        fi

        if _is_loopback_addr "$listen_disp"; then
            loopback_cnt=$((loopback_cnt + 1))
            case "$net" in
                ws|httpupgrade|xhttp|splithttp|grpc)
                    if $proxy_active; then
                        route_str="caddy:${path:-(no-path)}"
                    else
                        route_str="loopback:${path:-(no-path)}"
                    fi
                    ;;
                *)
                    route_str="loopback(${net})"
                    ;;
            esac
        else
            route_str="direct${path:+:${path}}"
        fi

        printf "  %-3s " "$id"
        echo -ne "$state_str"
        printf " %-12s %-15s %-6s %-13s %-5s " \
            "${proto:0:12}" "${listen_disp:0:15}" "$port" "${net_sec:0:13}" "$fw_proto"
        echo -ne "$live_str"
        printf " %-22s %s\n" "${route_str:0:22}" "${remark:-}"
    done <<< "$rows"

    echo ""
    info "Summary: ${enabled}/${total} enabled (${loopback_cnt} loopback)."
    echo ""
}

verify_inbounds_listeners() {
    echo ""
    echo -e "${BOLD}── Inbound Listener & Conflict Verification ──${NC}"
    echo ""

    get_panel_info || true
    local rows ss_out proxy_active=false
    rows=$(get_xui_inbounds || true)
    if [[ -z "$rows" ]]; then
        info "No inbounds configured in 3x-ui database."
        return 0
    fi

    ss_out=$(run_out "ss -tulnp 2>/dev/null" || true)
    if $PROXY_ENABLED && is_caddy_running; then
        proxy_active=true
    fi

    local issues=0 warnings=0 checked=0
    local seen_tcp=" " seen_udp=" " seen_paths=" "
    local id en proto listen port remark net sec path fw_proto listen_disp

    while IFS='|' read -r id en proto listen port remark net sec path fw_proto; do
        [[ -z "$id" ]] && continue
        _is_inbound_enabled "$en" || continue
        checked=$((checked + 1))
        listen_disp="${listen:-0.0.0.0}"

        # Duplicate enabled port+protocol check
        if [[ "$fw_proto" == "tcp" || "$fw_proto" == "both" ]]; then
            if [[ "$seen_tcp" == *" ${port} "* ]]; then
                error "Inbound #${id} (${remark:-$proto}): duplicate TCP listener on port ${port}"
                issues=$((issues + 1))
            fi
            seen_tcp="${seen_tcp}${port} "
        fi
        if [[ "$fw_proto" == "udp" || "$fw_proto" == "both" ]]; then
            if [[ "$seen_udp" == *" ${port} "* ]]; then
                error "Inbound #${id} (${remark:-$proto}): duplicate UDP listener on port ${port}"
                issues=$((issues + 1))
            fi
            seen_udp="${seen_udp}${port} "
        fi

        # Conflict check against Panel / Subscription / Caddy ports for non-loopback inbounds
        if ! _is_loopback_addr "$listen_disp"; then
            if $proxy_active; then
                if [[ "$port" == "$PROXY_PORT" ]]; then
                    error "Inbound #${id} (${remark:-$proto}): port ${port}/${fw_proto} conflicts with Caddy HTTPS/HTTP3 port ${PROXY_PORT}"
                    issues=$((issues + 1))
                elif [[ "$port" == "80" && "$fw_proto" != "udp" ]]; then
                    error "Inbound #${id} (${remark:-$proto}): TCP port 80 conflicts with Caddy ACME HTTP-01 listener"
                    issues=$((issues + 1))
                fi
            else
                if [[ -n "$PANEL_PORT" && "$port" == "$PANEL_PORT" && "$fw_proto" != "udp" ]]; then
                    error "Inbound #${id} (${remark:-$proto}): TCP port ${port} conflicts with 3X-UI Panel port"
                    issues=$((issues + 1))
                fi
                if [[ "$SUB_ENABLE_DB" == "true" && -n "$SUB_PORT_DB" && "$port" == "$SUB_PORT_DB" && "$fw_proto" != "udp" ]]; then
                    error "Inbound #${id} (${remark:-$proto}): TCP port ${port} conflicts with 3X-UI Subscription port"
                    issues=$((issues + 1))
                fi
            fi
        else
            case "$net" in
                ws|httpupgrade|xhttp|splithttp|grpc)
                    if [[ -z "$path" || "$path" == "/" ]]; then
                        warn "Inbound #${id} (${remark:-$proto}): loopback ${net} inbound has empty/root path; Caddy cannot isolate it from decoy."
                        warnings=$((warnings + 1))
                    else
                        local norm_p="/${path#/}"
                        local p_base="${PANEL_PATH%/}"
                        [[ -n "$p_base" && ( "${norm_p%/}" == "$p_base" || "$norm_p" == "${p_base}/"* ) ]] && {
                            error "Inbound #${id}: path ${norm_p} overlaps Panel WebPath ${PANEL_PATH}"
                            issues=$((issues + 1))
                        }
                        if [[ "$seen_paths" == *" ${norm_p} "* ]]; then
                            error "Inbound #${id}: duplicate reverse-proxy path ${norm_p}"
                            issues=$((issues + 1))
                        fi
                        seen_paths="${seen_paths}${norm_p} "
                    fi
                    ;;
                *)
                    warn "Inbound #${id} (${remark:-$proto}): listens on loopback (${listen_disp}) with transport '${net}' (not Caddy HTTP-proxiable)."
                    warnings=$((warnings + 1))
                    ;;
            esac
        fi

        # Live socket verification
        if [[ -z "$ss_out" ]]; then
            warn "Inbound #${id} (${remark:-$proto}): could not read host sockets via ss."
            warnings=$((warnings + 1))
        else
            if [[ "$fw_proto" == "tcp" || "$fw_proto" == "both" ]]; then
                if ! echo "$ss_out" | grep -qE "^tcp[[:space:]].*:${port}([^0-9]|$)"; then
                    error "Inbound #${id} (${remark:-$proto}): missing live TCP socket on port ${port}"
                    issues=$((issues + 1))
                fi
            fi
            if [[ "$fw_proto" == "udp" || "$fw_proto" == "both" ]]; then
                if ! echo "$ss_out" | grep -qE "^udp[[:space:]].*:${port}([^0-9]|$)"; then
                    error "Inbound #${id} (${remark:-$proto}): missing live UDP socket on port ${port}"
                    issues=$((issues + 1))
                fi
            fi
        fi
    done <<< "$rows"

    if (( checked == 0 )); then
        info "All configured inbounds are currently disabled."
        return 0
    fi

    echo ""
    if (( issues == 0 && warnings == 0 )); then
        success "Verified ${checked} enabled inbound(s): all listeners active and conflict-free."
    elif (( issues == 0 )); then
        warn "Verified ${checked} enabled inbound(s): 0 errors, ${warnings} warning(s)."
    else
        error "Inbound verification found ${issues} error(s) and ${warnings} warning(s)."
        return 1
    fi
    return 0
}

sync_inbounds_caddy() {
    get_panel_info || true
    if ! $PROXY_ENABLED && ! is_caddy_running; then
        warn "Caddy reverse proxy is not enabled/running. Run './manage.sh proxy setup' first."
        return 1
    fi

    local blocks
    blocks=$(_collect_caddy_inbound_blocks "${PANEL_PATH:-/}" "${SUB_PATH:-/sub/}" "${SUB_JSON_PATH:-/json/}" || true)
    local route_count=0
    if [[ -n "$blocks" ]]; then
        route_count=$(echo "$blocks" | grep -c "^[[:space:]]*@inbound_" || true)
    fi

    info "Detected ${route_count} Caddy-routable loopback inbound(s) (ws/httpupgrade/xhttp/grpc)."
    _sync_caddy_if_active "$PANEL_PORT" "$PANEL_PATH" || return 1
    verify_panel_loaded 3 || true
}

sync_inbound_firewall() {
    local fw="${1:-}"
    if [[ -z "$fw" ]]; then
        if run_q "command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'"; then
            fw="ufw"
        elif run_q "command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null"; then
            fw="firewalld"
        else
            fw="none"
        fi
    fi

    if [[ "$fw" == "none" ]]; then
        warn "Neither ufw nor firewalld is currently active."
        return 0
    fi

    get_panel_info || true
    local rows xray_sockets
    rows=$(get_xui_inbounds || true)
    xray_sockets=$(run_out "ss -tulnp 2>/dev/null | awk '/xray/ {print \$1\":\"\$5}'" || true)

    local rules_list=()
    _add_fw_rule() {
        local candidate="${1}:${2}"
        local existing
        for existing in "${rules_list[@]:-}"; do
            [[ "$existing" == "$candidate" ]] && return 0
        done
        rules_list+=("$candidate")
    }

    local summary_inbounds="" skipped_loopback=0
    _add_fw_rule "$SSH_PORT" "tcp"

    if $PROXY_ENABLED && is_caddy_running; then
        _add_fw_rule "80" "tcp"
        _add_fw_rule "$PROXY_PORT" "tcp"
        _add_fw_rule "$PROXY_PORT" "udp"
    else
        validate_port "${PANEL_PORT:-}" && _add_fw_rule "$PANEL_PORT" "tcp"
        if [[ "$SUB_ENABLE_DB" == "true" ]] && ! _is_loopback_addr "${SUB_LISTEN_DB:-}" && validate_port "${SUB_PORT_DB:-}"; then
            _add_fw_rule "$SUB_PORT_DB" "tcp"
        fi
    fi

    local id en proto listen port remark net sec path fw_proto
    while IFS='|' read -r id en proto listen port remark net sec path fw_proto; do
        [[ -z "$id" ]] && continue
        _is_inbound_enabled "$en" || continue
        validate_port "$port" || continue
        if _is_loopback_addr "${listen:-}"; then
            skipped_loopback=$((skipped_loopback + 1))
            continue
        fi
        case "$fw_proto" in
            tcp)  _add_fw_rule "$port" "tcp";  summary_inbounds="${summary_inbounds} ${port}/tcp(${proto})" ;;
            udp)  _add_fw_rule "$port" "udp";  summary_inbounds="${summary_inbounds} ${port}/udp(${proto})" ;;
            both)
                _add_fw_rule "$port" "tcp"
                _add_fw_rule "$port" "udp"
                summary_inbounds="${summary_inbounds} ${port}/tcp+udp(${proto})"
                ;;
        esac
    done <<< "$rows"

    local entry s_proto s_addr s_host s_port extra_xray=""
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        s_proto="${entry%%:*}"
        s_addr="${entry#*:}"
        s_port="${s_addr##*:}"
        s_host="${s_addr%:*}"
        if _is_loopback_addr "$s_host"; then
            continue
        fi
        [[ "$s_proto" == udp* ]] && s_proto="udp" || s_proto="tcp"
        if validate_port "$s_port"; then
            local before_cnt="${#rules_list[@]}"
            _add_fw_rule "$s_port" "$s_proto"
            if (( ${#rules_list[@]} > before_cnt )); then
                extra_xray="${extra_xray} ${s_port}/${s_proto}"
            fi
        fi
    done <<< "$xray_sockets"

    echo ""
    echo "  Will allow via ${fw}:"
    echo "    * SSH      : ${SSH_PORT}/tcp"
    if $PROXY_ENABLED && is_caddy_running; then
        echo "    * ACME     : 80/tcp (Caddy)"
        echo "    * Proxy    : ${PROXY_PORT}/tcp + ${PROXY_PORT}/udp (Caddy HTTPS/HTTP3)"
    else
        echo "    * Panel    : ${PANEL_PORT}/tcp"
        if [[ "$SUB_ENABLE_DB" == "true" ]] && ! _is_loopback_addr "${SUB_LISTEN_DB:-}" && validate_port "${SUB_PORT_DB:-}"; then
            echo "    * Subs     : ${SUB_PORT_DB}/tcp"
        fi
    fi
    [[ -n "$summary_inbounds" ]] && echo "    * Inbounds :${summary_inbounds}"
    [[ -n "$extra_xray" ]] && echo "    * Xray live:${extra_xray}"
    (( skipped_loopback > 0 )) && echo "    * Skipped  : ${skipped_loopback} loopback inbound(s) served via Caddy"

    if confirm "Apply these firewall rules?"; then
        local r r_port r_proto
        for r in "${rules_list[@]}"; do
            r_port="${r%%:*}"
            r_proto="${r#*:}"
            _fw_open_port "$fw" "$r_port" "$r_proto" || true
        done
        [[ "$fw" == "firewalld" ]] && run "firewall-cmd --reload >/dev/null" || true
        success "Firewall rules applied"
    fi
}

manage_inbounds() {
    while true; do
        local opts=(
            "List all inbounds & live socket status"
            "Verify inbound listeners, conflicts & proxy paths"
            "Sync loopback inbounds (WS/gRPC/XHTTP/HTTPUpgrade) to Caddy"
            "Sync firewall rules for active public inbounds (TCP/UDP)"
            "Back"
        )
        tui_select "Inbounds & Protocol Routing" "  Inspect SQLite/Postgres inbounds, verify sockets & sync Caddy/firewall" "${opts[@]}"
        local sub=$?
        clear_screen
        case "$sub" in
            0) list_inbounds_report ;;
            1) verify_inbounds_listeners || true ;;
            2) sync_inbounds_caddy || true ;;
            3) sync_inbound_firewall ;;
            4|255) _SKIP_PAUSE=true; return ;;
        esac
        echo ""
        read -rp "  Press Enter..."
    done
}

# ─── Xray, GeoIP/GeoSite, Diagnostics & Network Tuning ──────────────────────
xray_status() {
    require_deployed || return 1
    require_running  || return 1
    echo -e "\n${BOLD}Xray Core Status:${NC}"

    info "Internal panel settings (/app/x-ui setting -show)..."
    if $INTERACTIVE; then
        run_it "$(_xui_setting_cmd -show=true) 2>/dev/null || echo 'x-ui CLI unavailable'"
    else
        run "$(_xui_setting_cmd -show=true) 2>/dev/null || echo 'x-ui CLI unavailable'"
    fi

    echo -e "\n${DIM}Xray process:${NC}"
    local ps_out
    ps_out=$(run_out "docker exec 3xui_app sh -c 'ps aux 2>/dev/null | grep -i \"[x]ray\" || ps 2>/dev/null | grep -i \"[x]ray\" || pidof xray-linux-amd64'" || true)

    if [[ -z "$ps_out" ]]; then
        error "Xray core process does NOT seem to be running inside the container."
        warn "Check 'Logs' to see if Xray failed to start (e.g., an invalid inbound config)."
    else
        success "Xray core process is RUNNING."
        printf '%s\n' "$ps_out" | sed 's/^/  /'
    fi

    echo -e "\n${DIM}Listening Xray ports:${NC}"
    run "docker exec 3xui_app sh -c 'ss -tulnp 2>/dev/null | grep -E \"xray|v2ray\" || netstat -tulnp 2>/dev/null | grep -E \"xray|v2ray\" || echo \"  (none detected or ss/netstat unavailable)\"'" || true

    echo -e "\n${DIM}Fail2ban status:${NC}"
    run "docker exec 3xui_app fail2ban-client status 2>/dev/null || echo '  (Fail2ban not active)'" || true
    echo ""
}

ensure_bash_in_container() {
    run_q "docker exec 3xui_app test -x /bin/bash" && return 0
    info "Installing bash in container..."
    run "docker exec 3xui_app sh -c 'apk update >/dev/null 2>&1 && apk add --no-cache bash'" \
        || { warn "Could not install bash"; return 1; }
}

container_control() {
    require_running || return 1
    ensure_bash_in_container || { error "bash not available in container"; return 1; }

    info "Opening bash shell in container (type 'exit' to return)..."
    run_it "docker exec -it 3xui_app /bin/bash"
    _SKIP_PAUSE=true
}

health_check() {
    echo ""
    echo -e "  ${BOLD}${MAGENTA}System & Panel Health Diagnostics${NC}"
    echo -e "  ${DIM}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${NC}\n"

    local diag_script
    diag_script=$(cat <<EOF
os_name=\$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || uname -s)
kernel=\$(uname -r)
arch=\$(uname -m)
cpus=\$(nproc 2>/dev/null || echo '?')
uptime_s=\$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo '?')
load_avg=\$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?')
mem_info=\$(free -h 2>/dev/null | awk '/^Mem:/ {printf "%s / %s (avail %s)", \$3, \$2, \$7}' || echo '?')
swap_info=\$(free -h 2>/dev/null | awk '/^Swap:/ {printf "%s / %s", \$3, \$2}' || echo '?')
disk_root=\$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s / %s (%s used)", \$3, \$2, \$5}' || echo '?')
cc=\$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')
qdisc=\$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')
pub4=\$(curl -4fsS --proto '=https' --tlsv1.2 --max-time 2 https://api.ipify.org 2>/dev/null || echo 'unavailable')
pub6=\$(curl -6fsS --proto '=https' --tlsv1.2 --max-time 2 https://api64.ipify.org 2>/dev/null || echo 'unavailable')
docker_v=\$(docker --version 2>/dev/null | sed 's/Docker version //' || echo 'not installed')

printf "  OS / Kernel   : %s (%s %s)\n" "\$os_name" "\$kernel" "\$arch"
printf "  Uptime / Load : %s  |  load: %s (%s cores)\n" "\$uptime_s" "\$load_avg" "\$cpus"
printf "  Memory / Swap : %s  |  Swap: %s\n" "\$mem_info" "\$swap_info"
printf "  Disk (/)      : %s\n" "\$disk_root"
printf "  Network TCP   : congestion=%s  qdisc=%s\n" "\$cc" "\$qdisc"
printf "  Public IP     : v4=%s  v6=%s\n" "\$pub4" "\$pub6"
printf "  Docker        : %s\n" "\$docker_v"

if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^3xui_'; then
    echo ""
    echo "  Container Resource Usage:"
    docker stats --no-stream --format '    {{.Name}}\tCPU: {{.CPUPerc}}\tMEM: {{.MemUsage}}\tNET: {{.NetIO}}' \$(docker ps --format '{{.Names}}' | grep '^3xui_') 2>/dev/null || true
fi

if [ -d $(quote_sh "$INSTALL_DIR/cert") ]; then
    echo ""
    echo "  TLS Certificates:"
    found_cert=0
    for cf in $(quote_sh "$INSTALL_DIR/cert")/*/fullchain.pem; do
        [ -f "\$cf" ] || continue
        found_cert=1
        dom=\$(basename "\$(dirname "\$cf")")
        exp=\$(openssl x509 -enddate -noout -in "\$cf" 2>/dev/null | cut -d= -f2 || echo 'unknown')
        warn_exp=""
        if ! openssl x509 -checkend 1209600 -noout -in "\$cf" 2>/dev/null; then
            warn_exp=" [EXPIRES WITHIN 14 DAYS OR EXPIRED!]"
        fi
        printf "    * %s : %s%s\n" "\$dom" "\$exp" "\$warn_exp"
    done
    [ "\$found_cert" -eq 0 ] && echo "    (none)"
fi
EOF
)
    run "$diag_script" || true

    if is_running; then
        get_panel_info || true
        echo ""
        echo -e "  Panel URL     : ${BOLD}$(format_panel_url "$(get_target_ip)")${NC}"
        if verify_panel_loaded 2 >/dev/null 2>&1; then
            echo -e "  Web UI Check  : ${GREEN}Loaded (${PANEL_LOAD_STATUS})${NC}"
        else
            echo -e "  Web UI Check  : ${RED}Not verified (${PANEL_LOAD_STATUS:-failed})${NC}"
        fi
        if $PROXY_ENABLED && is_caddy_running; then
            echo -e "  Reverse Proxy : ${GREEN}Caddy Active${NC} (backend ${PANEL_LISTEN:-127.0.0.1}:${PANEL_PORT})"
            [[ -n "$PROXY_SUB_URL" ]] && echo -e "  Sub URL       : ${BOLD}${PROXY_SUB_URL}${NC}"
        fi
        if [[ "$SUB_ENABLE_DB" == "true" ]]; then
            if verify_subscription_endpoint 2 >/dev/null 2>&1; then
                echo -e "  Sub Check     : ${GREEN}Verified (${SUB_VERIFY_STATUS})${NC}"
            else
                echo -e "  Sub Check     : ${YELLOW}Not verified (${SUB_VERIFY_STATUS:-failed})${NC}"
            fi
        fi
        local ib_rows ib_total=0 ib_enabled=0 ib_id ib_en ib_rest
        ib_rows=$(get_xui_inbounds || true)
        while IFS='|' read -r ib_id ib_en ib_rest; do
            [[ -z "$ib_id" ]] && continue
            ib_total=$((ib_total + 1))
            _is_inbound_enabled "$ib_en" && ib_enabled=$((ib_enabled + 1))
        done <<< "$ib_rows"
        echo -e "  Inbounds      : ${ib_enabled}/${ib_total} enabled"
        echo -e "  Xray Process  : $(run_q "docker exec 3xui_app sh -c 'pgrep -f xray >/dev/null 2>&1 || pidof xray-linux-amd64 >/dev/null 2>&1'" && echo "${GREEN}running${NC}" || echo "${RED}not detected${NC}")"
        local f2b
        f2b=$(run_out "docker exec 3xui_app fail2ban-client status 3x-ui 2>/dev/null | grep 'Currently banned' | tr -d '\t'" || true)
        [[ -n "$f2b" ]] && echo -e "  Fail2ban      : ${f2b}"
    fi
    echo ""
}

enable_bbr_tuning() {
    echo ""
    local cur_cc cur_qdisc
    cur_cc=$(run_out "sysctl -n net.ipv4.tcp_congestion_control" || echo "unknown")
    cur_qdisc=$(run_out "sysctl -n net.core.default_qdisc" || echo "unknown")
    echo -e "  Current congestion control: ${BOLD}${cur_cc}${NC}"
    echo -e "  Current default qdisc     : ${BOLD}${cur_qdisc}${NC}"
    echo ""
    echo "  This will write /etc/sysctl.d/99-3xui-optimizer.conf with:"
    echo "    * TCP BBR + FQ qdisc"
    echo "    * 16MB TCP/UDP socket buffers (helps QUIC / Hysteria / Reality throughput)"
    echo "    * TCP Fast Open (3) & MTU probing"

    if $INTERACTIVE; then
        confirm "Apply BBR & network optimizations?" || return 0
    fi

    local sysctl_conf
    sysctl_conf=$(cat <<'CONF'
# Managed by 3X-UI Manager - BBR & proxy network tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 4096
CONF
)
    local sysctl_file="/etc/sysctl.d/99-3xui-optimizer.conf"
    run "modprobe tcp_bbr 2>/dev/null || true" || true
    if $REMOTE; then
        printf '%s\n' "$sysctl_conf" | ssh_cmd "mkdir -p /etc/sysctl.d && cat > $sysctl_file && chmod 644 $sysctl_file" || return 1
    else
        mkdir -p /etc/sysctl.d
        printf '%s\n' "$sysctl_conf" > "$sysctl_file"
        chmod 644 "$sysctl_file"
    fi

    run "sysctl --system >/dev/null 2>&1 || sysctl -p $sysctl_file" || { error "sysctl apply failed"; return 1; }
    local new_cc new_qdisc
    new_cc=$(run_out "sysctl -n net.ipv4.tcp_congestion_control" || echo "?")
    new_qdisc=$(run_out "sysctl -n net.core.default_qdisc" || echo "?")
    success "Applied! Active: congestion=${new_cc}, qdisc=${new_qdisc}"
}

_fw_open_port() {
    local fw="$1" port="$2" proto="${3:-tcp}"
    validate_port "$port" || return 1
    case "$fw" in
        ufw)
            run "ufw allow ${port}/${proto} >/dev/null" ;;
        firewalld)
            run "firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null" ;;
    esac
}

_fw_close_port() {
    local fw="$1" port="$2" proto="${3:-tcp}"
    validate_port "$port" || return 1
    case "$fw" in
        ufw)
            run "ufw --force delete allow ${port}/${proto} >/dev/null" ;;
        firewalld)
            run "firewall-cmd --permanent --remove-port=${port}/${proto} >/dev/null" ;;
    esac
}

_fw_detect_backend() {
    if run_q "command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'"; then
        printf 'ufw'
    elif run_q "command -v firewall-cmd >/dev/null 2>&1 && (firewall-cmd --state 2>/dev/null | grep -q 'running' || systemctl is-active --quiet firewalld 2>/dev/null)"; then
        printf 'firewalld'
    else
        printf 'none'
    fi
}

firewall_cli_dispatch() {
    local action="${1:-status}"
    shift || true
    local fw
    fw=$(_fw_detect_backend)

    case "$action" in
        status)
            printf 'FIREWALL_BACKEND=%s\n' "$fw"
            case "$fw" in
                ufw)       run "ufw status verbose" ;;
                firewalld) run "firewall-cmd --list-all" ;;
                *)
                    info "No active ufw or firewalld detected. Active sockets:"
                    run "ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null || true"
                    ;;
            esac
            ;;
        sync)
            sync_inbound_firewall "$fw"
            ;;
        open)
            local p="${1:-}" proto="${2:-tcp}"
            validate_port "$p" || { error "Invalid port: $p"; return 1; }
            [[ "$fw" == "none" ]] && { error "No active ufw or firewalld firewall detected"; return 1; }
            case "$proto" in
                tcp|udp) _fw_open_port "$fw" "$p" "$proto" || return 1 ;;
                both)    { _fw_open_port "$fw" "$p" "tcp" && _fw_open_port "$fw" "$p" "udp"; } || return 1 ;;
                *)       error "Invalid protocol '$proto' (use: tcp|udp|both)"; return 1 ;;
            esac
            [[ "$fw" == "firewalld" ]] && run "firewall-cmd --reload >/dev/null" || true
            success "Opened port $p ($proto) via $fw"
            ;;
        close)
            local p="${1:-}" proto="${2:-tcp}"
            validate_port "$p" || { error "Invalid port: $p"; return 1; }
            [[ "$fw" == "none" ]] && { error "No active ufw or firewalld firewall detected"; return 1; }
            local ssh_ports=" 22 ${SSH_PORT:-22} "
            local sshd_ports
            sshd_ports=$(run_out "awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print \$2}' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null" || true)
            if [[ -n "$sshd_ports" ]]; then
                local sp
                while IFS= read -r sp; do
                    validate_port "$sp" && ssh_ports+="${sp} "
                done <<< "$sshd_ports"
            fi
            if [[ "$ssh_ports" == *" ${p} "* ]] && [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
                error "Refusing to close active SSH port ${p}/tcp (prevents administrative lockout)"
                return 1
            fi
            load_proxy_conf
            if $PROXY_ENABLED && [[ "$p" == "$PROXY_PORT" ]]; then
                error "Refusing to close active Caddy reverse-proxy port ${PROXY_PORT} while WebPanel/Proxy is active"
                return 1
            fi
            case "$proto" in
                tcp|udp) _fw_close_port "$fw" "$p" "$proto" || return 1 ;;
                both)    { _fw_close_port "$fw" "$p" "tcp" && _fw_close_port "$fw" "$p" "udp"; } || return 1 ;;
                *)       error "Invalid protocol '$proto' (use: tcp|udp|both)"; return 1 ;;
            esac
            [[ "$fw" == "firewalld" ]] && run "firewall-cmd --reload >/dev/null" || true
            success "Closed port $p ($proto) via $fw"
            ;;
        *)
            error "Unknown firewall action: $action (use: status|sync|open|close)"
            return 1
            ;;
    esac
}

dns_check_cli() {
    local domain="${1:-}"
    validate_domain "$domain" || { error "Invalid domain: $domain"; return 1; }
    local resolved=""
    resolved=$(run_out "
        if command -v getent >/dev/null 2>&1; then
            getent ahosts $(quote_sh "$domain") 2>/dev/null | awk '{print \$1}' | sort -u
        elif command -v dig >/dev/null 2>&1; then
            { dig +short A $(quote_sh "$domain"); dig +short AAAA $(quote_sh "$domain"); } 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' | sort -u
        elif command -v nslookup >/dev/null 2>&1; then
            nslookup $(quote_sh "$domain") 2>/dev/null | awk '/^Address:[[:space:]]*/ {print \$2}' | grep -E '^[0-9a-fA-F:.]+$' | sort -u
        fi
    " || true)
    local pub4="" pub6=""
    pub4=$(run_out "curl -4fsS --proto '=https' --tlsv1.2 --max-time 2 https://api.ipify.org" || true)
    pub6=$(run_out "curl -6fsS --proto '=https' --tlsv1.2 --max-time 2 https://api64.ipify.org" || true)
    local rec_csv="" matched="false" r
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        rec_csv+="${rec_csv:+,}${r}"
        if [[ -n "$pub4" && "$r" == "$pub4" ]] || [[ -n "$pub6" && "$r" == "$pub6" ]]; then
            matched="true"
        fi
    done <<< "$resolved"
    printf 'DNS_DOMAIN=%s\nDNS_RECORDS=%s\nSERVER_IPV4=%s\nSERVER_IPV6=%s\nDNS_MATCH=%s\n' \
        "$domain" "$rec_csv" "$pub4" "$pub6" "$matched"
    _check_domain_dns "$domain"
}

dns_status_cli() {
    local ns=""
    ns=$(run_out "awk '/^nameserver[[:space:]]+/{printf \"%s%s\", (c++?\",\":\"\"), \$2}' /etc/resolv.conf 2>/dev/null" || true)
    local hn=""
    hn=$(run_out "hostname -f 2>/dev/null || hostname 2>/dev/null" || true)
    local ifaces=""
    ifaces=$(run_out "ip -o addr show 2>/dev/null | awk '{print \$2\" \"\$3\" \"\$4}'" || true)
    printf 'HOSTNAME=%s\nNAMESERVERS=%s\n' "$hn" "$ns"
    if [[ -n "$ifaces" ]]; then
        printf '%s\n' "$ifaces" | sed 's/^/IFACE=/'
    fi
}

manage_firewall() {
    local fw="none"
    if run_q "command -v ufw" && run_q "ufw status | grep -qi 'Status: active'"; then
        fw="ufw"
    elif run_q "command -v firewall-cmd" && run_q "firewall-cmd --state | grep -q 'running'"; then
        fw="firewalld"
    fi

    while true; do
        local header_text="  Detected active firewall: ${BOLD}${fw}${NC}"
        local opts=(
            "Show firewall status & rules"
            "Auto-allow SSH + Panel + active Xray ports"
            "Open a custom port (TCP/UDP)"
            "Back"
        )

        tui_select "Firewall Helper" "$header_text" "${opts[@]}"
        local sub=$?
        clear_screen
        case "$sub" in
            0)
                echo ""
                case "$fw" in
                    ufw)       run "ufw status verbose" ;;
                    firewalld) run "firewall-cmd --list-all" ;;
                    *)
                        warn "No active ufw or firewalld detected. Showing listening ports:"
                        run "ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null || true"
                        ;;
                esac
                ;;
            1)
                sync_inbound_firewall "$fw"
                ;;
            2)
                if [[ "$fw" == "none" ]]; then
                    warn "Neither ufw nor firewalld is currently active."
                else
                    local p proto
                    read -rp "  Port (1-65535): " p
                    if ! validate_port "$p"; then
                        error "Invalid port"
                    else
                        read -rp "  Protocol (tcp/udp/both) [tcp]: " proto
                        proto="${proto:-tcp}"
                        local fw_ok=true
                        case "$proto" in
                            tcp|udp) _fw_open_port "$fw" "$p" "$proto" || fw_ok=false ;;
                            both)    { _fw_open_port "$fw" "$p" "tcp" && _fw_open_port "$fw" "$p" "udp"; } || fw_ok=false ;;
                            *)       error "Invalid protocol"; fw_ok=false ;;
                        esac
                        if $fw_ok; then
                            [[ "$fw" == "firewalld" ]] && run "firewall-cmd --reload >/dev/null" || true
                            success "Opened port $p ($proto)"
                        fi
                    fi
                fi
                ;;
            3|255) _SKIP_PAUSE=true; return ;;
        esac
        echo ""
        read -rp "  Press Enter..."
    done
}

manage_geo_assets() {
    require_deployed || return 1
    require_running  || return 1

    local bin_dir
    bin_dir=$(_xui_detect_bin_dir)

    local scope="${1:-}"
    if [[ -z "$scope" ]]; then
        tui_select "Update GeoIP / GeoSite Assets" "Downloads latest routing .dat files into 3xui_app:${bin_dir}/:" \
            "Standard GeoIP & GeoSite (Loyalsoldier)" \
            "Standard + Iran rules (geoip_IR / geosite_IR)" \
            "Standard + Russia rules (geoip_RU / geosite_RU)" \
            "ALL datasets (Standard + IR + RU)" \
            "Cancel"
        local sel=$?
        clear_screen
        case "$sel" in
            0) scope="std" ;;
            1) scope="ir" ;;
            2) scope="ru" ;;
            3) scope="all" ;;
            4|255) info "Cancelled"; return 0 ;;
        esac
    fi

    local pairs=(
        "geoip.dat|https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
        "geosite.dat|https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    )
    if [[ "$scope" == "ir" || "$scope" == "all" ]]; then
        pairs+=(
            "geoip_IR.dat|https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geoip.dat"
            "geosite_IR.dat|https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geosite.dat"
        )
    fi
    if [[ "$scope" == "ru" || "$scope" == "all" ]]; then
        pairs+=(
            "geoip_RU.dat|https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"
            "geosite_RU.dat|https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"
        )
    fi

    local tmp_dir
    tmp_dir=$(run_out "mktemp -d /tmp/3xui-geo.XXXXXX")
    [[ -n "$tmp_dir" ]] || { error "Failed to create temp directory"; return 1; }
    run_q "chmod 700 $(quote_sh "$tmp_dir") && mkdir -p $(quote_sh "$tmp_dir/bak")" || true

    local pair fname url ok=0 copied_files=()
    for pair in "${pairs[@]}"; do
        fname="${pair%%|*}"
        url="${pair#*|}"
        info "Downloading $fname..."
        run_q "docker cp $(quote_sh "3xui_app:${bin_dir}/${fname}") $(quote_sh "${tmp_dir}/bak/${fname}")" || true
        if run "curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 $(quote_sh "$url") -o $(quote_sh "$tmp_dir/$fname") && [ \$(wc -c < $(quote_sh "$tmp_dir/$fname")) -gt 10240 ] && docker cp $(quote_sh "$tmp_dir/$fname") $(quote_sh "3xui_app:${bin_dir}/${fname}")"; then
            ok=$(( ok + 1 ))
            copied_files+=("$fname")
        else
            warn "Failed to update $fname"
        fi
    done

    if (( ok > 0 )); then
        info "Restarting container so Xray reloads geo databases..."
        compose restart >/dev/null || docker restart 3xui_app >/dev/null || true
        sleep 2
        if is_running && run_q "docker exec 3xui_app sh -c 'pgrep -f xray >/dev/null 2>&1 || pidof xray-linux-amd64 >/dev/null 2>&1'"; then
            run_q "rm -rf $(quote_sh "$tmp_dir")" || true
            success "Updated $ok/${#pairs[@]} geo-asset file(s) in ${bin_dir}"
            return 0
        fi
        warn "Xray process did not recover after geo update — rolling back previous .dat files..."
        local rf
        for rf in "${copied_files[@]}"; do
            run_q "test -f $(quote_sh "${tmp_dir}/bak/${rf}") && docker cp $(quote_sh "${tmp_dir}/bak/${rf}") $(quote_sh "3xui_app:${bin_dir}/${rf}")" || true
        done
        compose restart >/dev/null || docker restart 3xui_app >/dev/null || true
        run_q "rm -rf $(quote_sh "$tmp_dir")" || true
        report_diagnostic "ERROR" "manage_geo_assets" \
            "Xray failed to stay running after updating geo databases" \
            "3xui_app:${bin_dir}/" \
            "Rolled back previous .dat files; inspect Xray logs."
        return 1
    else
        run_q "rm -rf $(quote_sh "$tmp_dir")" || true
        error "No geo-asset files were updated"
        return 1
    fi
}

# ─── Security Audit ─────────────────────────────────────────────────────────
_remote_file_mode() {
    local p="$1"
    run_out "stat -c '%a' $(quote_sh "$p") 2>/dev/null || stat -f '%Lp' $(quote_sh "$p") 2>/dev/null" || true
}

security_audit() {
    echo ""
    echo -e "  ${BOLD}${MAGENTA}Security & Configuration Audit${NC}"
    echo -e "  ${DIM}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${H}${NC}\n"

    local pass=0 warn_c=0 fail=0
    _aud_pass() { printf "  ${GREEN}[PASS]${NC} %s\n" "$1"; pass=$(( pass + 1 )); }
    _aud_warn() { printf "  ${YELLOW}[WARN]${NC} %s\n" "$1"; warn_c=$(( warn_c + 1 )); }
    _aud_fail() { printf "  ${RED}[FAIL]${NC} %s\n" "$1"; fail=$(( fail + 1 )); }

    # 1. Local SSH config hygiene
    if [[ -f "$CONFIG_FILE" ]]; then
        local cmeta cmode="" cuid=""
        cmeta=$(_file_mode_uid "$CONFIG_FILE")
        [[ -n "$cmeta" ]] && read -r cmode cuid <<< "$cmeta"
        if [[ "$cmode" == "600" || "$cmode" == "400" ]]; then
            _aud_pass "Local config $CONFIG_FILE permissions ($cmode)"
        else
            _aud_warn "Local config $CONFIG_FILE has loose permissions (${cmode:-unknown}, expected 600)"
        fi
        if grep -qE '^SSH_PASS_B64=".+"' "$CONFIG_FILE" 2>/dev/null; then
            _aud_warn "Legacy SSH_PASS_B64 stored in $CONFIG_FILE — migrate to SSH keys and clear saved password"
        else
            _aud_pass "No SSH password persisted in $CONFIG_FILE"
        fi
    else
        _aud_pass "No local SSH credentials file on disk ($CONFIG_FILE)"
    fi

    if ! is_deployed; then
        _aud_warn "Stack is not deployed at $INSTALL_DIR — skipping container/panel checks"
        echo ""
        echo -e "  Summary: ${GREEN}${pass} passed${NC}, ${YELLOW}${warn_c} warning(s)${NC}, ${RED}${fail} failed${NC}"
        echo ""
        (( fail > 0 )) && return 1 || return 0
    fi

    get_panel_info || true

    # 2. Panel auth & session
    case "${PANEL_HAS_DEFAULT:-}" in
        false) _aud_pass "Admin credentials changed from default" ;;
        true)  _aud_fail "Default admin credentials still active — reset credentials immediately" ;;
        *)     _aud_warn "Could not verify default-credential status (container stopped?)" ;;
    esac

    if [[ "${PANEL_2FA:-false}" == "true" ]]; then
        _aud_pass "Two-Factor Authentication (2FA) is enabled"
    else
        _aud_warn "Two-Factor Authentication (2FA) is disabled (enable inside 3X-UI web settings)"
    fi

    if [[ "${PANEL_SESSION_AGE:-}" =~ ^[0-9]+$ ]] && (( 10#$PANEL_SESSION_AGE > 0 && 10#$PANEL_SESSION_AGE <= 1440 )); then
        _aud_pass "Panel session timeout set to ${PANEL_SESSION_AGE}m"
    else
        _aud_warn "Panel session timeout unset or > 24h (${PANEL_SESSION_AGE:-0}m) — configure via Settings"
    fi

    if [[ "$PANEL_PATH" == "/" ]]; then
        if $PROXY_ENABLED; then
            _aud_fail "Panel webBasePath is '/' while Caddy reverse proxy is active"
        else
            _aud_warn "Panel webBasePath is '/' (use a random path to reduce automated scanning)"
        fi
    else
        _aud_pass "Custom panel webBasePath ($PANEL_PATH)"
    fi

    # 3. Panel network & TLS
    if $PROXY_ENABLED; then
        if _is_loopback_addr "${PANEL_LISTEN:-}"; then
            _aud_pass "Panel bound to loopback (${PANEL_LISTEN}) behind Caddy"
        else
            _aud_fail "Panel listen IP (${PANEL_LISTEN:-0.0.0.0}) is NOT loopback while Caddy proxy is enabled"
        fi
        if [[ -n "$PANEL_DOMAIN" && "$PANEL_DOMAIN" == "$PROXY_DOMAIN" ]]; then
            _aud_pass "Panel webDomain matches PROXY_DOMAIN ($PROXY_DOMAIN)"
        else
            _aud_warn "Panel webDomain (${PANEL_DOMAIN:-unset}) does not match PROXY_DOMAIN ($PROXY_DOMAIN)"
        fi
    else
        if [[ "$PANEL_PROTO" == "https" ]]; then
            _aud_pass "Direct panel serves HTTPS"
        elif _is_loopback_addr "${PANEL_LISTEN:-}"; then
            _aud_pass "Direct panel restricted to loopback (${PANEL_LISTEN})"
        else
            _aud_fail "Panel exposed over unencrypted HTTP on ${PANEL_LISTEN:-0.0.0.0}:${PANEL_PORT}"
        fi
    fi

    # 4. Subscription security & consistency
    if [[ "$SUB_ENABLE_DB" == "true" ]]; then
        if $PROXY_ENABLED && [[ "$SUB_MODE" != "none" ]]; then
            local exp_host="$PROXY_DOMAIN"
            [[ "$SUB_MODE" == "dedicated" && -n "$SUB_DOMAIN" ]] && exp_host="$SUB_DOMAIN"
            local sub_json_ok=true sub_json_note=""
            if [[ "$SUB_JSON_ENABLE_DB" == "true" ]]; then
                [[ "$SUB_JSON_URI_DB" == https://* ]] && sub_json_note=", JSON enabled" || sub_json_ok=false
            fi
            if [[ "$SUB_LISTEN_DB" == "127.0.0.1" && "$SUB_DOMAIN_DB" == "$exp_host" && "$SUB_URI_DB" == https://* ]] && $sub_json_ok; then
                _aud_pass "Subscription proxy locked to 127.0.0.1 (domain=${SUB_DOMAIN_DB}, HTTPS URI${sub_json_note})"
            else
                _aud_fail "Subscription proxy settings inconsistent (listen=${SUB_LISTEN_DB:-unset}, domain=${SUB_DOMAIN_DB:-unset}, uri=${SUB_URI_DB:-unset})"
            fi
        elif $PROXY_ENABLED; then
            _aud_warn "Subscriptions enabled in 3X-UI while Caddy SUB_MODE=none"
        else
            if _is_loopback_addr "${SUB_LISTEN_DB:-}"; then
                _aud_warn "Direct subscription server bound to loopback (${SUB_LISTEN_DB}) without Caddy"
            fi
            if [[ -n "$SUB_CERT_DB" && -n "$SUB_KEY_DB" ]]; then
                _aud_pass "Direct subscription server uses TLS"
            else
                _aud_warn "Direct subscription server uses plain HTTP (enable TLS or Caddy reverse proxy)"
            fi
        fi
        if [[ "$SUB_ENCRYPT_DB" == "true" ]]; then
            _aud_pass "Subscription Base64 encoding (subEncrypt) enabled"
        else
            _aud_warn "Subscription Base64 encoding (subEncrypt) disabled"
        fi
    else
        _aud_pass "Subscription server disabled"
    fi

    # 5. Caddy hardening
    if $PROXY_ENABLED; then
        if is_caddy_running; then
            _aud_pass "Caddy container (3xui_caddy) is running"
        else
            _aud_fail "Caddy reverse proxy is enabled in proxy.conf but 3xui_caddy is stopped"
        fi
        local cf_path="$INSTALL_DIR/caddy/Caddyfile"
        if run_q "grep -q 'admin unix//config/admin.sock' $(quote_sh "$cf_path")"; then
            _aud_pass "Caddy admin API isolated to Unix socket (/config/admin.sock)"
        else
            _aud_warn "Caddy admin API still on default TCP localhost:2019 (re-run proxy setup to isolate)"
        fi
        if run_q "grep -q 'Strict-Transport-Security' $(quote_sh "$cf_path") && grep -q 'X-Content-Type-Options' $(quote_sh "$cf_path")"; then
            _aud_pass "Caddy security response headers configured"
        else
            _aud_warn "Caddy security response headers incomplete"
        fi
        local c_data_m c_cfg_m
        c_data_m=$(_remote_file_mode "$INSTALL_DIR/caddy/data")
        c_cfg_m=$(_remote_file_mode "$INSTALL_DIR/caddy/config")
        if [[ "$c_data_m" == "700" && "$c_cfg_m" == "700" ]]; then
            _aud_pass "Caddy data & config directories restricted (0700)"
        else
            _aud_warn "Caddy data/config directory modes (${c_data_m:-?}/${c_cfg_m:-?}) looser than 700"
        fi
        if run_q "grep -q 'no-new-privileges:true' $(quote_sh "$INSTALL_DIR/compose.yaml") && grep -q 'cap_drop:' $(quote_sh "$INSTALL_DIR/compose.yaml")"; then
            _aud_pass "Caddy container hardened (cap_drop + no-new-privileges)"
        else
            _aud_warn "Caddy container lacks cap_drop / no-new-privileges (re-run proxy setup)"
        fi
    fi

    # 5b. TLS certificate expiry check (> 14 days)
    if run_q "test -d $(quote_sh "$INSTALL_DIR/cert")"; then
        local cert_list cf exp_dom
        cert_list=$(run_out "find $(quote_sh "$INSTALL_DIR/cert") -name 'fullchain.pem' 2>/dev/null" || true)
        while IFS= read -r cf; do
            [[ -z "$cf" ]] && continue
            exp_dom=$(basename "$(dirname "$cf")")
            if run_q "openssl x509 -checkend 1209600 -noout -in $(quote_sh "$cf")"; then
                _aud_pass "TLS cert for ${exp_dom} valid > 14 days"
            else
                _aud_warn "TLS cert for ${exp_dom} expires within 14 days or is expired"
            fi
        done <<< "$cert_list"
    fi

    # 6. Compose & secrets hygiene
    local cmp_m
    cmp_m=$(_remote_file_mode "$INSTALL_DIR/compose.yaml")
    if [[ "$cmp_m" == "600" || "$cmp_m" == "400" ]]; then
        _aud_pass "compose.yaml permissions ($cmp_m)"
    else
        _aud_warn "compose.yaml permissions (${cmp_m:-?}) should be 600"
    fi
    if run_q "test -f $(quote_sh "$INSTALL_DIR/.env")"; then
        local env_m
        env_m=$(_remote_file_mode "$INSTALL_DIR/.env")
        if [[ "$env_m" == "600" || "$env_m" == "400" ]]; then
            _aud_pass ".env permissions ($env_m)"
        else
            _aud_fail ".env permissions (${env_m:-?}) should be 600"
        fi
    fi
    if _is_postgres_backend; then
        if run_q "grep -q 'XUI_DB_DSN:' $(quote_sh "$INSTALL_DIR/compose.yaml")"; then
            _aud_warn "Plaintext XUI_DB_DSN found in compose.yaml (migrate to .env)"
        elif run_q "test -f $(quote_sh "$INSTALL_DIR/compose.yaml.bak") && grep -q 'XUI_DB_DSN:' $(quote_sh "$INSTALL_DIR/compose.yaml.bak")"; then
            _aud_warn "Plaintext XUI_DB_DSN found in legacy compose.yaml.bak (consider removing)"
        else
            _aud_pass "PostgreSQL DSN isolated in .env (not in compose.yaml)"
        fi
    fi
    if run_q "grep -q 'XRAY_VMESS_AEAD_FORCED:[[:space:]]*\"true\"' $(quote_sh "$INSTALL_DIR/compose.yaml")"; then
        _aud_pass "XRAY_VMESS_AEAD_FORCED enabled"
    else
        _aud_warn "XRAY_VMESS_AEAD_FORCED is disabled or unset"
    fi
    if run_q "grep -q 'XUI_ENABLE_FAIL2BAN:[[:space:]]*\"true\"' $(quote_sh "$INSTALL_DIR/compose.yaml")"; then
        _aud_pass "Fail2ban environment flag enabled"
    else
        _aud_warn "XUI_ENABLE_FAIL2BAN is disabled"
    fi
    if run_q "grep -q 'no-new-privileges:true' $(quote_sh "$INSTALL_DIR/compose.yaml")"; then
        _aud_pass "no-new-privileges enabled in compose.yaml"
    else
        _aud_warn "no-new-privileges missing in compose.yaml"
    fi

    # 7. Host defenses
    if is_running && run_q "docker exec 3xui_app fail2ban-client status 3x-ui"; then
        _aud_pass "Fail2ban 3x-ui jail active"
    else
        _aud_warn "Fail2ban 3x-ui jail not detected"
    fi
    if run_q "(command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active') || (command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q 'running')"; then
        _aud_pass "Host firewall active (ufw or firewalld)"
    else
        _aud_warn "Neither ufw nor firewalld appears active"
    fi

    # 8. Forward Compatibility, Probe Redirection & WebPanel Isolation
    local det_v det_cls
    det_v=$(xui_detect_version 2>/dev/null || true)
    det_cls=$(xui_classify_version "${det_v:-unknown}" 2>/dev/null || echo "unknown_tag")
    case "$det_cls" in
        supported|major_upgrade) _aud_pass "3X-UI version '${det_v}' within supported compatibility matrix" ;;
        unknown_tag)             _aud_warn "3X-UI image tag '${det_v:-unknown}' is unpinned; pin explicit release tags for reproducibility" ;;
        *)                       _aud_fail "3X-UI version '${det_v:-unknown}' (${det_cls}) is unsupported" ;;
    esac

    load_probe_conf
    if $PROBE_REDIRECT_ENABLED; then
        if validate_redirect_url "$PROBE_REDIRECT_TARGET"; then
            _aud_pass "Probe redirection enabled (${PROBE_REDIRECT_TARGET}, fallback=${PROBE_FALLBACK_MODE})"
        else
            _aud_fail "Probe redirection enabled with invalid target URL: ${PROBE_REDIRECT_TARGET}"
        fi
    fi

    load_webpanel_conf
    if $WEBPANEL_ENABLED; then
        if is_webpanel_running; then
            _aud_pass "Standalone Web Management Panel service is running (${WEBPANEL_PATH})"
        else
            _aud_fail "Web Management Panel is enabled in webpanel.conf but service is stopped"
        fi
        if [[ "${WEBPANEL_BIND:-127.0.0.1}" == "127.0.0.1" || "${WEBPANEL_BIND:-}" == "::1" ]]; then
            _aud_pass "WebPanel bound exclusively to loopback (${WEBPANEL_BIND}:${WEBPANEL_PORT})"
        else
            _aud_fail "WebPanel bind host (${WEBPANEL_BIND}) is NOT loopback"
        fi
        local wp_cm wp_am
        wp_cm=$(_remote_file_mode "$INSTALL_DIR/webpanel/webpanel.conf")
        wp_am=$(_remote_file_mode "$INSTALL_DIR/webpanel/auth.json")
        if [[ "$wp_cm" == "600" && "$wp_am" == "600" ]]; then
            _aud_pass "WebPanel config & auth.json permissions restricted (0600)"
        else
            _aud_warn "WebPanel config/auth modes (${wp_cm:-?}/${wp_am:-?}) should be 600"
        fi
        if _paths_overlap "$WEBPANEL_PATH" "$PANEL_PATH"; then
            _aud_fail "WebPanel path ($WEBPANEL_PATH) overlaps 3X-UI panel path ($PANEL_PATH)"
        else
            _aud_pass "WebPanel path ($WEBPANEL_PATH) isolated from 3X-UI panel path ($PANEL_PATH)"
        fi
    fi

    echo ""
    echo -e "  Summary: ${GREEN}${pass} passed${NC}, ${YELLOW}${warn_c} warning(s)${NC}, ${RED}${fail} failed${NC}"
    echo ""
    (( fail > 0 )) && return 1 || return 0
}

# ─── Environment Detection & CLI Entrypoint ─────────────────────────────────
detect_environment() {
    local score=0

    # Check fast local signals first before probing link-local metadata.
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] && score=$(( score - 10 ))
    [[ "$(uname)" == "Darwin" ]] && score=$(( score - 10 ))
    grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null && score=$(( score - 8 )) || true
    [[ -f /.dockerenv ]] && score=$(( score - 10 ))
    [[ -d "$HOME/.docker/desktop" || -f "$HOME/.docker/daemon.json" ]] && score=$(( score - 4 ))

    [[ -f /etc/cloud/cloud.cfg ]] && score=$(( score + 4 ))

    if [[ -r /sys/class/dmi/id/product_name ]]; then
        local product
        product=$(< /sys/class/dmi/id/product_name)
        case "$product" in
            *KVM*|*Virtual*|*QEMU*|*Xen*|*VMware*|*OpenStack*|*HVM*|*Google*|*Amazon*|*Alibaba*|*Hyper-V*)
                score=$(( score + 8 )) ;;
        esac
    fi

    if command -v systemd-detect-virt &>/dev/null; then
        local virt
        virt=$(systemd-detect-virt 2>/dev/null || true)
        case "$virt" in
            kvm|qemu|xen|vmware|oracle|amazon|google|microsoft) score=$(( score + 6 )) ;;
            wsl|lxc|podman|containerd) score=$(( score - 6 )) ;;
        esac
    fi

    # Only hit cloud metadata endpoint when signals are still ambiguous.
    if (( score > -3 && score < 5 )) && command -v curl &>/dev/null; then
        curl -sf --max-time 1 http://169.254.169.254/latest/meta-data/ &>/dev/null && score=$(( score + 10 )) || true
    fi

    if (( score >= 5 )); then
        echo "vps"
    elif (( score <= -3 )); then
        echo "local"
    else
        echo "unknown"
    fi
}

usage() {
    local prog="manage.sh"
    [[ -n "${0:-}" && "$0" != "bash" && "$0" != "-bash" && "$0" != /dev/fd/* && "$0" != /proc/* ]] && prog=$(basename "$0")
    cat <<EOF
3X-UI Manager v${DEPLOY_VERSION} (${REPO_URL})

Usage:
  ${prog} [OPTIONS] [COMMAND] [ARGS]

Options:
  -r, --remote <target>   Target remote VPS ([user@]host[:port], default user=root, port=22)
  -l, --local             Force local execution mode
  -d, --dir <path>        Override install directory (default: /opt/3x-ui)
  -y, --yes               Auto-confirm destructive or interactive confirmation prompts
  -v, --verbose           Enable debug logging to stderr and log file
      --force-compat      Override unsupported 3x-ui version/preflight blocks
  -V, --version           Print 3xui-deploy version and exit
  -h, --help              Show this help message

Commands (omit to launch interactive TUI):
  deploy [sqlite|postgres [user]]
                          Install Docker if needed and deploy 3X-UI
  status                  Show deployment and panel status
  start | stop | restart  Control container lifecycle
  update [tag]            Update 3X-UI (latest or specific tag) with preflight & auto-rollback
  rollback                Rollback to compose.yaml.bak
  compat [check|matrix|test <tag>]
                          Check 3x-ui compatibility, DB schema & preflight image contract
  logs [follow|all|N|deploy]
                          View container logs or 3xui-deploy operation logs
  backup [now|cron-status|cron-set <hour> <keep>|cron-disable]
                          Create timestamped backup or manage daily backup schedule
  restore [archive]       Restore from backup archive
  health                  Show system & panel diagnostics
  xray-status             Show Xray core process, listening sockets & Fail2ban status
  bbr                     Enable TCP BBR & proxy network sysctl tuning
  geo-update [std|ir|ru|all]  Update Xray GeoIP & GeoSite databases
  settings [show|set-port|set-listen|set-webpath|set-security|set-sub|reset-2fa|reset-credentials]
                          Manage panel settings, listen IP, subscriptions & security
  certs [list|issue|renew|revoke|self-signed|apply]
                          Manage Let's Encrypt & self-signed SSL/TLS certificates
  dns [status|check <domain>]
                          Inspect host DNS resolvers, interfaces & domain A/AAAA match
  firewall [status|sync|open <port> [proto]|close <port> [proto]]
                          Inspect and safely manage UFW/Firewalld rules
  proxy [setup|configure|status|verify|reload|probe|check-redirect|disable]
                          Manage Caddy reverse proxy, decoy website & probe redirection
  webpanel [enable|disable|status|reset-password|update-settings|logs]
                          Manage standalone Web Management Panel (/deploy/)
  inbounds [list|verify|sync-proxy|sync-fw]
                          Inspect inbounds, verify sockets & sync Caddy/firewall
  audit                   Run security & configuration audit
  version [--check]       Show installed 3xui-deploy / WebPanel version (or check for updates)
  self-install            Install this manager globally as ${BIN_INSTALL_PATH}
  self-update [tag|main|--check|--force]
                          Update 3xui-deploy (& WebPanel if installed) from latest release or ref
  help                    Show this help message
EOF
}

_deploy_validate_ref() {
    local ref="${1:-}"
    [[ "$ref" == "main" ]] && return 0
    [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]
}

_repo_raw_base_for_ref() {
    local ref="${1:-main}"
    printf 'https://raw.githubusercontent.com/%s/%s' "$REPO_SLUG" "$ref"
}

_deploy_http_get() {
    local url="$1" dst="${2:-}"
    if command -v curl &>/dev/null; then
        if [[ -n "$dst" ]]; then
            curl -fsSL --proto '=https' --tlsv1.2 --max-time 25 "$url" -o "$dst"
        else
            curl -fsSL --proto '=https' --tlsv1.2 --max-time 25 "$url"
        fi
    elif command -v wget &>/dev/null; then
        if [[ -n "$dst" ]]; then
            wget -qO "$dst" --https-only --secure-protocol=TLSv1_2 --timeout=25 "$url"
        else
            wget -qO- --https-only --secure-protocol=TLSv1_2 --timeout=25 "$url"
        fi
    else
        error "curl or wget is required to download from GitHub"
        return 1
    fi
}

_deploy_read_installed_webpanel_version() {
    local init_py="$INSTALL_DIR/webpanel/__init__.py"
    local raw=""
    if $REMOTE; then
        raw=$(run_out "sed -n 's/^__version__[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p' $(quote_sh "$init_py") | head -n 1" || true)
    elif [[ -f "$init_py" ]]; then
        raw=$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$init_py" 2>/dev/null | head -n 1 || true)
    fi
    printf '%s' "${raw//[$'\r\n ']/}"
}

_deploy_extract_script_version() {
    local script_file="$1"
    [[ -f "$script_file" ]] || return 1
    sed -n 's/^DEPLOY_VERSION="\([^"]*\)".*/\1/p' "$script_file" 2>/dev/null | head -n 1
}

_deploy_latest_release_ref() {
    local tag=""
    local releases_url="${REPO_URL}/releases/latest"
    local api_url="https://api.github.com/repos/${REPO_SLUG}/releases/latest"

    if command -v curl &>/dev/null; then
        local effective_url=""
        effective_url=$(curl -fsSLI --proto '=https' --tlsv1.2 -o /dev/null -w '%{url_effective}' --max-time 10 "$releases_url" 2>/dev/null || true)
        if [[ "$effective_url" == */releases/tag/* ]]; then
            tag="${effective_url##*/}"
        fi
        if [[ -z "$tag" ]]; then
            tag=$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 10 "$api_url" 2>/dev/null \
                | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1 || true)
        fi
    elif command -v wget &>/dev/null; then
        tag=$(wget -qO- --https-only --secure-protocol=TLSv1_2 --timeout=10 "$api_url" 2>/dev/null \
            | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1 || true)
    fi

    tag="${tag//[$'\r\n ']/}"
    if [[ -n "$tag" && "$tag" != "main" ]] && _deploy_validate_ref "$tag"; then
        printf '%s|%s|release' "$tag" "${tag#v}"
        return 0
    fi

    local main_ver=""
    main_ver=$(_deploy_http_get "$(_repo_raw_base_for_ref main)/VERSION" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$main_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
        printf 'main|%s|main' "$main_ver"
    else
        printf 'main||main'
    fi
}

_sha256_file() {
    local path="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$path" | awk '{print tolower($1)}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$path" | awk '{print tolower($1)}'
    else
        return 1
    fi
}

_download_release_checksums() {
    local ref="${1:-}" dst="${2:-}"
    [[ "$ref" == v* && -n "$dst" ]] || return 1
    local url="${REPO_URL}/releases/download/${ref}/SHA256SUMS.txt"
    _deploy_http_get "$url" "$dst" 2>/dev/null && [[ -s "$dst" ]]
}

_verify_checksum_if_present() {
    local sums_file="${1:-}" rel_path="${2:-}" local_file="${3:-}"
    [[ -n "$sums_file" && -s "$sums_file" ]] || return 0
    local expected actual
    expected=$(awk -v target="$rel_path" '
        {
            p = $2
            sub(/^\.\//, "", p)
            if (p == target && $1 ~ /^[0-9a-fA-F]{64}$/) {
                print tolower($1)
                exit
            }
        }
    ' "$sums_file" 2>/dev/null || true)
    if [[ -z "$expected" ]]; then
        error "Checksum entry missing for '${rel_path}' in SHA256SUMS.txt"
        return 1
    fi
    actual=$(_sha256_file "$local_file") || {
        error "sha256sum or shasum is required to verify release checksums"
        return 1
    }
    if [[ "$actual" != "$expected" ]]; then
        error "SHA-256 verification failed for ${rel_path} (expected ${expected}, got ${actual})"
        return 1
    fi
    return 0
}

_deploy_version_info() {
    local check_remote=false
    [[ "${1:-}" == "--check" ]] && check_remote=true

    local wp_ver=""
    wp_ver=$(_deploy_read_installed_webpanel_version || true)
    printf 'DEPLOY_CURRENT_VERSION=%s\n' "$DEPLOY_VERSION"
    printf 'DEPLOY_WEBPANEL_VERSION=%s\n' "${wp_ver:-none}"

    if ! $check_remote; then
        if [[ -n "$wp_ver" ]]; then
            echo "  3xui-deploy v${DEPLOY_VERSION} (WebPanel v${wp_ver})"
        else
            echo "  3xui-deploy v${DEPLOY_VERSION}"
        fi
        return 0
    fi

    local resolved="" latest_ref="main" latest_ver="" channel="main"
    resolved=$(_deploy_latest_release_ref || true)
    IFS='|' read -r latest_ref latest_ver channel <<< "$resolved"
    latest_ref="${latest_ref:-main}"
    channel="${channel:-main}"

    local avail="unknown" cmp=""
    if [[ -n "$latest_ver" ]]; then
        cmp=$(_semver_compare "$latest_ver" "$DEPLOY_VERSION" 2>/dev/null || true)
        if [[ "$cmp" == "1" ]]; then
            avail="true"
        elif [[ "$cmp" == "0" || "$cmp" == "-1" ]]; then
            avail="false"
        fi
    fi

    local rel_url="$REPO_URL"
    [[ "$channel" == "release" && "$latest_ref" == v* ]] && rel_url="${REPO_URL}/releases/tag/${latest_ref}"

    printf 'DEPLOY_LATEST_VERSION=%s\n' "${latest_ver:-unknown}"
    printf 'DEPLOY_LATEST_REF=%s\n' "$latest_ref"
    printf 'DEPLOY_CHANNEL=%s\n' "$channel"
    printf 'DEPLOY_UPDATE_AVAILABLE=%s\n' "$avail"
    printf 'DEPLOY_RELEASE_URL=%s\n' "$rel_url"

    if [[ "$avail" == "true" ]]; then
        info "Update available: v${DEPLOY_VERSION} -> v${latest_ver} (${channel}: ${latest_ref})"
    elif [[ "$avail" == "false" ]]; then
        success "Up to date on v${DEPLOY_VERSION} (${channel}: ${latest_ref})"
    else
        warn "Could not resolve remote version from ${REPO_URL}"
    fi
}

deploy_version_cmd() {
    case "${1:-}" in
        "" )
            _deploy_version_info
            ;;
        --check)
            _deploy_version_info --check
            ;;
        *)
            error "Unknown version option: $1 (use: version [--check])"
            return 1
            ;;
    esac
}

_download_script_to() {
    local dst="$1" ref="${2:-main}" sums_file="${3:-}"
    local url
    url="$(_repo_raw_base_for_ref "$ref")/manage.sh"
    _deploy_http_get "$url" "$dst" || return 1
    [[ -s "$dst" ]] || return 1
    head -n 1 "$dst" | grep -q '^#!/usr/bin/env bash' || return 1
    head -n 5 "$dst" | grep -q '^# 3X-UI Manager$' || return 1
    _verify_checksum_if_present "$sums_file" "manage.sh" "$dst" || return 1
    bash -n "$dst" 2>/dev/null
}

_sync_webpanel_from_ref() {
    local ref="${1:-main}" sums_file="${2:-}" manage_src="${3:-}"
    local dst="$INSTALL_DIR/webpanel"
    run_q "test -f $(quote_sh "$dst/server.py")" || return 0

    local stage
    stage=$(mktemp -d /tmp/3xui-wp-update.XXXXXX) || { error "Failed to create WebPanel staging directory"; return 1; }

    local files=(
        "webpanel/__init__.py"
        "webpanel/auth.py"
        "webpanel/probe.py"
        "webpanel/ops.py"
        "webpanel/server.py"
        "webpanel/static/index.html"
        "webpanel/static/app.css"
        "webpanel/static/app.js"
    )
    local base rel url local_target
    base=$(_repo_raw_base_for_ref "$ref")
    mkdir -p "$stage/webpanel/static"

    info "Staging WebPanel files from ${ref}..."
    for rel in "${files[@]}"; do
        url="${base}/${rel}"
        local_target="${stage}/${rel}"
        if ! _deploy_http_get "$url" "$local_target" || [[ ! -s "$local_target" ]]; then
            rm -rf "$stage"
            error "Failed to download ${rel} from ${ref}"
            return 1
        fi
        if ! _verify_checksum_if_present "$sums_file" "$rel" "$local_target"; then
            rm -rf "$stage"
            return 1
        fi
    done

    if command -v python3 &>/dev/null; then
        if ! python3 -m py_compile \
            "${stage}/webpanel/__init__.py" \
            "${stage}/webpanel/auth.py" \
            "${stage}/webpanel/probe.py" \
            "${stage}/webpanel/ops.py" \
            "${stage}/webpanel/server.py" 2>/dev/null; then
            rm -rf "$stage"
            error "Staged WebPanel Python syntax check failed; aborting WebPanel update"
            return 1
        fi
    fi

    if $REMOTE; then
        if ! tar -cf - -C "$stage/webpanel" . | ssh_cmd "mkdir -p $(quote_sh "$dst/static") && tar --no-same-owner -xf - -C $(quote_sh "$dst")"; then
            rm -rf "$stage"
            error "Failed to copy staged WebPanel files to remote host"
            return 1
        fi
        if [[ -n "$manage_src" && -f "$manage_src" ]]; then
            if ! ssh_copy "$manage_src" "$dst/manage.sh" || ! run "chmod 755 $(quote_sh "$dst/manage.sh")"; then
                rm -rf "$stage"
                error "Failed to sync $dst/manage.sh on remote host"
                return 1
            fi
        fi
        run "chmod 700 $(quote_sh "$dst") && chmod 755 $(quote_sh "$dst/static") && chmod 644 $(quote_sh "$dst")/*.py $(quote_sh "$dst/static")/*" || true
    else
        local need_sudo=false
        [[ ! -w "$dst" && $EUID -ne 0 ]] && need_sudo=true
        if $need_sudo && command -v sudo &>/dev/null; then
            sudo mkdir -p "$dst/static" || { rm -rf "$stage"; return 1; }
            sudo cp -a "$stage/webpanel/." "$dst/" || { rm -rf "$stage"; return 1; }
            if [[ -n "$manage_src" && -f "$manage_src" ]]; then
                sudo install -m 0755 "$manage_src" "$dst/manage.sh" || { rm -rf "$stage"; return 1; }
            fi
            sudo chmod 700 "$dst" && sudo chmod 755 "$dst/static" && sudo chmod 644 "$dst"/*.py "$dst/static"/* || true
        else
            mkdir -p "$dst/static" || { rm -rf "$stage"; return 1; }
            cp -a "$stage/webpanel/." "$dst/" || { rm -rf "$stage"; return 1; }
            if [[ -n "$manage_src" && -f "$manage_src" ]]; then
                install -m 0755 "$manage_src" "$dst/manage.sh" || { cp "$manage_src" "$dst/manage.sh" && chmod 755 "$dst/manage.sh"; } || { rm -rf "$stage"; return 1; }
            fi
            chmod 700 "$dst" && chmod 755 "$dst/static" && chmod 644 "$dst"/*.py "$dst/static"/* || true
        fi
    fi

    rm -rf "$stage"
    success "Synced WebPanel package at $dst"

    if run_q "command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet 3xui-deploy-web 2>/dev/null"; then
        if [[ "${WEBPANEL_NO_SELF_RESTART:-0}" == "1" ]]; then
            printf 'WEBPANEL_RESTART_REQUIRED=true\n'
        else
            if $REMOTE; then
                run "systemctl restart 3xui-deploy-web" || warn "Failed to restart 3xui-deploy-web service"
            elif [[ $EUID -eq 0 ]]; then
                systemctl restart 3xui-deploy-web || warn "Failed to restart 3xui-deploy-web service"
            elif command -v sudo &>/dev/null; then
                sudo systemctl restart 3xui-deploy-web || warn "Failed to restart 3xui-deploy-web service"
            fi
        fi
    fi
    return 0
}

_can_write_bin_path() {
    local p="$1" d
    d=$(dirname "$p")
    [[ -w "$p" ]] && return 0
    [[ -d "$d" && -w "$d" ]] && return 0
    [[ ! -e "$d" && -w "$(dirname "$d")" ]] && return 0
    return 1
}

self_install() {
    local tmp_script
    tmp_script=$(mktemp /tmp/3xui-install.XXXXXX.sh) || { error "Failed to create temp file"; return 1; }
    chmod 600 "$tmp_script" 2>/dev/null || true

    if [[ "${XUI_SOURCE_ONLY:-0}" != "1" && -f "${0:-}" && "$0" != /dev/fd/* && "$0" != /proc/* && "$0" != "bash" && "$0" != "-bash" ]] && head -n 5 "$0" 2>/dev/null | grep -q '^# 3X-UI Manager$'; then
        cp "$0" "$tmp_script" || { rm -f "$tmp_script"; error "Failed to copy script"; return 1; }
        bash -n "$tmp_script" 2>/dev/null || { rm -f "$tmp_script"; error "Script syntax check failed"; return 1; }
    else
        info "Downloading latest manager script from GitHub..."
        if ! _download_script_to "$tmp_script" "main"; then
            rm -f "$tmp_script"
            error "Download or validation failed"
            return 1
        fi
    fi

    local bin_dir
    bin_dir=$(dirname "$BIN_INSTALL_PATH")
    if [[ $EUID -eq 0 ]] || _can_write_bin_path "$BIN_INSTALL_PATH"; then
        mkdir -p "$bin_dir"
        install -m 0755 "$tmp_script" "$BIN_INSTALL_PATH" || { cp "$tmp_script" "$BIN_INSTALL_PATH" && chmod 755 "$BIN_INSTALL_PATH"; }
    else
        info "Installing to $BIN_INSTALL_PATH (sudo required)..."
        sudo install -m 0755 "$tmp_script" "$BIN_INSTALL_PATH"
    fi
    local rc=$?
    rm -f "$tmp_script"

    if (( rc == 0 )); then
        success "Installed to $BIN_INSTALL_PATH — you can now run '3xui-deploy' from anywhere!"
    else
        error "Failed to install to $BIN_INSTALL_PATH"
        return 1
    fi
}

self_update() {
    local check_only=false force_update=false requested_ref="" arg=""
    for arg in "$@"; do
        case "$arg" in
            --check)     check_only=true ;;
            --force|-f)  force_update=true ;;
            -*)
                error "Unknown self-update option: $arg (use: self-update [vX.Y.Z|main|--check|--force])"
                return 1
                ;;
            *)
                if [[ -n "$requested_ref" ]]; then
                    error "Unexpected extra argument to self-update: $arg"
                    return 1
                fi
                requested_ref="$arg"
                ;;
        esac
    done

    if $check_only; then
        _deploy_version_info --check
        return $?
    fi

    if [[ -n "$requested_ref" ]] && ! _deploy_validate_ref "$requested_ref"; then
        error "Invalid target version/ref '$requested_ref' (expected vX.Y.Z or main)"
        return 1
    fi

    if $REMOTE; then
        init_master_connection || return 1
    fi

    local target_ref="" target_ver="" channel="release" auto_resolved=false
    if [[ -n "$requested_ref" ]]; then
        target_ref="$requested_ref"
        if [[ "$target_ref" == v* ]]; then
            target_ver="${target_ref#v}"
            channel="release"
        else
            channel="main"
            target_ver=$(_deploy_http_get "$(_repo_raw_base_for_ref main)/VERSION" 2>/dev/null | tr -d '[:space:]' || true)
            [[ "$target_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || target_ver=""
        fi
    else
        auto_resolved=true
        local resolved=""
        resolved=$(_deploy_latest_release_ref || true)
        IFS='|' read -r target_ref target_ver channel <<< "$resolved"
        target_ref="${target_ref:-main}"
        channel="${channel:-main}"
    fi

    local wp_ver=""
    wp_ver=$(_deploy_read_installed_webpanel_version || true)
    if ! $force_update && [[ -n "$target_ver" ]]; then
        local cmp=""
        cmp=$(_semver_compare "$target_ver" "$DEPLOY_VERSION" 2>/dev/null || true)
        if [[ "$cmp" == "0" ]] && { [[ -z "$wp_ver" ]] || [[ "$wp_ver" == "$target_ver" ]]; }; then
            success "Already up to date (3xui-deploy v${DEPLOY_VERSION}, ref: ${target_ref})"
            printf 'UPDATED_FROM=%s\nUPDATED_TO=%s\nUPDATED_REF=%s\n' "$DEPLOY_VERSION" "$DEPLOY_VERSION" "$target_ref"
            return 0
        fi
        if $auto_resolved && [[ "$cmp" == "-1" ]]; then
            success "Current v${DEPLOY_VERSION} is already newer than latest release v${target_ver}"
            printf 'UPDATED_FROM=%s\nUPDATED_TO=%s\nUPDATED_REF=%s\n' "$DEPLOY_VERSION" "$DEPLOY_VERSION" "$target_ref"
            return 0
        fi
    fi

    local tmp_script tmp_sums
    tmp_script=$(mktemp /tmp/3xui-update.XXXXXX.sh) || { error "Failed to create temp file"; return 1; }
    tmp_sums=$(mktemp /tmp/3xui-sums.XXXXXX) || { rm -f "$tmp_script"; error "Failed to create temp checksum file"; return 1; }
    chmod 600 "$tmp_script" "$tmp_sums" 2>/dev/null || true

    if [[ "$target_ref" == v* ]]; then
        if _download_release_checksums "$target_ref" "$tmp_sums"; then
            info "Downloaded SHA256SUMS.txt for ${target_ref}"
        else
            : > "$tmp_sums"
        fi
    else
        : > "$tmp_sums"
    fi

    info "Downloading 3xui-deploy (${target_ref}${target_ver:+ · v${target_ver}}) from ${REPO_URL}..."
    if ! _download_script_to "$tmp_script" "$target_ref" "$tmp_sums"; then
        rm -f "$tmp_script" "$tmp_sums"
        error "Failed to download or validate updated script from ${target_ref}"
        return 1
    fi

    local new_ver=""
    new_ver=$(_deploy_extract_script_version "$tmp_script" || true)
    new_ver="${new_ver:-${target_ver:-unknown}}"

    local updated=false
    if [[ "${XUI_SOURCE_ONLY:-0}" != "1" && -f "${0:-}" && "$0" != /dev/fd/* && "$0" != /proc/* && "$0" != "bash" && "$0" != "-bash" ]] && head -n 5 "$0" 2>/dev/null | grep -q '^# 3X-UI Manager$'; then
        if [[ -w "$0" ]]; then
            install -m 0755 "$tmp_script" "$0" && updated=true
        elif [[ $EUID -ne 0 ]] && command -v sudo &>/dev/null; then
            sudo install -m 0755 "$tmp_script" "$0" && updated=true
        fi
    fi

    local bin_dir
    bin_dir=$(dirname "$BIN_INSTALL_PATH")
    if [[ -e "$BIN_INSTALL_PATH" ]] && [[ "$(realpath "$BIN_INSTALL_PATH" 2>/dev/null || echo "$BIN_INSTALL_PATH")" != "$(realpath "${0:-}" 2>/dev/null || echo "")" ]]; then
        if [[ $EUID -eq 0 ]] || _can_write_bin_path "$BIN_INSTALL_PATH"; then
            cp -a "$BIN_INSTALL_PATH" "${BIN_INSTALL_PATH}.bak" 2>/dev/null || true
            install -m 0755 "$tmp_script" "$BIN_INSTALL_PATH" && updated=true
        elif command -v sudo &>/dev/null; then
            sudo cp -a "$BIN_INSTALL_PATH" "${BIN_INSTALL_PATH}.bak" 2>/dev/null || true
            sudo install -m 0755 "$tmp_script" "$BIN_INSTALL_PATH" && updated=true
        fi
    fi

    if ! $updated; then
        if [[ $EUID -eq 0 ]] || _can_write_bin_path "$BIN_INSTALL_PATH"; then
            mkdir -p "$bin_dir"
            install -m 0755 "$tmp_script" "$BIN_INSTALL_PATH" && updated=true
        elif command -v sudo &>/dev/null; then
            sudo install -m 0755 "$tmp_script" "$BIN_INSTALL_PATH" && updated=true
        fi
    fi

    local wp_sync_rc=0
    if run_q "test -f $(quote_sh "$INSTALL_DIR/webpanel/server.py")"; then
        _sync_webpanel_from_ref "$target_ref" "$tmp_sums" "$tmp_script" || wp_sync_rc=1
    elif ! $REMOTE && [[ -f "$INSTALL_DIR/webpanel/manage.sh" ]] && [[ "$(realpath "$INSTALL_DIR/webpanel/manage.sh" 2>/dev/null || echo "$INSTALL_DIR/webpanel/manage.sh")" != "$(realpath "${0:-}" 2>/dev/null || echo "")" ]]; then
        if [[ $EUID -eq 0 || -w "$INSTALL_DIR/webpanel/manage.sh" ]]; then
            install -m 0755 "$tmp_script" "$INSTALL_DIR/webpanel/manage.sh" || true
        elif command -v sudo &>/dev/null; then
            sudo install -m 0755 "$tmp_script" "$INSTALL_DIR/webpanel/manage.sh" || true
        fi
    fi

    rm -f "$tmp_script" "$tmp_sums"
    if (( wp_sync_rc != 0 )); then
        error "Manager script updated to v${new_ver}, but WebPanel sync failed"
        return 1
    fi
    if $updated; then
        printf 'UPDATED_FROM=%s\nUPDATED_TO=%s\nUPDATED_REF=%s\n' "$DEPLOY_VERSION" "$new_ver" "$target_ref"
        success "Updated 3xui-deploy: v${DEPLOY_VERSION} -> v${new_ver} (${target_ref})"
    else
        error "Could not write updated script"
        return 1
    fi
}

_parse_remote_spec() {
    local spec="$1"
    local u="root" h="" p="22"

    if [[ "$spec" == *@* ]]; then
        u="${spec%%@*}"
        spec="${spec#*@}"
    fi

    if [[ "$spec" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
        h="${BASH_REMATCH[1]}"
        p="${BASH_REMATCH[2]}"
    elif [[ "$spec" =~ ^\[([0-9a-fA-F:]+)\]$ ]]; then
        h="${BASH_REMATCH[1]}"
    elif [[ "$spec" == *:*:* ]]; then
        # Raw IPv6 without brackets/port
        h="$spec"
    elif [[ "$spec" == *:* ]]; then
        h="${spec%:*}"
        p="${spec##*:}"
    else
        h="$spec"
    fi

    validate_ssh_user "$u" || { error "Invalid SSH user in '$1'"; exit 1; }
    validate_ssh_host "$h" || { error "Invalid SSH host in '$1'"; exit 1; }
    validate_port "$p"     || { error "Invalid SSH port in '$1'"; exit 1; }

    SSH_USER="$u"
    SSH_HOST="$h"
    SSH_PORT="$p"
    REMOTE=true
}

ensure_local_privileges() {
    if $REMOTE; then
        return 0
    fi
    if [[ $EUID -eq 0 ]]; then
        return 0
    fi
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        return 0
    fi
    error "Root privileges (sudo) or docker group access required for local management."
    exit 1
}

main_loop() {
    local options=(
        "--- DEPLOYMENT & VERSIONING ---"
        "Deploy / Install"
        "Update to latest version"
        "Change version manually"
        "Rollback version"
        "Remove"
        "--- CONTROL & MONITORING ---"
        "Start"
        "Stop"
        "Restart"
        "Status"
        "Health & diagnostics"
        "Logs"
        "Lazydocker UI"
        "--- PANEL & SECURITY ---"
        "Panel settings & security"
        "Reverse proxy (Caddy)"
        "Standalone Web Management Panel"
        "Compatibility & preflight checks"
        "Inbounds & protocol routing"
        "Manage certificates"
        "Security audit"
        "Xray status"
        "--- BACKUPS ---"
        "Backup & restore"
        "--- VPS & SYSTEM ---"
        "BBR & network tuning"
        "Firewall helper"
        "Update GeoIP / GeoSite"
        "Target & SSH manager"
        "Container shell (bash)"
        "Install / update CLI (3xui-deploy)"
        "Exit"
    )

    while true; do
        tui_select "Main Menu" "" "${options[@]}"
        local choice=$?
        _SKIP_PAUSE=false

        if [[ $choice -eq 255 ]]; then
            clear_screen
            echo -e "\nBye!"
            exit 0
        fi

        clear_screen

        case "${options[$choice]}" in
            "Deploy / Install")          deploy ;;
            "Update to latest version")  update_panel_latest ;;
            "Change version manually")   change_version_manually ;;
            "Rollback version")          rollback_version ;;
            "Remove")                    remove_panel ;;
            "Start")                     start_panel ;;
            "Stop")                      stop_panel ;;
            "Restart")                   restart_panel ;;
            "Status")                    status_panel ;;
            "Health & diagnostics")      health_check ;;
            "Logs")                      logs_panel ;;
            "Lazydocker UI")             launch_lazydocker ;;
            "Panel settings & security")   manage_panel_settings ;;
            "Reverse proxy (Caddy)")       manage_reverse_proxy ;;
            "Standalone Web Management Panel") manage_webpanel ;;
            "Compatibility & preflight checks") xui_check_compatibility check || true ;;
            "Inbounds & protocol routing") manage_inbounds ;;
            "Manage certificates")         manage_certs ;;
            "Security audit")              security_audit || true ;;
            "Xray status")                 xray_status ;;
            "Backup & restore")          manage_backups ;;
            "BBR & network tuning")      enable_bbr_tuning ;;
            "Firewall helper")           manage_firewall ;;
            "Update GeoIP / GeoSite")    manage_geo_assets ;;
            "Target & SSH manager")      manage_ssh ;;
            "Container shell (bash)")    container_control ;;
            "Install / update CLI (3xui-deploy)")
                if [[ -e "$BIN_INSTALL_PATH" ]]; then
                    self_update
                else
                    self_install
                fi
                ;;
            "Exit")                      clear_screen; echo -e "\nBye!"; exit 0 ;;
            *)                           warn "Invalid option selected" ;;
        esac

        $_SKIP_PAUSE || { echo ""; read -rp "Press Enter to return to menu..."; }
    done
}

main() {
    local orig_args=("$@")
    setup_terminal
    load_config

    local cli_cmd="" cli_arg="" cli_arg2=""
    local -a cli_args=() cli_rest=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--remote)
                [[ $# -lt 2 ]] && { error "--remote requires [user@]host[:port]"; exit 1; }
                _parse_remote_spec "$2"
                shift 2
                ;;
            -l|--local)
                FORCE_LOCAL=true
                REMOTE=false
                shift
                ;;
            -d|--dir)
                [[ $# -lt 2 ]] && { error "--dir requires a safe absolute path"; exit 1; }
                validate_safe_dir "$2" || { error "Install dir must be a safe non-system absolute path"; exit 1; }
                INSTALL_DIR="$2"
                shift 2
                ;;
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            -v|--verbose)
                XUI_DEBUG=1
                shift
                ;;
            -V|--version)
                printf '3xui-deploy v%s\n' "$DEPLOY_VERSION"
                exit 0
                ;;
            --force-compat)
                FORCE_COMPAT=true
                shift
                ;;
            --check|--force|-f)
                if [[ -n "$cli_cmd" ]]; then
                    cli_args+=("$1")
                    shift
                else
                    error "Option '$1' must follow a command (e.g. 'self-update $1' or 'version $1')"
                    exit 1
                fi
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                if [[ -z "$cli_cmd" ]]; then
                    cli_cmd="$1"
                else
                    cli_args+=("$1")
                fi
                shift
                ;;
        esac
    done

    cli_arg="${cli_args[0]:-}"
    cli_arg2="${cli_args[1]:-}"
    if (( ${#cli_args[@]} > 1 )); then
        cli_rest=("${cli_args[@]:1}")
    fi

    validate_safe_dir "$INSTALL_DIR" || { error "Unsafe install directory: $INSTALL_DIR"; exit 1; }
    validate_safe_dir "$BACKUP_DIR"  || { error "Unsafe backup directory: $BACKUP_DIR"; exit 1; }

    # Non-interactive / direct CLI command path.
    if [[ -n "$cli_cmd" ]]; then
        case "$cli_cmd" in
            help)         usage; exit 0 ;;
            version)      deploy_version_cmd ${cli_args[@]+"${cli_args[@]}"}; exit $? ;;
            self-install) self_install; exit $? ;;
            self-update)  self_update ${cli_args[@]+"${cli_args[@]}"}; exit $? ;;
        esac

        local _needs_tty=false
        if ! $AUTO_YES; then
            case "$cli_cmd:${cli_arg:-}" in
                deploy:|settings:|certs:) _needs_tty=true ;;
                proxy:|proxy:setup|proxy:probe) _needs_tty=true ;;
                webpanel:|webpanel:reset-password) _needs_tty=true ;;
                inbounds:) _needs_tty=true ;;
            esac
        fi
        if $_needs_tty && [[ ! -t 0 ]] && ( : < /dev/tty ) 2>/dev/null; then
            exec < /dev/tty
        fi

        INTERACTIVE=false
        if $REMOTE; then
            init_master_connection || exit 1
        else
            ensure_local_privileges
        fi

        case "$cli_cmd" in
            deploy)
                if [[ -n "$cli_arg" ]] || $AUTO_YES; then
                    deploy "$cli_arg" "$cli_arg2"
                else
                    INTERACTIVE=true
                    deploy
                fi
                ;;
            status)       status_panel ;;
            start)        start_panel ;;
            stop)         stop_panel ;;
            restart)      restart_panel ;;
            update)       update_panel_latest "$cli_arg" ;;
            rollback)     rollback_version ;;
            compat)
                case "${cli_arg:-check}" in
                    check|matrix) xui_check_compatibility "${cli_arg:-check}" ;;
                    test)         xui_check_compatibility test "$cli_arg2" ;;
                    *)            error "Unknown compat action: $cli_arg (use: check|matrix|test <tag>)"; exit 1 ;;
                esac
                ;;
            logs)         logs_panel "${cli_arg:-100}" ;;
            backup)
                case "${cli_arg:-now}" in
                    now)          backup_panel ;;
                    cron-status)  _status_backup_cron ;;
                    cron-set)     _install_backup_cron "${cli_arg2:-3}" "${cli_args[2]:-7}" ;;
                    cron-disable) _disable_backup_cron ;;
                    *)            error "Unknown backup action: $cli_arg (use: now|cron-status|cron-set <hour> <keep>|cron-disable)"; exit 1 ;;
                esac
                ;;
            restore)      restore_panel "$cli_arg" ;;
            health)       health_check ;;
            xray-status)  xray_status ;;
            bbr)          enable_bbr_tuning ;;
            geo-update)   manage_geo_assets "${cli_arg:-std}" ;;
            settings)
                if [[ -z "$cli_arg" ]]; then
                    INTERACTIVE=true
                    manage_panel_settings
                else
                    settings_cli_dispatch "$cli_arg" ${cli_rest[@]+"${cli_rest[@]}"}
                fi
                ;;
            certs)
                if [[ -z "$cli_arg" ]]; then
                    INTERACTIVE=true
                    manage_certs
                else
                    certs_cli_dispatch "$cli_arg" ${cli_rest[@]+"${cli_rest[@]}"}
                fi
                ;;
            dns)
                case "${cli_arg:-status}" in
                    status) dns_status_cli ;;
                    check)  dns_check_cli "$cli_arg2" ;;
                    *)      error "Unknown dns action: $cli_arg (use: status|check <domain>)"; exit 1 ;;
                esac
                ;;
            firewall)
                firewall_cli_dispatch "${cli_arg:-status}" ${cli_rest[@]+"${cli_rest[@]}"}
                ;;
            proxy)
                case "${cli_arg:-}" in
                    "")              INTERACTIVE=true; manage_reverse_proxy ;;
                    setup)           INTERACTIVE=true; setup_reverse_proxy ;;
                    configure)       configure_reverse_proxy_cli ${cli_rest[@]+"${cli_rest[@]}"} ;;
                    status)          status_reverse_proxy ;;
                    verify)          verify_reverse_proxy ;;
                    reload)          reload_reverse_proxy ;;
                    probe)           INTERACTIVE=true; configure_probe_redirect ;;
                    check-redirect)  check_redirect_target_health "$cli_arg2" ;;
                    sync-caddy)      get_panel_info >/dev/null 2>&1 || true; _sync_caddy_if_active "$PANEL_PORT" "$PANEL_PATH" ;;
                    decoy-apply)     load_probe_conf; generate_decoy_site true ;;
                    protected-paths) _print_protected_paths ;;
                    disable)         disable_reverse_proxy ;;
                    *)               error "Unknown proxy action: $cli_arg (use: setup|configure|status|verify|reload|probe|check-redirect|disable)"; exit 1 ;;
                esac
                ;;
            webpanel)
                case "${cli_arg:-}" in
                    "")              INTERACTIVE=true; manage_webpanel ;;
                    enable)          enable_webpanel "${cli_arg2:-cli}" ;;
                    disable)         disable_webpanel ;;
                    status)          status_webpanel ;;
                    reset-password)  INTERACTIVE=true; reset_webpanel_password ;;
                    update-settings) webpanel_update_settings ${cli_rest[@]+"${cli_rest[@]}"} ;;
                    logs)            run "tail -n 100 $(quote_sh "$INSTALL_DIR/logs/webpanel-audit.log") 2>/dev/null || echo '(no audit log yet)'" ;;
                    *)               error "Unknown webpanel action: $cli_arg (use: enable|disable|status|reset-password|update-settings|logs)"; exit 1 ;;
                esac
                ;;
            inbounds)
                case "${cli_arg:-}" in
                    "")         INTERACTIVE=true; manage_inbounds ;;
                    list)       list_inbounds_report ;;
                    verify)     verify_inbounds_listeners ;;
                    sync-proxy) sync_inbounds_caddy ;;
                    sync-fw)    sync_inbound_firewall ;;
                    *)          error "Unknown inbounds action: $cli_arg (use: list|verify|sync-proxy|sync-fw)"; exit 1 ;;
                esac
                ;;
            audit)        security_audit ;;
            *)            error "Unknown command: $cli_cmd"; usage; exit 1 ;;
        esac
        exit $?
    fi

    # Support interactive TUI when launched via `curl ... | bash`
    if [[ ! -t 0 ]] && ( : < /dev/tty ) 2>/dev/null; then
        exec < /dev/tty
    fi

    # Interactive TUI path.
    if $REMOTE; then
        init_master_connection || exit 1
        main_loop
        return
    fi

    if $FORCE_LOCAL; then
        ensure_local_privileges
        main_loop
        return
    fi

    local detected detected_label
    detected=$(detect_environment)
    case "$detected" in
        vps)   detected_label="VPS/Server" ;;
        local) detected_label="Local" ;;
        *)     detected_label="Unknown" ;;
    esac

    case "$detected" in
        vps)
            if [[ $EUID -ne 0 ]] && ! (command -v docker &>/dev/null && docker info &>/dev/null); then
                tui_select "Environment: VPS/Server detected" "" "Re-run as root (sudo)" "Connect to another VPS via SSH" "Exit"
                local choice=$?
                case "$choice" in
                    0)
                        if [[ -f "${0:-}" && "$0" != /dev/fd/* && "$0" != /proc/* && "$0" != "bash" && "$0" != "-bash" ]]; then
                            exec sudo "$0" ${orig_args[@]+"${orig_args[@]}"}
                        else
                            exec sudo bash -c 's=$(mktemp /tmp/3xui-sudo.XXXXXX.sh); trap "rm -f \"$s\"" EXIT; chmod 700 "$s"; curl -fsSL --proto "=https" --tlsv1.2 "$1" -o "$s" && [ -s "$s" ] && bash -n "$s" && bash "$s" "${@:2}"' _ "$REPO_RAW_URL" ${orig_args[@]+"${orig_args[@]}"}
                        fi
                        ;;
                    1) setup_ssh || exit 1 ;;
                    *) exit 0 ;;
                esac
            fi
            main_loop
            ;;
        local|*)
            tui_select "Environment: ${detected_label} machine detected" "" "Connect to remote VPS via SSH" "Run locally (this machine)" "Exit"
            local choice=$?
            case "$choice" in
                0) setup_ssh || exit 1 ;;
                1)
                    if [[ $EUID -ne 0 ]] && ! (command -v docker &>/dev/null && docker info &>/dev/null); then
                        error "Run as root (sudo) or add user to docker group"
                        exit 1
                    fi
                    ;;
                *) exit 0 ;;
            esac
            main_loop
            ;;
    esac
}

if [[ "${XUI_SOURCE_ONLY:-0}" != "1" ]]; then
    main "$@"
fi
