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
PANEL_HAS_DEFAULT=""

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

validate_domain() {
    local d="${1-}"
    [[ ${#d} -le 253 && "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

validate_domain_or_ip() {
    local v="${1-}"
    validate_ipv4 "$v" || validate_domain "$v"
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
    [[ "$p" == *".."* ]] && return 1
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
    [[ "$p" == /* && "$p" != *$'\n'* && "$p" != *$'\r'* ]]
}

has_control_chars() {
    local s="${1-}"
    [[ "$s" == *$'\n'* || "$s" == *$'\r'* || "$s" == *$'\0'* ]]
}

generate_random_string() {
    local length="${1:-16}"
    local out=""
    # Use dd + cut (never head) so tr never trips SIGPIPE under set -o pipefail.
    out=$(dd if=/dev/urandom bs=2048 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"$length")
    if [[ ${#out} -lt $length ]]; then
        out="${out}$(dd if=/dev/urandom bs=2048 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"$(( length - ${#out} ))")"
    fi
    printf '%s' "$out"
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

get_target_ip() {
    if $REMOTE; then
        printf '%s' "$SSH_HOST"
        return 0
    fi
    local ip=""
    ip=$(get_ip)
    if [[ "$ip" == "127.0.0.1" ]] && command -v curl &>/dev/null; then
        local pub
        pub=$(curl -4fsS --max-time 2 https://api.ipify.org 2>/dev/null || true)
        validate_ipv4 "$pub" && ip="$pub"
    fi
    printf '%s' "$ip"
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
        -o ControlPersist=1h
        -o ConnectTimeout=10
        -o ServerAliveInterval=30
        -o ServerAliveCountMax=3
        -o StrictHostKeyChecking=accept-new
    )
    [[ -n "${SSH_KEY:-}" && -f "${SSH_KEY:-}" ]] && SSH_OPTS+=(-i "$SSH_KEY")
    [[ "${SSH_PORT:-22}" != "22" ]] && SSH_OPTS+=(-p "$SSH_PORT")
}

get_scp_opts() {
    SCP_OPTS=(
        -o ControlMaster=auto
        -o "ControlPath=$(get_mux_path)"
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new
    )
    [[ -n "${SSH_KEY:-}" && -f "${SSH_KEY:-}" ]] && SCP_OPTS+=(-i "$SSH_KEY")
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
load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
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
    local enc_pass=""
    if [[ -n "${SSH_PASS:-}" ]]; then
        enc_pass=$(printf '%s' "$SSH_PASS" | base64 | tr -d '\n\r')
    fi

    (
        umask 077
        printf 'SSH_HOST="%s"\nSSH_PORT="%s"\nSSH_USER="%s"\nSSH_KEY="%s"\nSSH_PASS_B64="%s"\n' \
            "${SSH_HOST//\"/}" "${SSH_PORT//\"/}" "${SSH_USER//\"/}" "${SSH_KEY//\"/}" "$enc_pass" > "$CONFIG_FILE"
    )
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
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
        ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" || { error "ssh-keygen failed"; return 1; }
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
        [[ -n "${SSH_PASS:-}" ]] && auth_mode="${auth_mode}, saved password"

        local header_text
        if $REMOTE; then
            header_text="  Mode      : ${BOLD}Remote${NC} (${SSH_USER}@${SSH_HOST}:${SSH_PORT})\n  Master Mux: ${mux_state}\n  Auth      : ${auth_mode}"
        else
            header_text="  Mode      : ${BOLD}Local${NC} (this machine)\n  Saved VPS : ${SSH_USER:-none}@${SSH_HOST:-none}:${SSH_PORT:-22}"
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
    run "cd $(quote_sh "$INSTALL_DIR") && $COMPOSE_CMD $*"
}

ensure_docker() {
    if run_q "command -v docker"; then
        success "Docker already installed"
    else
        info "Installing Docker via get.docker.com..."
        run "s=\$(mktemp /tmp/get-docker.XXXXXX.sh) && curl -fsSL https://get.docker.com -o \"\$s\" && sh \"\$s\"; rc=\$?; rm -f \"\$s\"; exit \$rc" \
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
    run "docker exec 3xui_app sh -c 'apk update >/dev/null 2>&1 && apk add --no-cache sqlite >/dev/null 2>&1'" \
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
            run_out "docker exec 3xui_app sqlite3 /etc/x-ui/x-ui.db $(quote_sh "$sql")" || true
        elif run_q "command -v sqlite3 && test -f $(quote_sh "$INSTALL_DIR/db/x-ui.db")"; then
            run_out "sqlite3 $(quote_sh "$INSTALL_DIR/db/x-ui.db") $(quote_sh "$sql")" || true
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
        run "docker exec 3xui_postgres psql -U $(quote_sh "$PG_USER") -d $(quote_sh "$PG_DB") -c $(quote_sh "$sql") >/dev/null"
    else
        local sql="UPDATE settings SET value='${val_sql}' WHERE key='${key}'; INSERT INTO settings (key, value) SELECT '${key}', '${val_sql}' WHERE (SELECT changes()) = 0;"
        if is_running && ensure_sqlite_in_container; then
            run "docker exec 3xui_app sqlite3 /etc/x-ui/x-ui.db $(quote_sh "$sql")"
        elif run_q "command -v sqlite3 && test -f $(quote_sh "$INSTALL_DIR/db/x-ui.db")"; then
            run "sqlite3 $(quote_sh "$INSTALL_DIR/db/x-ui.db") $(quote_sh "$sql")"
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

    run "mkdir -p $(quote_sh "$INSTALL_DIR/caddy") && chmod 700 $(quote_sh "$INSTALL_DIR/caddy")" || return 1
    if $REMOTE; then
        printf '%s' "$conf_body" | ssh_cmd "umask 077 && cat > $(quote_sh "$INSTALL_DIR/caddy/proxy.conf") && chmod 600 $(quote_sh "$INSTALL_DIR/caddy/proxy.conf")"
    else
        ( umask 077; printf '%s' "$conf_body" > "$INSTALL_DIR/caddy/proxy.conf" )
        chmod 600 "$INSTALL_DIR/caddy/proxy.conf"
    fi
}

# ─── Panel Introspection & Settings ─────────────────────────────────────────
get_panel_info() {
    PANEL_PORT="2053"
    PANEL_PATH="/"
    PANEL_USER="admin"
    PANEL_PROTO="http"
    PANEL_LISTEN=""
    PANEL_HAS_DEFAULT=""

    load_proxy_conf

    is_running || return 1
    local out cert_out listen_out
    out=$(run_out "docker exec 3xui_app x-ui setting -show=true" || true)
    if [[ -n "$out" ]]; then
        local val
        val=$(printf '%s\n' "$out" | awk -F': *' '/^[[:space:]]*port:/ {print $2; exit}' | tr -d '\r')
        validate_port "$val" && PANEL_PORT="$val"

        val=$(printf '%s\n' "$out" | awk -F': *' '/^[[:space:]]*webBasePath:/ {print $2; exit}' | tr -d '\r')
        if [[ -n "$val" ]]; then
            [[ "$val" != /* ]] && val="/$val"
            PANEL_PATH="$val"
        fi

        val=$(printf '%s\n' "$out" | awk -F': *' '/^[[:space:]]*username:/ {print $2; exit}' | tr -d '\r')
        [[ -n "$val" ]] && PANEL_USER="$val"

        val=$(printf '%s\n' "$out" | awk -F': *' '/^[[:space:]]*hasDefaultCredential:/ {print $2; exit}' | tr -d '\r')
        PANEL_HAS_DEFAULT="$val"
    fi

    listen_out=$(run_out "docker exec 3xui_app x-ui setting -getListen=true" || true)
    if [[ -n "$listen_out" ]]; then
        PANEL_LISTEN=$(printf '%s\n' "$listen_out" | awk -F': *' '/(listen|IP)/ {print $2; exit}' | tr -d '\r ')
    fi

    cert_out=$(run_out "docker exec 3xui_app x-ui setting -getCert=true" || true)
    if [[ -n "$cert_out" ]]; then
        local cert_line
        cert_line=$(printf '%s\n' "$cert_out" | awk -F': *' '/(cert|webCertFile)/ {print $2; exit}' | tr -d '\r ')
        if [[ -n "$cert_line" && "$cert_line" != "none" && "$cert_line" != "<nil>" ]]; then
            PANEL_PROTO="https"
        fi
    fi

    if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]] && [[ "$SUB_MODE" != "none" ]]; then
        local port_sfx="" sub_host="$PROXY_DOMAIN"
        [[ "$PROXY_PORT" != "443" ]] && port_sfx=":${PROXY_PORT}"
        [[ "$SUB_MODE" == "dedicated" && -n "$SUB_DOMAIN" ]] && sub_host="$SUB_DOMAIN"
        PROXY_SUB_URL="https://${sub_host}${port_sfx}${SUB_PATH}"
    fi
}

format_panel_url() {
    local ip="$1"
    local path="$PANEL_PATH"
    [[ "$path" != /* ]] && path="/$path"
    if $PROXY_ENABLED && [[ -n "$PROXY_DOMAIN" ]] && is_caddy_running; then
        local port_sfx=""
        [[ "$PROXY_PORT" != "443" ]] && port_sfx=":${PROXY_PORT}"
        printf 'https://%s%s%s' "$PROXY_DOMAIN" "$port_sfx" "$path"
        return 0
    fi
    printf '%s://%s:%s%s' "$PANEL_PROTO" "$ip" "$PANEL_PORT" "$path"
}

reset_credentials() {
    require_deployed || return 1
    require_running  || return 1

    echo ""
    local new_user new_pass auto_pass=false
    read -rp "  New username [admin]: " new_user
    new_user="${new_user:-admin}"
    if has_control_chars "$new_user"; then
        error "Invalid characters in username"
        return 1
    fi

    read -rs -p "  New password [Enter to auto-generate strong password]: " new_pass
    echo ""
    if [[ -z "$new_pass" ]]; then
        new_pass=$(generate_random_string 16)
        auto_pass=true
    elif has_control_chars "$new_pass"; then
        error "Invalid control characters in password"
        return 1
    fi

    run_masked "Update credentials" \
        "docker exec 3xui_app x-ui setting -username $(quote_sh "$new_user") -password $(quote_sh "$new_pass")" \
        || return 1
    success "Credentials updated (username: $new_user)"
    $auto_pass && echo -e "  Generated password: ${BOLD}${YELLOW}${new_pass}${NC}  (save this now!)"
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
        run "docker exec 3xui_caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1" \
            && success "Synced & reloaded Caddy reverse proxy" || warn "Failed to reload Caddy"
    fi
}

change_panel_port() {
    require_running || return 1
    get_panel_info
    echo ""
    echo -e "  Current port: ${BOLD}${PANEL_PORT}${NC}"
    local new_port
    read -rp "  New panel port (1-65535): " new_port
    if ! validate_port "$new_port"; then
        error "Invalid port: $new_port"
        return 1
    fi
    run "docker exec 3xui_app x-ui setting -port $(quote_sh "$new_port")" || return 1
    success "Panel port updated to $new_port (restart required to take effect)"
    _sync_caddy_if_active "$new_port" "$PANEL_PATH"
    confirm "Restart panel now?" && restart_panel || true
}

change_panel_webpath() {
    require_running || return 1
    get_panel_info
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
        error "Invalid path (allowed: alphanumeric, '/', '_', '-')"
        return 1
    fi
    if $PROXY_ENABLED && [[ "$new_path" == "/" ]]; then
        error "Web Base Path cannot be '/' while Caddy camouflage site is active"
        return 1
    fi
    run "docker exec 3xui_app x-ui setting -webBasePath $(quote_sh "$new_path")" || return 1
    success "Web Base Path set to ${BOLD}${new_path}${NC}"
    _sync_caddy_if_active "$PANEL_PORT" "$new_path"
    confirm "Restart panel now?" && restart_panel || true
}

reset_panel_2fa() {
    require_running || return 1
    confirm "Disable / reset Two-Factor Authentication (2FA) for admin?" || return 0
    run "docker exec 3xui_app x-ui setting -resetTwoFactor=true" || return 1
    success "Two-Factor Authentication reset"
    confirm "Restart panel now?" && restart_panel || true
}

manage_panel_settings() {
    require_deployed || return 1
    require_running  || return 1

    while true; do
        get_panel_info
        local ip
        ip=$(get_target_ip)
        local url
        url=$(format_panel_url "$ip")

        local header_text="  Panel URL : ${BOLD}${url}${NC}\n  Username  : ${BOLD}${PANEL_USER}${NC}"
        if [[ "$PANEL_HAS_DEFAULT" == "true" ]]; then
            header_text+="\n  ${YELLOW}! Default credentials detected — change them!${NC}"
        fi

        local opts=(
            "Show full panel settings"
            "Change panel port"
            "Change / randomize Web Base Path"
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
                run_it "docker exec 3xui_app x-ui setting -show=true"
                echo ""
                run_it "docker exec 3xui_app x-ui setting -getCert=true"
                echo ""
                echo -e "  Effective URL: ${BOLD}${url}${NC}"
                ;;
            1) change_panel_port ;;
            2) change_panel_webpath ;;
            3) reset_credentials ;;
            4) reset_panel_2fa ;;
            5|255) _SKIP_PAUSE=true; return ;;
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
        effective_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 10 "$releases_url" 2>/dev/null || true)
        if [[ "$effective_url" == */releases/tag/* ]]; then
            tag="${effective_url##*/}"
        fi
        if [[ -z "$tag" ]]; then
            tag=$(curl -fsSL --max-time 10 "$api_url" 2>/dev/null \
                | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
        fi
    elif command -v wget &>/dev/null; then
        tag=$(wget -qO- --timeout=10 "$api_url" 2>/dev/null \
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
        env_content=$(printf 'POSTGRES_USER=%s\nPOSTGRES_PASSWORD=%s\nPOSTGRES_DB=xui\n' "$pg_user" "$pg_pass")
        xui_db_env="
      XUI_DB_TYPE: \"postgres\"
      XUI_DB_DSN: \"postgres://${pg_user}:${enc_pass}@127.0.0.1:5432/xui?sslmode=disable\""
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
    volumes:
      - \$PWD/db/:/etc/x-ui/
      - \$PWD/cert/:/root/cert/
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
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

    run "cp $q_cfg $q_bak" || { error "Failed to backup compose.yaml"; return 1; }

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
    for (( i=0; i<10; i++ )); do
        if run_q "docker exec 3xui_app x-ui setting -show=true"; then
            wait_ok=true
            break
        fi
        sleep 1
    done
    $wait_ok || { warn "Container still initializing; use 'Panel settings & security' later to harden."; return 0; }

    echo ""
    confirm "Harden panel now? (customize port, Web Base Path, and admin credentials)" || return 0

    local h_port h_path h_user h_pass auto_pass=false
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
    has_control_chars "$h_user" && h_user="admin"

    read -rs -p "  Admin password [Enter to auto-generate 16-char password]: " h_pass
    echo ""
    if [[ -z "$h_pass" ]] || has_control_chars "$h_pass"; then
        h_pass=$(generate_random_string 16)
        auto_pass=true
    fi

    run_masked "Apply hardening settings" \
        "docker exec 3xui_app x-ui setting -port $(quote_sh "$h_port") -webBasePath $(quote_sh "$h_path") -username $(quote_sh "$h_user") -password $(quote_sh "$h_pass")" \
        || { warn "Could not apply settings automatically"; return 0; }

    info "Restarting container to apply hardened settings..."
    compose restart >/dev/null || true
    sleep 1

    echo ""
    success "Panel hardened!"
    echo -e "  Username : ${BOLD}${h_user}${NC}"
    if $auto_pass; then
        echo -e "  Password : ${BOLD}${YELLOW}${h_pass}${NC}  (save this now!)"
    else
        echo -e "  Password : ${BOLD}(as entered)${NC}"
    fi
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
    generate_compose "$db_type" "$latest_tag" "$pg_user" "$pg_pass" || { error "Failed to generate compose.yaml"; return 1; }

    info "Pulling images..."
    compose pull || { error "Image pull failed"; return 1; }

    info "Starting containers..."
    compose up -d || { error "Container start failed"; return 1; }

    $INTERACTIVE && post_deploy_harden
    if $INTERACTIVE && is_running; then
        echo ""
        confirm "Set up Caddy reverse proxy now? (custom domain + HTTPS + camouflage + subs)" && setup_reverse_proxy || true
    fi

    get_panel_info || true
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
    echo -e "  Panel URL : ${BOLD}$url${NC}"
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
            confirm "Delete ALL data at $INSTALL_DIR? Irreversible!" || { info "Cancelled"; return 0; }
            run "cd $(quote_sh "$INSTALL_DIR") && $COMPOSE_CMD down -v 2>/dev/null || true"
            run "rm -rf $(quote_sh "$INSTALL_DIR")"
            invalidate_status
            success "Everything removed"
            ;;
        2|255) info "Cancelled" ;;
    esac
}

start_panel()   { require_deployed || return 1; compose up -d   || return 1; invalidate_status; success "Started"; }
stop_panel()    { require_deployed || return 1; compose stop    || return 1; invalidate_status; success "Stopped"; }
restart_panel() { require_deployed || return 1; compose restart || return 1; invalidate_status; success "Restarted"; }

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
            echo -e "  Proxy   : ${GREEN}Caddy Active${NC} (backend ${PANEL_LISTEN:-127.0.0.1}:${PANEL_PORT})"
            [[ -n "$PROXY_SUB_URL" ]] && echo -e "  Subs    : ${BOLD}${PROXY_SUB_URL}${NC}"
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
        info "Lazydocker not found. Installing..."
        run "curl -fsSL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | DIR=/usr/local/bin bash" \
            || { error "Failed to install lazydocker"; return 1; }
        success "Lazydocker installed."
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
            docker exec 3xui_app sqlite3 /etc/x-ui/x-ui.db ".backup '/etc/x-ui/.x-ui.db.backup'" 2>/dev/null || true
            if [ -f $q_inst/db/.x-ui.db.backup ]; then
                mv -f $q_inst/db/.x-ui.db.backup $q_stage/db/x-ui.db
                rm -f $q_stage/db/x-ui.db-wal $q_stage/db/x-ui.db-shm
            fi
        fi
    elif command -v sqlite3 >/dev/null 2>&1 && [ -f $q_inst/db/x-ui.db ]; then
        sqlite3 $q_inst/db/x-ui.db ".backup '$stage_parent/$stage_name/db/x-ui.db'" 2>/dev/null || true
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
            mkdir -p "$local_dir"
            ssh_download "$LAST_BACKUP_ARCHIVE" "$local_dir/" \
                && success "Downloaded to $local_dir/$(basename "$LAST_BACKUP_ARCHIVE")" \
                || warn "Download failed"
        fi
    fi

    echo -e "\n  ${BOLD}Existing Backups:${NC}"
    run "ls -lh $(quote_sh "$BACKUP_DIR")/*.tar.gz 2>/dev/null || echo '  (none)'" || true
}

_list_backups() {
    run_out "ls -1t $(quote_sh "$BACKUP_DIR")/*.tar.gz 2>/dev/null" || true
}

restore_panel() {
    local chosen="${1:-}"

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
                    local remote_tmp
                    remote_tmp=$(run_out "mktemp /tmp/3xui-upload.XXXXXX.tar.gz")
                    [[ -z "$remote_tmp" ]] && { error "Failed to allocate remote temp path"; return 1; }
                    info "Uploading backup to remote host..."
                    if ! ssh_copy "$local_file" "$remote_tmp"; then
                        run_q "rm -f $(quote_sh "$remote_tmp")"
                        error "Upload failed"
                        return 1
                    fi
                    chosen="$remote_tmp"
                    local _cleanup_uploaded="$remote_tmp"
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

    if ! run_q "test -f $(quote_sh "$chosen") && tar -tzf $(quote_sh "$chosen") >/dev/null 2>&1"; then
        [[ -n "${_cleanup_uploaded:-}" ]] && run_q "rm -f $(quote_sh "$_cleanup_uploaded")"
        error "Invalid or unreadable backup archive: $chosen"
        return 1
    fi

    confirm "Restore $(basename "$chosen") into $INSTALL_DIR (replaces active data)?" || {
        [[ -n "${_cleanup_uploaded:-}" ]] && run_q "rm -f $(quote_sh "$_cleanup_uploaded")"
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
        [[ -n "${_cleanup_uploaded:-}" ]] && run_q "rm -f $(quote_sh "$_cleanup_uploaded")"
        error "Failed to create secure temp directory"
        return 1
    fi

    info "Restoring $(basename "$chosen")..."
    local restore_script
    restore_script=$(cat <<EOF
set -e
chmod 700 $(quote_sh "$tmp_dir")
tar -xzf $(quote_sh "$chosen") -C $(quote_sh "$tmp_dir")

src=$(quote_sh "$tmp_dir")
if [ ! -d "\$src/db" ] && [ ! -f "\$src/compose.yaml" ]; then
    sub=\$(find "\$src" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    [ -n "\$sub" ] && src="\$sub"
fi

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
fi
if [ -d "\$src/caddy" ]; then
    rm -rf $(quote_sh "$INSTALL_DIR/caddy")
    cp -a "\$src/caddy" $(quote_sh "$INSTALL_DIR/caddy")
    chmod 755 $(quote_sh "$INSTALL_DIR/caddy")
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
elif [ -f "\$src/postgres_dump.sql" ]; then
    cp -a "\$src/postgres_dump.sql" $(quote_sh "$INSTALL_DIR/.restore_dump.sql")
    chmod 600 $(quote_sh "$INSTALL_DIR/.restore_dump.sql")
fi
EOF
)

    local rc=0
    run "$restore_script" || rc=1
    run_q "rm -rf $(quote_sh "$tmp_dir")" || true
    [[ -n "${_cleanup_uploaded:-}" ]] && run_q "rm -f $(quote_sh "$_cleanup_uploaded")" || true

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
                    run "docker exec -i 3xui_postgres psql -U $(quote_sh "$PG_USER") -d $(quote_sh "$PG_DB") < $(quote_sh "$INSTALL_DIR/.restore_dump.sql") >/dev/null" \
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
                printf '%s\n' "$script_body" | ssh_cmd "cat > $helper_script && chmod 700 $helper_script"
            else
                printf '%s\n' "$script_body" > "$helper_script"
                chmod 700 "$helper_script"
            fi

            local cron_line="0 $(( 10#$hour )) * * * root $helper_script >/dev/null 2>&1"
            run "printf '%s\n' $(quote_sh "$cron_line") > $cron_file && chmod 644 $cron_file" || return 1
            success "Daily backup scheduled at $(printf '%02d:00' "$(( 10#$hour ))") (retaining last $keep backups)"
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
INSTALL_DIR=$(quote_sh "$INSTALL_DIR")
if [ -n "\${RENEWED_DOMAINS:-}" ] && [ -n "\${RENEWED_LINEAGE:-}" ]; then
    for domain in \$RENEWED_DOMAINS; do
        dest="\$INSTALL_DIR/cert/\$domain"
        mkdir -p "\$dest"
        cp -L "\$RENEWED_LINEAGE/fullchain.pem" "\$dest/fullchain.pem"
        cp -L "\$RENEWED_LINEAGE/privkey.pem" "\$dest/privkey.pem"
        chmod 644 "\$dest/fullchain.pem"
        chmod 600 "\$dest/privkey.pem"
    done
    docker restart 3xui_app >/dev/null 2>&1 || true
fi
EOF
)
    run "mkdir -p $hook_dir" || return 1
    if $REMOTE; then
        printf '%s\n' "$hook_body" | ssh_cmd "cat > $hook_file && chmod 755 $hook_file"
    else
        printf '%s\n' "$hook_body" > "$hook_file"
        chmod 755 "$hook_file"
    fi
}

sync_letsencrypt_certs() {
    local sync_cmd
    sync_cmd=$(cat <<EOF
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

    run "docker exec 3xui_app x-ui setting -webCert $(quote_sh "$cert_path") -webCertKey $(quote_sh "$key_path")" \
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
        run "mkdir -p $(quote_sh "$dest") && chmod 700 $(quote_sh "$INSTALL_DIR/cert")"
        run "cp -L $(quote_sh "/etc/letsencrypt/live/$domain/fullchain.pem") $(quote_sh "$dest/fullchain.pem") && chmod 644 $(quote_sh "$dest/fullchain.pem")" || warn "Could not copy fullchain"
        run "cp -L $(quote_sh "/etc/letsencrypt/live/$domain/privkey.pem") $(quote_sh "$dest/privkey.pem") && chmod 600 $(quote_sh "$dest/privkey.pem")" || warn "Could not copy privkey"
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
        error "Invalid domain or IPv4 address: $host"
        return 1
    fi

    local san_entry="DNS:${host}"
    validate_ipv4 "$host" && san_entry="IP:${host}"

    local dest="$INSTALL_DIR/cert/$host"
    info "Generating 10-year ECDSA P-256 self-signed certificate for $host..."

    local gen_cmd
    gen_cmd=$(cat <<EOF
set -e
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
subjectAltName = $san_entry
CFG
openssl ecparam -name prime256v1 -genkey -noout -out $(quote_sh "$dest/privkey.pem")
openssl req -new -x509 -days 3650 -key $(quote_sh "$dest/privkey.pem") -out $(quote_sh "$dest/fullchain.pem") -config "\$cfg"
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

# ─── Reverse Proxy (Caddy) ──────────────────────────────────────────────────
inject_caddy_compose() {
    local cfg="$INSTALL_DIR/compose.yaml"
    local q_cfg q_tmp
    q_cfg=$(quote_sh "$cfg")
    q_tmp=$(quote_sh "${cfg}.tmp")

    run_q "grep -qE '^  caddy:' $q_cfg" && return 0

    local block
    block=$(_caddy_service_block)
    local cur_yaml new_yaml
    cur_yaml=$(run_out "cat $q_cfg") || return 1
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
  <title>Edge Telemetry &amp; Status</title>
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
    <h1>Edge Relay Node</h1>
    <p>Automated routing and health probe endpoint. Authorized administrative endpoints require a valid session path.</p>
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

    local global_opts=""
    if [[ -n "$acme_email" ]]; then
        printf -v global_opts '{\n    email %s\n}\n\n' "$acme_email"
    fi

    local panel_addr="$panel_domain"
    [[ "$https_port" != "443" ]] && panel_addr="${panel_domain}:${https_port}"

    local panel_tls=""
    panel_tls=$(_caddy_tls_block "$panel_domain" "$https_port" "$use_existing_panel_cert")

    local same_sub_block=""
    if [[ "$sub_mode" == "same" ]]; then
        same_sub_block=$(cat <<EOF

    @sub {
        path ${sub_no_slash} ${sub_no_slash}/*
    }
    handle @sub {
        reverse_proxy 127.0.0.1:${sub_port}
    }

    @subjson {
        path ${sub_json_no_slash} ${sub_json_no_slash}/*
    }
    handle @subjson {
        reverse_proxy 127.0.0.1:${sub_port}
    }
EOF
)
    fi

    local dedicated_sub_block=""
    if [[ "$sub_mode" == "dedicated" && -n "$sub_domain" ]]; then
        local sub_addr="$sub_domain"
        [[ "$https_port" != "443" ]] && sub_addr="${sub_domain}:${https_port}"
        local sub_tls=""
        sub_tls=$(_caddy_tls_block "$sub_domain" "$https_port" "$use_existing_sub_cert")
        dedicated_sub_block=$(cat <<EOF

${sub_addr} {
${sub_tls}
    encode gzip zstd

    header {
        -Server
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    @sub {
        path ${sub_no_slash} ${sub_no_slash}/*
    }
    handle @sub {
        reverse_proxy 127.0.0.1:${sub_port}
    }

    @subjson {
        path ${sub_json_no_slash} ${sub_json_no_slash}/*
    }
    handle @subjson {
        reverse_proxy 127.0.0.1:${sub_port}
    }

    handle {
        root * /srv/site
        try_files {path} /index.html
        file_server
    }
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
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    @panel {
        path ${base_no_slash} ${base_no_slash}/*
    }
    handle @panel {
        reverse_proxy 127.0.0.1:${panel_port}
    }${same_sub_block}

    handle {
        root * /srv/site
        try_files {path} /index.html
        file_server
    }
}${dedicated_sub_block}
EOF
)

    local cdir="$INSTALL_DIR/caddy"
    local cfile="$cdir/Caddyfile"
    run "mkdir -p $(quote_sh "$cdir") $(quote_sh "$cdir/data") $(quote_sh "$cdir/config") && chmod 755 $(quote_sh "$cdir")" || return 1
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
        run "docker exec 3xui_app x-ui setting -webBasePath $(quote_sh "$new_base")" || return 1
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

    local use_existing_panel_cert=false
    if run_q "test -f $(quote_sh "$INSTALL_DIR/cert/$panel_domain/fullchain.pem") && test -f $(quote_sh "$INSTALL_DIR/cert/$panel_domain/privkey.pem")"; then
        confirm "Found existing cert in $INSTALL_DIR/cert/$panel_domain/. Use it instead of Caddy ACME?" && use_existing_panel_cert=true
    fi

    if ! $use_existing_panel_cert; then
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
        local db_sub_port db_sub_path db_sub_json
        db_sub_port=$(xui_db_get "subPort" | tr -d '\r ' || true)
        db_sub_path=$(xui_db_get "subPath" | tr -d '\r ' || true)
        db_sub_json=$(xui_db_get "subJsonPath" | tr -d '\r ' || true)
        validate_port "$db_sub_port" && sub_port="$db_sub_port"
        [[ -n "$db_sub_path" ]] && sub_path="$db_sub_path"
        [[ -n "$db_sub_json" ]] && sub_json_path="$db_sub_json"

        if [[ "$sub_mode" == "dedicated" ]]; then
            read -rp "  Subscription domain (e.g. sub.example.com)${SUB_DOMAIN:+ [$SUB_DOMAIN]}: " sub_domain
            sub_domain="${sub_domain:-$SUB_DOMAIN}"
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

        read -rp "  Subscription path [${sub_path}]: " input_spath
        sub_path="${input_spath:-$sub_path}"
        [[ "$sub_path" != /* ]] && sub_path="/$sub_path"
        [[ "$sub_path" != */ ]] && sub_path="${sub_path}/"
        if [[ "$sub_path" == "/" ]] || ! validate_webpath "$sub_path" || [[ "$sub_path" == "$panel_path" ]]; then
            error "Invalid subscription path (cannot be '/' or equal to $panel_path)"
            return 1
        fi

        read -rp "  JSON subscription path [${sub_json_path}]: " input_jpath
        sub_json_path="${input_jpath:-$sub_json_path}"
        [[ "$sub_json_path" != /* ]] && sub_json_path="/$sub_json_path"
        [[ "$sub_json_path" != */ ]] && sub_json_path="${sub_json_path}/"
        if [[ "$sub_json_path" == "/" ]] || ! validate_webpath "$sub_json_path" || [[ "$sub_json_path" == "$panel_path" ]] || [[ "$sub_json_path" == "$sub_path" ]]; then
            error "Invalid JSON subscription path"
            return 1
        fi
    fi

    local port_sfx=""
    [[ "$https_port" != "443" ]] && port_sfx=":${https_port}"
    local ext_panel_url="https://${panel_domain}${port_sfx}${panel_path}"
    local ext_sub_url="" ext_sub_json_url=""
    if [[ "$sub_mode" == "dedicated" ]]; then
        ext_sub_url="https://${sub_domain}${port_sfx}${sub_path}"
        ext_sub_json_url="https://${sub_domain}${port_sfx}${sub_json_path}"
    elif [[ "$sub_mode" == "same" ]]; then
        ext_sub_url="https://${panel_domain}${port_sfx}${sub_path}"
        ext_sub_json_url="https://${panel_domain}${port_sfx}${sub_json_path}"
    fi

    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo -e "    Panel URL    : ${BOLD}${ext_panel_url}${NC} -> 127.0.0.1:${PANEL_PORT}"
    echo -e "    Camouflage   : https://${panel_domain}${port_sfx}/ -> /srv/site/"
    if [[ -n "$ext_sub_url" ]]; then
        echo -e "    Sub URL      : ${BOLD}${ext_sub_url}${NC} -> 127.0.0.1:${sub_port}"
        echo -e "    Sub JSON URL : ${BOLD}${ext_sub_json_url}${NC} -> 127.0.0.1:${sub_port}"
    fi
    confirm "Apply reverse proxy configuration?" || { info "Cancelled"; return 0; }

    info "Locking 3X-UI panel to loopback (127.0.0.1)..."
    run "docker exec 3xui_app x-ui setting -listenIP 127.0.0.1" >/dev/null || true
    xui_db_set "webListen" "127.0.0.1" || return 1
    xui_db_set "webCertFile" "" || return 1
    xui_db_set "webKeyFile" "" || return 1

    if [[ "$sub_mode" != "none" ]]; then
        info "Configuring 3X-UI subscription server for proxy..."
        xui_db_set "subEnable" "true" || return 1
        xui_db_set "subListen" "127.0.0.1" || return 1
        xui_db_set "subPort" "$sub_port" || return 1
        xui_db_set "subPath" "$sub_path" || return 1
        xui_db_set "subJsonPath" "$sub_json_path" || return 1
        xui_db_set "subCertFile" "" || return 1
        xui_db_set "subKeyFile" "" || return 1
        xui_db_set "subURI" "$ext_sub_url" || return 1
        xui_db_set "subJsonURI" "$ext_sub_json_url" || return 1
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

    info "Pulling/starting Caddy and restarting 3X-UI..."
    compose up -d || { error "Failed to start Caddy container"; return 1; }
    compose restart 3xui >/dev/null || true
    if is_caddy_running; then
        run "docker exec 3xui_caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true" || true
    fi

    invalidate_status
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
    echo -e "  Panel Domain  : ${BOLD}https://${PROXY_DOMAIN}${port_sfx}${PANEL_PATH}${NC}"
    echo -e "  Decoy Root    : https://${PROXY_DOMAIN}${port_sfx}/"
    echo -e "  Backend Bind  : ${PANEL_LISTEN:-0.0.0.0}:${PANEL_PORT}"
    echo -e "  Sub Proxy     : ${SUB_MODE}"
    if [[ "$SUB_MODE" != "none" && -n "$PROXY_SUB_URL" ]]; then
        echo -e "  Sub URL       : ${BOLD}${PROXY_SUB_URL}${NC} (127.0.0.1:${SUB_PORT})"
    fi
    echo ""
}

reload_reverse_proxy() {
    require_deployed || return 1
    is_caddy_running || { error "Container 3xui_caddy is not running"; return 1; }
    run "docker exec 3xui_caddy caddy validate --config /etc/caddy/Caddyfile" || return 1
    run "docker exec 3xui_caddy caddy reload --config /etc/caddy/Caddyfile" || return 1
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
            run_it "ed=\$(command -v nano || command -v vi || true); if [ -n \"\$ed\" ]; then \"\$ed\" $(quote_sh "$index_file"); else echo 'Neither nano nor vi found on host'; fi"
            success "Saved $index_file"
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
    load_proxy_conf

    confirm "Stop Caddy reverse proxy and revert 3X-UI to direct access (0.0.0.0)?" || { info "Cancelled"; return 0; }

    if is_running; then
        info "Reverting 3X-UI listen IP & subscription URI overrides..."
        xui_db_set "webListen" "" || warn "Could not clear webListen"
        if [[ "$SUB_MODE" != "none" ]]; then
            xui_db_set "subListen" "" || true
            xui_db_set "subURI" "" || true
            xui_db_set "subJsonURI" "" || true
        fi
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
            2) customize_decoy_site ;;
            3) run "docker logs --tail=100 3xui_caddy 2>/dev/null || echo '  (3xui_caddy not running)'" || true ;;
            4) reload_reverse_proxy ;;
            5) disable_reverse_proxy ;;
            6|255) _SKIP_PAUSE=true; return ;;
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

    info "Internal panel status (x-ui status)..."
    run_it "docker exec 3xui_app x-ui status 2>/dev/null || echo 'x-ui status unavailable'"

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
pub4=\$(curl -4fsS --max-time 2 https://api.ipify.org 2>/dev/null || echo 'unavailable')
pub6=\$(curl -6fsS --max-time 2 https://api64.ipify.org 2>/dev/null || echo 'unavailable')
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
        if $PROXY_ENABLED && is_caddy_running; then
            echo -e "  Reverse Proxy : ${GREEN}Caddy Active${NC} (backend ${PANEL_LISTEN:-127.0.0.1}:${PANEL_PORT})"
            [[ -n "$PROXY_SUB_URL" ]] && echo -e "  Sub URL       : ${BOLD}${PROXY_SUB_URL}${NC}"
        fi
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
                if [[ "$fw" == "none" ]]; then
                    warn "Neither ufw nor firewalld is currently active."
                else
                    get_panel_info || true
                    local xray_ports
                    xray_ports=$(run_out "ss -tulnp 2>/dev/null | awk '/xray/ {print \$1\":\"\$5}'" || true)
                    echo ""
                    echo "  Will allow:"
                    echo "    * SSH   : ${SSH_PORT}/tcp"
                    if $PROXY_ENABLED && is_caddy_running; then
                        echo "    * ACME  : 80/tcp (Caddy)"
                        echo "    * Proxy : ${PROXY_PORT}/tcp + ${PROXY_PORT}/udp (Caddy HTTPS/HTTP3)"
                    else
                        echo "    * Panel : ${PANEL_PORT}/tcp"
                    fi
                    [[ -n "$xray_ports" ]] && echo "    * Xray  : $(echo "$xray_ports" | tr '\n' ' ')"
                    if confirm "Apply these firewall rules?"; then
                        _fw_open_port "$fw" "$SSH_PORT" "tcp" || true
                        if $PROXY_ENABLED && is_caddy_running; then
                            _fw_open_port "$fw" "80" "tcp" || true
                            _fw_open_port "$fw" "$PROXY_PORT" "tcp" || true
                            _fw_open_port "$fw" "$PROXY_PORT" "udp" || true
                        else
                            _fw_open_port "$fw" "$PANEL_PORT" "tcp" || true
                        fi
                        local entry proto addr p
                        while IFS= read -r entry; do
                            [[ -z "$entry" ]] && continue
                            proto="${entry%%:*}"
                            addr="${entry#*:}"
                            p="${addr##*:}"
                            [[ "$proto" == udp* ]] && proto="udp" || proto="tcp"
                            validate_port "$p" && _fw_open_port "$fw" "$p" "$proto" || true
                        done <<< "$xray_ports"
                        [[ "$fw" == "firewalld" ]] && run "firewall-cmd --reload >/dev/null" || true
                        success "Firewall rules applied"
                    fi
                fi
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

    local pair fname url ok=0
    for pair in "${pairs[@]}"; do
        fname="${pair%%|*}"
        url="${pair#*|}"
        info "Downloading $fname..."
        if run "curl -fsSL --max-time 60 $(quote_sh "$url") -o $(quote_sh "$tmp_dir/$fname") && [ \$(wc -c < $(quote_sh "$tmp_dir/$fname")) -gt 10240 ] && docker cp $(quote_sh "$tmp_dir/$fname") $(quote_sh "3xui_app:/app/bin/$fname")"; then
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
  proxy [setup|status|reload|disable]
                          Manage Caddy reverse proxy (HTTPS + decoy + subs)
  self-install            Install this manager globally as ${BIN_INSTALL_PATH}
  self-update             Update this manager script from GitHub main branch
  help                    Show this help message
EOF
}

_download_script_to() {
    local dst="$1"
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 30 "$REPO_RAW_URL" -o "$dst" || return 1
    elif command -v wget &>/dev/null; then
        wget -qO "$dst" --timeout=30 "$REPO_RAW_URL" || return 1
    else
        error "curl or wget is required to download from GitHub"
        return 1
    fi
    [[ -s "$dst" ]] && bash -n "$dst" 2>/dev/null
}

self_install() {
    local tmp_script
    tmp_script=$(mktemp /tmp/3xui-install.XXXXXX.sh) || { error "Failed to create temp file"; return 1; }

    if [[ -f "${0:-}" && "$0" != /dev/fd/* && "$0" != /proc/* && "$0" != "bash" && "$0" != "-bash" ]] && grep -q '3X-UI Manager' "$0" 2>/dev/null; then
        cp "$0" "$tmp_script" || { rm -f "$tmp_script"; error "Failed to copy script"; return 1; }
        bash -n "$tmp_script" 2>/dev/null || { rm -f "$tmp_script"; error "Script syntax check failed"; return 1; }
    else
        info "Downloading latest manager script from GitHub..."
        if ! _download_script_to "$tmp_script"; then
            rm -f "$tmp_script"
            error "Download or syntax validation failed"
            return 1
        fi
    fi

    if [[ $EUID -eq 0 ]]; then
        install -m 0755 "$tmp_script" "$BIN_INSTALL_PATH" || cp "$tmp_script" "$BIN_INSTALL_PATH" && chmod 755 "$BIN_INSTALL_PATH"
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

    info "Downloading latest version from ${REPO_URL}..."
    if ! _download_script_to "$tmp_script"; then
        rm -f "$tmp_script"
        error "Failed to download or validate updated script"
        return 1
    fi

    local updated=false
    if [[ -f "${0:-}" && "$0" != /dev/fd/* && "$0" != /proc/* && "$0" != "bash" && "$0" != "-bash" ]]; then
        if [[ -w "$0" ]]; then
            cp "$tmp_script" "$0" && chmod +x "$0" && updated=true
        elif [[ $EUID -ne 0 ]] && command -v sudo &>/dev/null; then
            sudo cp "$tmp_script" "$0" && sudo chmod +x "$0" && updated=true
        fi
    fi

    if [[ -e "$BIN_INSTALL_PATH" && "$(realpath "$BIN_INSTALL_PATH" 2>/dev/null || echo "$BIN_INSTALL_PATH")" != "$(realpath "${0:-}" 2>/dev/null || echo "")" ]]; then
        if [[ $EUID -eq 0 || -w "$BIN_INSTALL_PATH" ]]; then
            install -m 0755 "$tmp_script" "$BIN_INSTALL_PATH" && updated=true
        elif command -v sudo &>/dev/null; then
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
        "Manage certificates"
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
            "Panel settings & security") manage_panel_settings ;;
            "Reverse proxy (Caddy)")     manage_reverse_proxy ;;
            "Manage certificates")       manage_certs ;;
            "Xray status")               xray_status ;;
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
                [[ $# -lt 2 ]] && { error "--dir requires an absolute path"; exit 1; }
                validate_abs_path "$2" || { error "Install dir must be an absolute path"; exit 1; }
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

    # Non-interactive / direct CLI command path.
    if [[ -n "$cli_cmd" ]]; then
        case "$cli_cmd" in
            help)         usage; exit 0 ;;
            self-install) self_install; exit $? ;;
            self-update)  self_update; exit $? ;;
        esac

        if [[ "$cli_cmd" == "deploy" || "$cli_cmd" == "settings" || "$cli_cmd" == "certs" || "$cli_cmd" == "proxy" ]]; then
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
                    reload)  reload_reverse_proxy ;;
                    disable) disable_reverse_proxy ;;
                    *)       error "Unknown proxy action: $cli_arg (use: setup|status|reload|disable)"; exit 1 ;;
                esac
                ;;
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
                            exec sudo bash -c 's=$(mktemp /tmp/3xui-sudo.XXXXXX.sh); trap "rm -f \"$s\"" EXIT; curl -fsSL "$1" -o "$s" && bash "$s" "${@:2}"' _ "$REPO_RAW_URL" ${orig_args[@]+"${orig_args[@]}"}
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

main "$@"
