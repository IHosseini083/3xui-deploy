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

# ─── Globals & Defaults ─────────────────────────────────────────────────────
REPO_URL="https://github.com/IHosseini083/3xui-deploy"
REPO_RAW_URL="https://raw.githubusercontent.com/IHosseini083/3xui-deploy/main/manage.sh"
BIN_INSTALL_PATH="/usr/local/bin/3xui-deploy"

INSTALL_DIR="${XUI_INSTALL_DIR:-/opt/3x-ui}"
BACKUP_DIR="${XUI_BACKUP_DIR:-/opt/3x-ui-backups}"
CONFIG_FILE="${HOME}/.3xui-manager.conf"
COMPOSE_CMD=""

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
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

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
        echo -e "${NC}${DIM}  Xray panel · Docker deployment manager${NC}"
    else
        echo -e "${CYAN}${BOLD}  3X-UI MANAGER${NC}"
        echo -e "${DIM}  Xray panel · Docker deployment manager${NC}"
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

invalidate_status() { _STATUS=""; }

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
    run_q "docker exec 3xui_app sh -c 'apk update >/dev/null 2>&1 && apk add --no-cache sqlite >/dev/null 2>&1'" \
        || return 1
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
        if is_running && ensure_sqlite_in_container; then
            run_out "docker exec 3xui_app sqlite3 -cmd '.timeout 5000' /etc/x-ui/x-ui.db $(quote_sh "$sql")" || true
        elif run_q "command -v sqlite3 && test -f $(quote_sh "$INSTALL_DIR/db/x-ui.db")"; then
            run_out "sqlite3 -cmd '.timeout 5000' $(quote_sh "$INSTALL_DIR/db/x-ui.db") $(quote_sh "$sql")" || true
        fi
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
        if is_running && ensure_sqlite_in_container; then
            run_out "docker exec 3xui_app sqlite3 -cmd '.timeout 5000' -separator \$'\t' /etc/x-ui/x-ui.db $(quote_sh "$sql")" || true
        elif run_q "command -v sqlite3 && test -f $(quote_sh "$INSTALL_DIR/db/x-ui.db")"; then
            run_out "sqlite3 -cmd '.timeout 5000' -separator \$'\t' $(quote_sh "$INSTALL_DIR/db/x-ui.db") $(quote_sh "$sql")" || true
        fi
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
        if is_running && ensure_sqlite_in_container; then
            run_masked "Update 3X-UI setting ($key)" "docker exec 3xui_app sqlite3 -cmd '.timeout 5000' /etc/x-ui/x-ui.db $(quote_sh "$sql")"
        elif run_q "command -v sqlite3 && test -f $(quote_sh "$INSTALL_DIR/db/x-ui.db")"; then
            run_masked "Update 3X-UI setting ($key)" "sqlite3 -cmd '.timeout 5000' $(quote_sh "$INSTALL_DIR/db/x-ui.db") $(quote_sh "$sql")"
        else
            error "sqlite3 unavailable to update $INSTALL_DIR/db/x-ui.db"
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

# ─── Panel Introspection & Settings ─────────────────────────────────────────
# Note: inside mhsanaei/3x-ui Docker images, /usr/bin/x-ui is the x-ui.sh shell
# wrapper (no 'setting' subcommand). Always invoke the Go binary (/app/x-ui).
_xui_setting_cmd() {
    local args="" a
    for a in "$@"; do
        args+=" $(quote_sh "$a")"
    done
    printf 'docker exec 3xui_app sh -c '\''b=/app/x-ui; [ -x "$b" ] || b=/usr/local/x-ui/x-ui; exec "$b" setting "$@"'\'' _%s' "$args"
}

# Set panel username/password via stdin so the password never appears in local,
# SSH, or docker exec process command-line arguments.
_xui_set_credentials_stdin() {
    local user="$1" pass="$2" port="${3:-}" webpath="${4:-}"
    local inner_sh='IFS= read -r _p; _u="$1"; _pt="$2"; _wp="$3"; b=/app/x-ui; [ -x "$b" ] || b=/usr/local/x-ui/x-ui; set -- setting "-username=${_u}" "-password=${_p}"; [ -n "$_pt" ] && set -- "$@" "-port=${_pt}"; [ -n "$_wp" ] && set -- "$@" "-webBasePath=${_wp}"; exec "$b" "$@"'
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

    if [[ "$code" == "200" ]] && printf '%s' "$body" | grep -qiE '(<html|id="app"|3x-ui|assets/)'; then
        if ! printf '%s' "$body" | grep -qE '(Edge Relay Node|Service Status Portal)'; then
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

    if printf '%s' "$clean_resp" | grep -qE '(Edge Relay Node|Service Status Portal)'; then
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
    run_q "grep -q $(quote_sh "tls /root/cert/$PROXY_DOMAIN/") $(quote_sh "$INSTALL_DIR/caddy/Caddyfile")" && use_p_cert=true
    if [[ "$SUB_MODE" == "dedicated" && -n "$SUB_DOMAIN" ]]; then
        run_q "grep -q $(quote_sh "tls /root/cert/$SUB_DOMAIN/") $(quote_sh "$INSTALL_DIR/caddy/Caddyfile")" && use_s_cert=true
    fi
    generate_caddyfile "$PROXY_DOMAIN" "$PROXY_PORT" "$PROXY_EMAIL" "$p_port" "$p_path" \
        "$SUB_MODE" "$SUB_DOMAIN" "$SUB_PORT" "$SUB_PATH" "$SUB_JSON_PATH" \
        "$use_p_cert" "$use_s_cert" || return 1
    if is_caddy_running; then
        _caddy_reload && success "Synced & reloaded Caddy reverse proxy" || warn "Failed to reload Caddy"
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
        changed=true
    fi

    if $changed; then
        confirm "Restart panel now to apply changes?" && restart_panel || true
    fi
}

reset_panel_2fa() {
    require_running || return 1
    confirm "Disable / reset Two-Factor Authentication (2FA) for admin?" || return 0
    run "$(_xui_setting_cmd -resetTwoFactor=true)" || return 1
    success "Two-Factor Authentication reset"
    confirm "Restart panel now?" && restart_panel || true
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

apply_version() {
    local new_tag="$1"
    if ! validate_tag "$new_tag"; then
        error "Invalid version tag: $new_tag"
        return 1
    fi

    echo ""
    info "Applying version $new_tag..."

    is_deployed || { error "compose.yaml not found at $INSTALL_DIR"; return 1; }

    local q_cfg q_bak q_tmp
    q_cfg=$(quote_sh "$INSTALL_DIR/compose.yaml")
    q_bak=$(quote_sh "$INSTALL_DIR/compose.yaml.bak")
    q_tmp=$(quote_sh "$INSTALL_DIR/compose.yaml.tmp")

    run "(umask 077 && cp $q_cfg $q_bak && chmod 600 $q_bak)" || { error "Failed to backup compose.yaml"; return 1; }

    run "awk -v tag=$(quote_sh "$new_tag") 'index(\$0, \"image: ghcr.io/mhsanaei/3x-ui:\") > 0 { sub(/3x-ui:.*/, \"3x-ui:\" tag) } { print }' $q_cfg > $q_tmp && chmod 600 $q_tmp && mv $q_tmp $q_cfg" \
        || { error "Failed to update version tag in compose.yaml"; return 1; }

    info "Pulling image ($new_tag)..."
    compose pull || { error "Image pull failed. Use 'Rollback version' to revert."; return 1; }

    info "Recreating containers..."
    compose up -d || { error "Container recreation failed. Use 'Rollback version' to revert."; return 1; }

    invalidate_status
    success "Panel successfully updated to version $new_tag"
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
    if is_deployed; then
        warn "Already deployed at $INSTALL_DIR"
        confirm "Redeploy (overwrite compose.yaml)?" || return 0
    fi

    ensure_docker || { error "Could not install Docker"; return 1; }

    local db_type="sqlite"
    if $INTERACTIVE; then
        tui_select "Database Selection" "Choose a backend for 3X-UI:" "SQLite (default)" "PostgreSQL" "Cancel"
        local sel=$?
        clear_screen
        case "$sel" in
            0) db_type="sqlite" ;;
            1) db_type="postgres" ;;
            2|255) info "Cancelled"; return 0 ;;
        esac
    fi

    local pg_user="xui" pg_pass="" pg_auto=false
    if [[ "$db_type" == "postgres" ]]; then
        echo ""
        read -rp "  Postgres user [xui]: " pg_user
        pg_user="${pg_user:-xui}"
        if ! validate_pg_ident "$pg_user"; then
            error "Invalid Postgres username (alphanumeric/_/-, starting with letter or _)"
            return 1
        fi
        read -rs -p "  Postgres password [Enter to auto-generate]: " pg_pass
        echo ""
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
    $pg_auto && echo -e "  PG Pass   : ${BOLD}${YELLOW}$pg_pass${NC}  (also stored in $INSTALL_DIR/.env)"
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
    local latest_tag
    latest_tag=$(get_latest_version)
    apply_version "$latest_tag"
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
    require_deployed || return 1
    local mode="${1:-}"

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

    tui_select "Logs Viewer" "Select log length:" "Live follow" "Last 100 lines" "Last 500 lines" "Full logs" "Cancel"
    local sel=$?
    clear_screen

    case "$sel" in
        0) run_it "cd $(quote_sh "$INSTALL_DIR") && $COMPOSE_CMD logs -f" ;;
        1) compose logs --tail=100 ;;
        2) compose logs --tail=500 ;;
        3) compose logs ;;
        4|255) info "Cancelled" ;;
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

for chk in "\$src/compose.yaml" "\$src/.env" "\$src/caddy/proxy.conf" "\$src/caddy/Caddyfile" "\$src/db/x-ui.db" "\$src/postgres_dump.sql"; do
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

setup_backup_cron() {
    local cron_file="/etc/cron.d/3xui-backup"
    local helper_script="/usr/local/bin/3xui-auto-backup.sh"

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
            if ! [[ "$hour" =~ ^[0-9]+$ ]] || (( 10#$hour < 0 || 10#$hour > 23 )); then
                error "Invalid hour: $hour"
                return 1
            fi
            read -rp "  Backups to retain [7]: " keep
            keep="${keep:-7}"
            if ! [[ "$keep" =~ ^[0-9]+$ ]] || (( 10#$keep < 1 || 10#$keep > 365 )); then
                error "Invalid retention count: $keep"
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
            success "Daily backup scheduled at $(printf '%02d:00' "$(( 10#$hour ))") (retaining last $keep backups, log: $log_file)"
            ;;
        1)
            run "rm -f $cron_file $helper_script" || return 1
            success "Automated backup disabled"
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
    local domain="$1"
    require_running || return 1

    local host_cert="$INSTALL_DIR/cert/$domain/fullchain.pem"
    local host_key="$INSTALL_DIR/cert/$domain/privkey.pem"
    if ! run_q "test -f $(quote_sh "$host_cert") && test -f $(quote_sh "$host_key")"; then
        error "Cert or key missing in $INSTALL_DIR/cert/$domain/"
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
    success "TLS configured — restart panel to apply."
    confirm "Restart panel now?" && restart_panel || true
}

cert_issue() {
    echo ""
    local domain email
    read -rp "  Domain: " domain
    if ! validate_domain "$domain"; then
        error "Invalid domain name: $domain"
        return 1
    fi

    read -rp "  Email for Let's Encrypt notices [blank to skip]: " email
    local email_args
    if [[ -n "$email" ]]; then
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
    if is_running; then
        was_running=true
        warn "Panel will be briefly stopped so certbot can bind port 80."
        confirm "Continue?" || return 0
        compose stop || { error "Could not stop panel"; return 1; }
    fi

    info "Requesting cert for $domain (port 80 must be publicly reachable)..."
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
        compose up -d && success "Panel restarted" || warn "Panel restart failed"
        invalidate_status
    fi

    if $issued && is_running; then
        apply_panel_cert "$domain" || true
    fi
}

cert_renew() {
    if ! run_q "command -v certbot"; then
        error "certbot not installed — issue a cert first"
        return 1
    fi

    local was_running=false
    if is_running; then
        if confirm "Stop panel briefly during renewal so standalone challenge can bind port 80?"; then
            was_running=true
            compose stop || { error "Could not stop panel"; return 1; }
        fi
    fi

    info "Renewing all certbot certificates..."
    local rc=0
    run "certbot renew" || rc=1

    install_certbot_deploy_hook || true
    info "Syncing certificates into $INSTALL_DIR/cert/..."
    sync_letsencrypt_certs || true

    if $was_running; then
        compose up -d && success "Panel restarted" || warn "Panel restart failed"
        invalidate_status
    elif is_running; then
        confirm "Restart panel to load renewed certificates?" && restart_panel || true
    fi
    if is_caddy_running; then
        _caddy_reload || true
    fi

    (( rc == 0 )) && success "Renewal & sync complete" || error "Renewal encountered errors — check certbot logs"
}

cert_self_signed() {
    require_deployed || return 1
    if ! run_q "command -v openssl"; then
        error "openssl not found on target system"
        return 1
    fi

    echo ""
    local default_host
    default_host=$(get_target_ip)
    local host
    read -rp "  Domain or IP for certificate [${default_host}]: " host
    host="${host:-$default_host}"
    if ! validate_domain_or_ip "$host"; then
        error "Invalid domain or IP address: $host"
        return 1
    fi

    local san_entry="DNS:${host}"
    ( validate_ipv4 "$host" || validate_ipv6 "$host" ) && san_entry="IP:${host}"

    local dest="$INSTALL_DIR/cert/$host"
    info "Generating 10-year ECDSA P-256 self-signed certificate for $host..."

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
openssl req -new -x509 -sha256 -days 3650 -key $(quote_sh "$dest/privkey.pem") -out $(quote_sh "$dest/fullchain.pem") -config "\$cfg"
chmod 644 $(quote_sh "$dest/fullchain.pem")
chmod 600 $(quote_sh "$dest/privkey.pem")
EOF
)
    run "$gen_cmd" || { error "Certificate generation failed"; return 1; }
    success "Self-signed certificate saved to $dest"

    if is_running; then
        apply_panel_cert "$host" || true
    fi
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
            4)
                echo ""
                if run_q "test -d $(quote_sh "$INSTALL_DIR/cert")"; then
                    run "find $(quote_sh "$INSTALL_DIR/cert") \\( -name '*.pem' -o -name '*.crt' -o -name '*.key' \\) 2>/dev/null || echo '  (none)'" || true
                else
                    echo "  (cert directory does not exist)"
                fi
                ;;
            5|255) _SKIP_PAUSE=true; return ;;
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
        wireguard|hysteria|hysteria2|tuic)
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
    if _is_postgres_backend; then
        is_pg_running || return 0
        get_pg_env
        local sql="SELECT id, enable, protocol, COALESCE(NULLIF(listen,''), '0.0.0.0'), port, regexp_replace(COALESCE(remark,''), E'[\\r\\n\\t]+', ' ', 'g'), regexp_replace(COALESCE(stream_settings,''), E'[\\r\\n\\t]+', ' ', 'g') FROM inbounds ORDER BY id;"
        raw_rows=$(run_out "docker exec 3xui_postgres psql -U $(quote_sh "$PG_USER") -d $(quote_sh "$PG_DB") -F \$'\t' -tA -c $(quote_sh "$sql")" || true)
    else
        local sql="SELECT id, enable, protocol, COALESCE(NULLIF(listen,''), '0.0.0.0'), port, replace(replace(replace(COALESCE(remark,''), char(10), ' '), char(13), ''), char(9), ' '), replace(replace(replace(COALESCE(stream_settings,''), char(10), ' '), char(13), ''), char(9), ' ') FROM inbounds ORDER BY id;"
        if is_running && ensure_sqlite_in_container; then
            raw_rows=$(run_out "docker exec 3xui_app sqlite3 -cmd '.timeout 5000' -separator \$'\t' /etc/x-ui/x-ui.db $(quote_sh "$sql")" || true)
        elif run_q "command -v sqlite3 && test -f $(quote_sh "$INSTALL_DIR/db/x-ui.db")"; then
            raw_rows=$(run_out "sqlite3 -cmd '.timeout 5000' -separator \$'\t' $(quote_sh "$INSTALL_DIR/db/x-ui.db") $(quote_sh "$sql")" || true)
        fi
    fi
    _format_inbound_rows "$raw_rows"
}

_collect_caddy_inbound_blocks() {
    local panel_path="${1:-/}" sub_path="${2:-/sub/}" sub_json_path="${3:-/json/}"
    local p_base="${panel_path%/}" s_base="${sub_path%/}" j_base="${sub_json_path%/}"
    local inbounds="${INBOUNDS_OVERRIDE:-}"
    [[ -z "$inbounds" ]] && inbounds=$(get_xui_inbounds || true)
    [[ -z "$inbounds" ]] && return 0

    local seen_paths="|${p_base}|${s_base}|${j_base}|"
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

generate_decoy_site() {
    local force="${1:-false}"
    local site_dir="$INSTALL_DIR/caddy/site"
    local index_file="$site_dir/index.html"

    run "mkdir -p $(quote_sh "$site_dir") && chmod 755 $(quote_sh "$site_dir")" || return 1
    if [[ "$force" != "true" ]] && run_q "test -f $(quote_sh "$index_file")"; then
        return 0
    fi

    local html
    html=$(cat <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Service Status Portal</title>
  <style>
    :root { color-scheme: dark; }
    body {
      margin: 0; font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
      background: #0f172a; color: #e2e8f0; display: grid; place-items: center; min-height: 100vh;
    }
    .card {
      max-width: 460px; padding: 2rem; border-radius: 12px;
      background: #1e293b; border: 1px solid #334155; box-shadow: 0 12px 30px rgba(0,0,0,.35);
    }
    h1 { margin: 0 0 .5rem; font-size: 1.25rem; font-weight: 600; }
    p { margin: 0 0 1.25rem; color: #94a3b8; font-size: .95rem; line-height: 1.5; }
    .badge {
      display: inline-flex; align-items: center; gap: .5rem;
      font-size: .85rem; color: #34d399; background: rgba(16,185,129,.12);
      padding: .35rem .75rem; border-radius: 999px;
    }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: #34d399; }
  </style>
</head>
<body>
  <main class="card">
    <h1>Service Status Portal</h1>
    <p>All core platform systems are operating normally. Scheduled maintenance windows are announced in advance.</p>
    <span class="badge"><span class="dot"></span>Operational</span>
  </main>
</body>
</html>
HTML
)
    if $REMOTE; then
        printf '%s\n' "$html" | ssh_cmd "cat > $(quote_sh "$index_file") && chmod 644 $(quote_sh "$index_file")"
    else
        printf '%s\n' "$html" > "$index_file"
        chmod 644 "$index_file"
    fi
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

    local base_no_slash="${panel_path%/}"
    [[ -z "$base_no_slash" ]] && base_no_slash="/"

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

    local same_sub_block=""
    if [[ "$sub_mode" == "same" ]]; then
        same_sub_block=$(_caddy_sub_routes "$sub_no_slash" "$sub_json_no_slash" "$sub_port")
    fi

    local dedicated_sub_block=""
    if [[ "$sub_mode" == "dedicated" && -n "$sub_domain" ]]; then
        local sub_addr="$sub_domain"
        [[ "$https_port" != "443" ]] && sub_addr="${sub_domain}:${https_port}"
        local sub_tls=""
        sub_tls=$(_caddy_tls_block "$sub_domain" "$https_port" "$use_existing_sub_cert")
        local sub_routes=""
        sub_routes=$(_caddy_sub_routes "$sub_no_slash" "$sub_json_no_slash" "$sub_port")
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
    }${sub_routes}

    handle {
        root * /srv/site
        @decoy_root path / /index.html
        rewrite @decoy_root /index.html
        header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"
        file_server
    }
}
EOF
)
    fi

    local caddy_inbound_blocks=""
    caddy_inbound_blocks=$(_collect_caddy_inbound_blocks "$panel_path" "$sub_path" "$sub_json_path" || true)

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
    )

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
    }${same_sub_block}${caddy_inbound_blocks}

    handle {
        root * /srv/site
        @decoy_root path / /index.html
        rewrite @decoy_root /index.html
        header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"
        file_server
    }
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

    info "Generating decoy site, Caddyfile, and updating compose.yaml..."
    generate_decoy_site false || return 1
    generate_caddyfile "$panel_domain" "$https_port" "$acme_email" "$PANEL_PORT" "$panel_path" \
        "$sub_mode" "$sub_domain" "$sub_port" "$sub_path" "$sub_json_path" \
        "$use_existing_panel_cert" "$use_existing_sub_cert" || return 1
    save_proxy_conf || return 1
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

    invalidate_status
    verify_panel_loaded 12 || true
    if [[ "$sub_mode" != "none" ]]; then
        verify_subscription_endpoint 8 || true
    fi
    echo ""
    success "Caddy reverse proxy is active!"
    echo -e "  Panel URL : ${BOLD}${ext_panel_url}${NC}"
    echo -e "  Decoy URL : ${BOLD}https://${panel_domain}${port_sfx}/${NC}"
    [[ -n "$ext_sub_url" ]] && echo -e "  Sub URL   : ${BOLD}${ext_sub_url}${NC}"
    echo -e "  ${DIM}Ensure DNS points to this server and firewall allows 80/tcp + ${https_port}/tcp+udp.${NC}"
}

status_reverse_proxy() {
    load_proxy_conf
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
    echo -e "  Decoy Root    : https://${PROXY_DOMAIN}${port_sfx}/"
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
    local index_file="$INSTALL_DIR/caddy/site/index.html"

    tui_select "Camouflage Decoy Site" "File: $index_file" \
        "Edit index.html interactively (nano / vi)" \
        "Upload custom local HTML file" \
        "Reset to default built-in status page" \
        "Back"
    local sel=$?
    clear_screen

    case "$sel" in
        0)
            generate_decoy_site false || return 1
            if run_q "command -v nano || command -v vi"; then
                run_it "ed=\$(command -v nano || command -v vi); \"\$ed\" $(quote_sh "$index_file")"
                success "Edited $index_file"
            else
                error "Neither nano nor vi is installed on the target host"
            fi
            ;;
        1)
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
        2)
            generate_decoy_site true && success "Decoy page reset to default"
            ;;
        3|255) return 0 ;;
    esac
}

disable_reverse_proxy() {
    require_deployed || return 1
    get_panel_info || true

    confirm "Stop Caddy reverse proxy and revert 3X-UI to direct access (0.0.0.0)?" || { info "Cancelled"; return 0; }

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
    success "Reverse proxy disabled; 3X-UI restored to direct access."
}

manage_reverse_proxy() {
    require_deployed || return 1

    while true; do
        load_proxy_conf
        local proxy_state="${DIM}not configured${NC}"
        if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]]; then
            if is_caddy_running; then
                proxy_state="${GREEN}active${NC} (${PROXY_DOMAIN}:${PROXY_PORT})"
            else
                proxy_state="${YELLOW}configured, stopped${NC} (${PROXY_DOMAIN}:${PROXY_PORT})"
            fi
        fi

        local header_text="  Proxy Status : ${proxy_state}\n  Sub Mode     : ${SUB_MODE}\n  Config Dir   : $INSTALL_DIR/caddy/"

        local opts=(
            "Setup / Reconfigure Caddy reverse proxy"
            "Reverse proxy status & URLs"
            "Verify panel, subscription & DNS routing"
            "Customize decoy site (index.html)"
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
            3) customize_decoy_site ;;
            4) run "docker logs --tail=100 3xui_caddy 2>/dev/null || echo '  (3xui_caddy not running)'" || true ;;
            5) reload_reverse_proxy ;;
            6) disable_reverse_proxy ;;
            7|255) _SKIP_PAUSE=true; return ;;
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
    run_it "$(_xui_setting_cmd -show=true) 2>/dev/null || echo 'x-ui CLI unavailable'"

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

    local scope="${1:-}"
    if [[ -z "$scope" ]]; then
        tui_select "Update GeoIP / GeoSite Assets" "Downloads latest routing .dat files into 3xui_app:/app/bin/:" \
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
    run_q "chmod 700 $(quote_sh "$tmp_dir")" || true

    local pair fname url ok=0
    for pair in "${pairs[@]}"; do
        fname="${pair%%|*}"
        url="${pair#*|}"
        info "Downloading $fname..."
        if run "curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 $(quote_sh "$url") -o $(quote_sh "$tmp_dir/$fname") && [ \$(wc -c < $(quote_sh "$tmp_dir/$fname")) -gt 10240 ] && docker cp $(quote_sh "$tmp_dir/$fname") $(quote_sh "3xui_app:/app/bin/$fname")"; then
            ok=$(( ok + 1 ))
        else
            warn "Failed to update $fname"
        fi
    done

    run_q "rm -rf $(quote_sh "$tmp_dir")" || true

    if (( ok > 0 )); then
        info "Restarting container so Xray reloads geo databases..."
        compose restart >/dev/null || docker restart 3xui_app >/dev/null || true
        success "Updated $ok/${#pairs[@]} geo-asset file(s)"
    else
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
3X-UI Manager (${REPO_URL})

Usage:
  ${prog} [OPTIONS] [COMMAND] [ARGS]

Options:
  -r, --remote <target>   Target remote VPS ([user@]host[:port], default user=root, port=22)
  -l, --local             Force local execution mode
  -d, --dir <path>        Override install directory (default: /opt/3x-ui)
  -y, --yes               Auto-confirm destructive or interactive confirmation prompts
  -h, --help              Show this help message

Commands (omit to launch interactive TUI):
  deploy                  Install Docker if needed and deploy 3X-UI
  status                  Show deployment and panel status
  start | stop | restart  Control container lifecycle
  update                  Update 3X-UI to latest GitHub release tag
  rollback                Rollback to compose.yaml.bak
  logs [follow|all|N]     View container logs (default: last 100 lines)
  backup                  Create timestamped backup archive
  restore [archive]       Restore from backup archive
  health                  Show system & panel diagnostics
  bbr                     Enable TCP BBR & proxy network sysctl tuning
  geo-update [std|ir|ru|all]  Update Xray GeoIP & GeoSite databases
  settings                Open Panel Settings & Security menu
  certs                   Open Certificate Management menu
  proxy [setup|status|verify|reload|disable]
                          Manage Caddy reverse proxy (HTTPS + decoy + subs)
  inbounds [list|verify|sync-proxy|sync-fw]
                          Inspect inbounds, verify sockets & sync Caddy/firewall
  audit                   Run security & configuration audit
  self-install            Install this manager globally as ${BIN_INSTALL_PATH}
  self-update             Update this manager script from GitHub main branch
  help                    Show this help message
EOF
}

_download_script_to() {
    local dst="$1"
    if command -v curl &>/dev/null; then
        curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "$REPO_RAW_URL" -o "$dst" || return 1
    elif command -v wget &>/dev/null; then
        wget -qO "$dst" --https-only --secure-protocol=TLSv1_2 --timeout=30 "$REPO_RAW_URL" || return 1
    else
        error "curl or wget is required to download from GitHub"
        return 1
    fi
    [[ -s "$dst" ]] || return 1
    head -n 1 "$dst" | grep -q '^#!/usr/bin/env bash' || return 1
    grep -q '# 3X-UI Manager' "$dst" || return 1
    bash -n "$dst" 2>/dev/null
}

self_install() {
    local tmp_script
    tmp_script=$(mktemp /tmp/3xui-install.XXXXXX.sh) || { error "Failed to create temp file"; return 1; }
    chmod 600 "$tmp_script" 2>/dev/null || true

    if [[ -f "${0:-}" && "$0" != /dev/fd/* && "$0" != /proc/* && "$0" != "bash" && "$0" != "-bash" ]] && grep -q '3X-UI Manager' "$0" 2>/dev/null; then
        cp "$0" "$tmp_script" || { rm -f "$tmp_script"; error "Failed to copy script"; return 1; }
        bash -n "$tmp_script" 2>/dev/null || { rm -f "$tmp_script"; error "Script syntax check failed"; return 1; }
    else
        info "Downloading latest manager script from GitHub..."
        if ! _download_script_to "$tmp_script"; then
            rm -f "$tmp_script"
            error "Download or validation failed"
            return 1
        fi
    fi

    if [[ $EUID -eq 0 ]]; then
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
    local tmp_script
    tmp_script=$(mktemp /tmp/3xui-update.XXXXXX.sh) || { error "Failed to create temp file"; return 1; }
    chmod 600 "$tmp_script" 2>/dev/null || true

    info "Downloading latest version from ${REPO_URL}..."
    if ! _download_script_to "$tmp_script"; then
        rm -f "$tmp_script"
        error "Failed to download or validate updated script"
        return 1
    fi

    local updated=false
    if [[ -f "${0:-}" && "$0" != /dev/fd/* && "$0" != /proc/* && "$0" != "bash" && "$0" != "-bash" ]]; then
        if [[ -w "$0" ]]; then
            install -m 0755 "$tmp_script" "$0" && updated=true
        elif [[ $EUID -ne 0 ]] && command -v sudo &>/dev/null; then
            sudo install -m 0755 "$tmp_script" "$0" && updated=true
        fi
    fi

    if [[ -e "$BIN_INSTALL_PATH" && "$(realpath "$BIN_INSTALL_PATH" 2>/dev/null || echo "$BIN_INSTALL_PATH")" != "$(realpath "${0:-}" 2>/dev/null || echo "")" ]]; then
        if [[ $EUID -eq 0 || -w "$BIN_INSTALL_PATH" ]]; then
            cp -a "$BIN_INSTALL_PATH" "${BIN_INSTALL_PATH}.bak" 2>/dev/null || true
            install -m 0755 "$tmp_script" "$BIN_INSTALL_PATH" && updated=true
        elif command -v sudo &>/dev/null; then
            sudo cp -a "$BIN_INSTALL_PATH" "${BIN_INSTALL_PATH}.bak" 2>/dev/null || true
            sudo install -m 0755 "$tmp_script" "$BIN_INSTALL_PATH" && updated=true
        fi
    fi

    if ! $updated; then
        if [[ $EUID -eq 0 ]]; then
            install -m 0755 "$tmp_script" "$BIN_INSTALL_PATH" && updated=true
        elif command -v sudo &>/dev/null; then
            sudo install -m 0755 "$tmp_script" "$BIN_INSTALL_PATH" && updated=true
        fi
    fi

    rm -f "$tmp_script"
    if $updated; then
        success "Updated manager script successfully! Re-run to use the new version."
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

    local cli_cmd="" cli_arg=""
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
                elif [[ -z "$cli_arg" ]]; then
                    cli_arg="$1"
                else
                    error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    validate_safe_dir "$INSTALL_DIR" || { error "Unsafe install directory: $INSTALL_DIR"; exit 1; }
    validate_safe_dir "$BACKUP_DIR"  || { error "Unsafe backup directory: $BACKUP_DIR"; exit 1; }

    # Non-interactive / direct CLI command path.
    if [[ -n "$cli_cmd" ]]; then
        case "$cli_cmd" in
            help)         usage; exit 0 ;;
            self-install) self_install; exit $? ;;
            self-update)  self_update; exit $? ;;
        esac

        if [[ "$cli_cmd" == "deploy" || "$cli_cmd" == "settings" || "$cli_cmd" == "certs" || "$cli_cmd" == "proxy" || "$cli_cmd" == "inbounds" ]]; then
            [[ ! -t 0 && -r /dev/tty ]] && exec < /dev/tty
        fi

        INTERACTIVE=false
        if $REMOTE; then
            init_master_connection || exit 1
        else
            ensure_local_privileges
        fi

        case "$cli_cmd" in
            deploy)       INTERACTIVE=true; deploy ;;
            status)       status_panel ;;
            start)        start_panel ;;
            stop)         stop_panel ;;
            restart)      restart_panel ;;
            update)       update_panel_latest ;;
            rollback)     rollback_version ;;
            logs)         logs_panel "${cli_arg:-100}" ;;
            backup)       backup_panel ;;
            restore)      restore_panel "$cli_arg" ;;
            health)       health_check ;;
            bbr)          enable_bbr_tuning ;;
            geo-update)   manage_geo_assets "${cli_arg:-std}" ;;
            settings)     INTERACTIVE=true; manage_panel_settings ;;
            certs)        INTERACTIVE=true; manage_certs ;;
            proxy)
                case "${cli_arg:-}" in
                    "")      INTERACTIVE=true; manage_reverse_proxy ;;
                    setup)   INTERACTIVE=true; setup_reverse_proxy ;;
                    status)  status_reverse_proxy ;;
                    verify)  verify_reverse_proxy ;;
                    reload)  reload_reverse_proxy ;;
                    disable) disable_reverse_proxy ;;
                    *)       error "Unknown proxy action: $cli_arg (use: setup|status|verify|reload|disable)"; exit 1 ;;
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
    [[ ! -t 0 && -r /dev/tty ]] && exec < /dev/tty

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
