#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/3xui-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
mkdir -p "$HOME"
export XUI_INSTALL_DIR="$TEST_TMP/opt-3x-ui"
export XUI_BACKUP_DIR="$TEST_TMP/opt-3x-ui-backups"
export XUI_SOURCE_ONLY=1

# shellcheck source=../manage.sh
source "$REPO_ROOT/manage.sh"
NO_COLOR=1
setup_terminal

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    PASS_COUNT=$(( PASS_COUNT + 1 ))
}

fail() {
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf 'FAIL: %s\n' "$1" >&2
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-values equal}"
    if [[ "$expected" == "$actual" ]]; then
        pass
    else
        fail "$msg (expected='$expected', actual='$actual')"
    fi
}

assert_ok() {
    local msg="$1"
    shift
    if "$@"; then
        pass
    else
        fail "$msg (expected exit 0)"
    fi
}

assert_fail() {
    local msg="$1"
    shift
    if "$@"; then
        fail "$msg (expected non-zero exit)"
    else
        pass
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-contains}"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass
    else
        fail "$msg (missing '$needle')"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-not contains}"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$msg (unexpected '$needle')"
    else
        pass
    fi
}

# ─── 1. Validators & Formatting ─────────────────────────────────────────────
test_validators() {
    assert_ok   "valid port 443"        validate_port "443"
    assert_ok   "valid port 65535"      validate_port "65535"
    assert_fail "invalid port 0"        validate_port "0"
    assert_fail "invalid port 65536"    validate_port "65536"
    assert_fail "invalid port alpha"    validate_port "abc"

    assert_ok   "valid ipv4"            validate_ipv4 "127.0.0.1"
    assert_ok   "valid ipv4 zero"       validate_ipv4 "0.0.0.0"
    assert_fail "invalid ipv4 octet"    validate_ipv4 "256.0.0.1"
    assert_fail "invalid ipv4 short"    validate_ipv4 "1.2.3"

    assert_ok   "valid ipv6 ::"         validate_ipv6 "::"
    assert_ok   "valid ipv6 ::1"        validate_ipv6 "::1"
    assert_ok   "valid ipv6 doc"        validate_ipv6 "2001:db8::1"
    assert_ok   "valid ipv6 full"       validate_ipv6 "2001:0db8:0000:0000:0000:0000:0000:0001"
    assert_ok   "valid ipv6 mapped"     validate_ipv6 "::ffff:192.0.2.1"
    assert_fail "invalid ipv6 empty"    validate_ipv6 ""
    assert_fail "invalid ipv6 ipv4"     validate_ipv6 "127.0.0.1"
    assert_fail "invalid ipv6 double::" validate_ipv6 "2001::db8::1"
    assert_fail "invalid ipv6 triple:"  validate_ipv6 "2001:::1"
    assert_fail "invalid ipv6 hex"      validate_ipv6 "gggg::1"
    assert_fail "invalid ipv6 9grps"    validate_ipv6 "1:2:3:4:5:6:7:8:9"
    assert_fail "invalid ipv6 3grps"    validate_ipv6 "2001:db8:1"
    assert_fail "invalid ipv6 lead :"   validate_ipv6 ":1:2:3:4:5:6:7"
    assert_fail "invalid ipv6 trail :"  validate_ipv6 "1:2:3:4:5:6:7:"

    assert_ok   "listen ip blank"       validate_listen_ip ""
    assert_ok   "listen ip 0.0.0.0"     validate_listen_ip "0.0.0.0"
    assert_ok   "listen ip ::"          validate_listen_ip "::"
    assert_ok   "listen ip ::1"         validate_listen_ip "::1"
    assert_ok   "listen ip v4"          validate_listen_ip "10.0.0.5"
    assert_fail "listen ip bad"         validate_listen_ip "not-an-ip"

    assert_ok   "valid domain"          validate_domain "sub.example.com"
    assert_fail "invalid domain single" validate_domain "localhost"
    assert_fail "invalid domain dash"   validate_domain "-bad.example.com"

    assert_ok   "valid webpath root"    validate_webpath "/"
    assert_ok   "valid webpath sub"     validate_webpath "/sub-1_a/"
    assert_fail "invalid webpath dot"   validate_webpath "/../etc/"
    assert_fail "invalid webpath dbl//" validate_webpath "/sub//a/"
    local long_path
    long_path="/$(printf 'a%.0s' {1..130})/"
    assert_fail "invalid webpath long"  validate_webpath "$long_path"

    assert_ok   "overlap identical"     _paths_overlap "/sub/" "/sub/"
    assert_ok   "overlap prefix"        _paths_overlap "/sub/" "/sub/json/"
    assert_ok   "overlap root"          _paths_overlap "/" "/panel/"
    assert_fail "disjoint /sub /json"   _paths_overlap "/sub/" "/json/"
    assert_fail "disjoint /sub /sub2"   _paths_overlap "/sub/" "/sub2/"

    assert_ok   "valid abs path"        validate_abs_path "/opt/3x-ui"
    assert_ok   "valid abs dots"        validate_abs_path "/tmp/file..name"
    assert_fail "invalid abs rel"       validate_abs_path "opt/3x-ui"
    assert_fail "invalid abs .."        validate_abs_path "/opt/../etc"
    assert_fail "invalid abs ctrl"      validate_abs_path $'/opt/bad\npath'

    assert_ok   "safe dir /opt/3x-ui"   validate_safe_dir "/opt/3x-ui"
    assert_fail "unsafe dir /"          validate_safe_dir "/"
    assert_fail "unsafe dir /opt"       validate_safe_dir "/opt"
    assert_fail "unsafe dir /opt/"      validate_safe_dir "/opt/"
    assert_fail "unsafe dir /etc"       validate_safe_dir "/etc"
    assert_fail "unsafe dir /tmp"       validate_safe_dir "/tmp"

    assert_ok   "strong pw 2-class"     validate_strong_password "Abcdefgh1234"
    assert_ok   "strong pw passphrase"  validate_strong_password "correcthorsebattery"
    assert_fail "weak pw short"         validate_strong_password "Ab1!"
    assert_fail "weak pw single class"  validate_strong_password "abcdefghijkl"
    assert_fail "weak pw default"       validate_strong_password "password1234"
    assert_fail "weak pw ctrl"          validate_strong_password $'Abcdefgh1234\n'

    assert_fail "no ctrl chars"         has_control_chars 'Tr!cky$Pass "quotes"'
    assert_ok   "has newline ctrl"      has_control_chars $'bad\nstr'

    local r20 r48
    r20=$(generate_random_string 20)
    r48=$(generate_random_string 48)
    assert_eq "20" "${#r20}" "random string 20 length"
    assert_eq "48" "${#r48}" "random string 48 length"

    assert_eq "https://www.cloudflare.com" "$(_normalize_redirect_url "www.cloudflare.com")" "normalize bare host"
    assert_ok   "valid redirect cloudflare" validate_redirect_url "https://www.cloudflare.com"
    assert_ok   "valid redirect speedtest"  validate_redirect_url "https://www.speedtest.net:8443/path"
    assert_fail "reject redirect loopback"  validate_redirect_url "http://127.0.0.1/test"
    assert_fail "reject redirect private"   validate_redirect_url "https://10.0.0.5"
    assert_fail "reject redirect 192.168"   validate_redirect_url "https://192.168.1.1"
    assert_fail "reject redirect localhost" validate_redirect_url "https://localhost:8080"
    assert_fail "reject redirect semicolon" validate_redirect_url "https://www.cloudflare.com;redir"
    assert_fail "reject redirect scheme"    validate_redirect_url "ftp://www.cloudflare.com"

    assert_ok   "valid cidr list"           validate_cidr_csv "203.0.113.0/24, 2001:db8::/32"
    assert_fail "invalid cidr entry"        validate_cidr_csv "203.0.113.0/99"
}

# ─── 2. Panel Output Parsing & URL Formatting ───────────────────────────────
test_panel_parsing_and_urls() {
    PANEL_PORT="2053"; PANEL_PATH="/"; PANEL_USER="admin"; PANEL_PROTO="http"; PANEL_LISTEN=""; PANEL_HAS_DEFAULT=""
    local show_sample listen_sample cert_sample
    show_sample=$'\033[32mport: 8443\033[0m\nwebBasePath: secretPath\nusername: opsadmin\nhasDefaultCredential: false\n'
    listen_sample=$'\033[36mlistenIP: ::1\033[0m\n'
    cert_sample=$'\033[33mcert: /root/cert/p.example.com/fullchain.pem\nkey: /root/cert/p.example.com/privkey.pem\033[0m\n'

    _parse_panel_outputs "$show_sample" "$listen_sample" "$cert_sample"
    assert_eq "8443" "$PANEL_PORT" "parsed port"
    assert_eq "/secretPath/" "$PANEL_PATH" "parsed normalized webBasePath"
    assert_eq "opsadmin" "$PANEL_USER" "parsed username"
    assert_eq "false" "$PANEL_HAS_DEFAULT" "parsed hasDefaultCredential"
    assert_eq "::1" "$PANEL_LISTEN" "parsed IPv6 listenIP"
    assert_eq "https" "$PANEL_PROTO" "parsed https proto"

    PANEL_LISTEN=""
    _parse_panel_outputs "" "Current Listen IP: 127.0.0.1" ""
    assert_eq "127.0.0.1" "$PANEL_LISTEN" "parsed Current Listen IP"

    assert_eq "127.0.0.1:2053" "$(_format_host_port "127.0.0.1" "2053")" "format IPv4 host:port"
    assert_eq "[::1]:2053" "$(_format_host_port "::1" "2053")" "format IPv6 host:port"
    assert_eq "[2001:db8::1]:2053" "$(_format_host_port "[2001:db8::1]" "2053")" "format already bracketed IPv6"

    PROXY_ENABLED=false
    PANEL_PROTO="http"; PANEL_PORT="2053"; PANEL_PATH="/p/"
    is_caddy_running() { return 1; }
    assert_eq "http://[2001:db8::1]:2053/p/" "$(format_panel_url "2001:db8::1")" "format_panel_url IPv6"

    PROXY_ENABLED=true; PROXY_DOMAIN="panel.example.com"; PROXY_PORT="8443"
    is_caddy_running() { return 0; }
    assert_eq "https://panel.example.com:8443/p/" "$(format_panel_url "1.2.3.4")" "format_panel_url proxy custom port"
    PROXY_PORT="443"
    assert_eq "https://panel.example.com/p/" "$(format_panel_url "1.2.3.4")" "format_panel_url proxy 443"
}

# ─── 3. Caddyfile, Decoy Site, Probe Redirection & WebPanel Routes ─────────
test_caddy_and_decoy() {
    REMOTE=false
    INBOUNDS_OVERRIDE='1|1|vless|127.0.0.1|10001|bad};comment|ws|none|/ws1/|tcp'
    PROBE_REDIRECT_ENABLED=false
    WEBPANEL_ENABLED=false

    generate_decoy_site true
    local decoy_html
    decoy_html=$(< "$INSTALL_DIR/caddy/site/index.html")
    assert_contains "$decoy_html" "Meridian Cloud Systems" "decoy realistic brand title"
    assert_not_contains "$decoy_html" "Authorized administrative endpoints" "decoy removed info leak"
    assert_not_contains "$decoy_html" "3x-ui" "decoy omits 3x-ui string"
    assert_not_contains "$decoy_html" "3xui" "decoy omits 3xui string"
    assert_not_contains "$decoy_html" "xray" "decoy omits xray string"
    assert_ok "decoy services.html exists" test -f "$INSTALL_DIR/caddy/site/services.html"
    assert_ok "decoy docs.html exists"     test -f "$INSTALL_DIR/caddy/site/docs.html"
    assert_ok "decoy about.html exists"    test -f "$INSTALL_DIR/caddy/site/about.html"
    assert_ok "decoy contact.html exists"  test -f "$INSTALL_DIR/caddy/site/contact.html"
    assert_ok "decoy 404.html exists"      test -f "$INSTALL_DIR/caddy/site/404.html"
    assert_ok "decoy style.css exists"     test -f "$INSTALL_DIR/caddy/site/assets/style.css"
    assert_ok "decoy app.js exists"        test -f "$INSTALL_DIR/caddy/site/assets/app.js"
    assert_ok "decoy robots.txt exists"    test -f "$INSTALL_DIR/caddy/site/robots.txt"
    assert_ok "decoy sitemap.xml exists"   test -f "$INSTALL_DIR/caddy/site/sitemap.xml"

    # Dedicated subscription domain mode + WebPanel + Probe redirection
    WEBPANEL_ENABLED=true
    WEBPANEL_PORT="2059"
    WEBPANEL_PATH="/deploy/"
    WEBPANEL_BIND="127.0.0.1"
    PROBE_REDIRECT_ENABLED=true
    PROBE_REDIRECT_TARGET="https://www.cloudflare.com"
    PROBE_REDIRECT_STATUS="302"
    PROBE_ACTIVE_STATE="primary"
    PROBE_CUSTOM_PATHS="/sec/overlap,/custom-probe"

    generate_caddyfile "panel.example.com" "8443" "ops@example.com" "2053" "/sec/" \
        "dedicated" "sub.example.com" "2096" "/sub/" "/json/" "false" "false"
    local cf
    cf=$(< "$INSTALL_DIR/caddy/Caddyfile")
    assert_contains "$cf" "admin unix//config/admin.sock" "caddyfile unix admin socket"
    assert_contains "$cf" "panel.example.com:8443 {" "caddyfile panel vhost"
    assert_contains "$cf" "sub.example.com:8443 {" "caddyfile dedicated sub vhost"
    assert_contains "$cf" "header_up X-Forwarded-Host {http.request.host}" "caddyfile X-Forwarded-Host"
    assert_contains "$cf" "header_up X-Forwarded-Port {http.request.port}" "caddyfile X-Forwarded-Port"
    assert_contains "$cf" 'header Cache-Control "no-store"' "caddyfile no-store on sub"
    assert_contains "$cf" "max_size 64KB" "caddyfile sub body limit"
    assert_contains "$cf" "max_size 32MB" "caddyfile panel body limit"
    assert_contains "$cf" "Strict-Transport-Security" "caddyfile HSTS"
    assert_contains "$cf" "Permissions-Policy" "caddyfile Permissions-Policy"
    assert_contains "$cf" "X-Robots-Tag" "caddyfile X-Robots-Tag"
    assert_contains "$cf" "Content-Security-Policy" "caddyfile decoy CSP"
    assert_contains "$cf" "# Inbound #1 (badcomment)" "caddyfile sanitized inbound remark"
    assert_not_contains "$cf" "bad};comment" "caddyfile stripped dangerous remark chars"

    # WebPanel route checks: present in panel vhost, stripped prefix, absent from dedicated sub vhost
    assert_contains "$cf" "redir /deploy /deploy/ 308" "caddyfile webpanel trailing slash redir"
    assert_contains "$cf" "@webpanel {" "caddyfile webpanel matcher"
    assert_contains "$cf" "uri strip_prefix /deploy" "caddyfile webpanel prefix strip"
    assert_contains "$cf" "reverse_proxy 127.0.0.1:2059 {" "caddyfile webpanel upstream"
    assert_contains "$cf" "header_up X-Forwarded-Prefix /deploy" "caddyfile webpanel X-Forwarded-Prefix"
    local sub_section="${cf#*sub.example.com:8443}"
    assert_not_contains "$sub_section" "127.0.0.1:2059" "webpanel excluded from dedicated sub vhost"

    # Probe redirection checks
    assert_contains "$cf" "not remote_ip 127.0.0.1 ::1" "probe allows loopback"
    assert_contains "$cf" "not header User-Agent *" "probe uses valid Caddy v2 missing header syntax"
    assert_contains "$cf" 'header User-Agent ""' "probe checks empty User-Agent"
    assert_contains "$cf" "header_regexp User-Agent" "probe checks suspicious UA patterns"
    assert_contains "$cf" "redir https://www.cloudflare.com 302" "probe redirects to configured target"
    assert_contains "$cf" "/custom-probe" "probe includes non-overlapping custom path"
    assert_not_contains "$cf" "/sec/overlap" "probe excludes path overlapping panel route"
    assert_contains "$cf" "try_files {path} {path}.html {path}/index.html" "decoy multi-page try_files"

    # Safe fallback: primary down -> fallback_decoy removes redirects cleanly
    PROBE_ACTIVE_STATE="fallback_decoy"
    generate_caddyfile "panel.example.com" "8443" "ops@example.com" "2053" "/sec/" \
        "dedicated" "sub.example.com" "2096" "/sub/" "/json/" "false" "false"
    cf=$(< "$INSTALL_DIR/caddy/Caddyfile")
    assert_not_contains "$cf" "redir https://www.cloudflare.com" "fallback_decoy disables broken redirect"

    # Safe fallback: secondary_url
    PROBE_ACTIVE_STATE="fallback_secondary"
    PROBE_FALLBACK_URL="https://www.speedtest.net"
    generate_caddyfile "panel.example.com" "8443" "ops@example.com" "2053" "/sec/" \
        "dedicated" "sub.example.com" "2096" "/sub/" "/json/" "false" "false"
    cf=$(< "$INSTALL_DIR/caddy/Caddyfile")
    assert_contains "$cf" "redir https://www.speedtest.net 302" "fallback_secondary redirects to secondary URL"

    # Same-domain subscription mode (reset probe/webpanel for baseline check)
    PROBE_REDIRECT_ENABLED=false
    PROBE_ACTIVE_STATE="primary"
    WEBPANEL_ENABLED=false
    generate_caddyfile "panel.example.com" "443" "" "2053" "/sec/" \
        "same" "" "2096" "/sub/" "/json/" "true" "false"
    cf=$(< "$INSTALL_DIR/caddy/Caddyfile")
    assert_contains "$cf" "auto_https disable_redirects" "caddyfile disable_redirects when existing cert"
    assert_contains "$cf" "@sub {" "caddyfile same-domain @sub"
    assert_contains "$cf" "@subjson {" "caddyfile same-domain @subjson"
    assert_contains "$cf" "reverse_proxy 127.0.0.1:2096 {" "caddyfile same-domain sub reverse_proxy block"

    INBOUNDS_OVERRIDE=""
    PROBE_CUSTOM_PATHS=""
}

# ─── 4. Compose Generation & Secrets Isolation ──────────────────────────────
test_compose_generation() {
    REMOTE=false
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    generate_compose "sqlite" "v2.5.0"
    local cmp_sqlite
    cmp_sqlite=$(< "$INSTALL_DIR/compose.yaml")
    assert_contains "$cmp_sqlite" 'XRAY_VMESS_AEAD_FORCED: "true"' "sqlite VMess AEAD forced"
    assert_contains "$cmp_sqlite" "no-new-privileges:true" "sqlite no-new-privileges"
    assert_not_contains "$cmp_sqlite" "XUI_DB_DSN:" "sqlite no DSN"

    mkdir -p "$INSTALL_DIR/caddy"
    : > "$INSTALL_DIR/caddy/Caddyfile"
    generate_compose "postgres" "v2.5.0" "xui_usr" 'pg$Pass!2026'
    local cmp_pg env_pg
    cmp_pg=$(< "$INSTALL_DIR/compose.yaml")
    env_pg=$(< "$INSTALL_DIR/.env")
    assert_not_contains "$cmp_pg" "XUI_DB_DSN:" "postgres DSN absent from compose.yaml"
    assert_not_contains "$cmp_pg" 'pg$Pass' "postgres password absent from compose.yaml"
    assert_contains "$cmp_pg" "env_file:" "postgres env_file attached"
    assert_contains "$cmp_pg" "scram-sha-256" "postgres scram-sha-256 auth"
    assert_contains "$cmp_pg" "cap_drop:" "caddy cap_drop"
    assert_contains "$cmp_pg" "NET_BIND_SERVICE" "caddy NET_BIND_SERVICE"
    assert_contains "$env_pg" "XUI_DB_DSN=postgres://xui_usr:pg%24Pass%212026@127.0.0.1:5432/xui?sslmode=disable" "postgres DSN encoded in .env"
}

# ─── 5. Tar Archive Validation (Tar-Slip & Symlinks) ────────────────────────
test_tar_validation() {
    REMOTE=false
    local arc_dir="$TEST_TMP/tar-test"
    mkdir -p "$arc_dir/valid/db"
    printf 'ok\n' > "$arc_dir/valid/compose.yaml"
    tar -czf "$arc_dir/valid.tar.gz" -C "$arc_dir" valid

    assert_ok "valid tar archive" _validate_tar_archive "$arc_dir/valid.tar.gz"

    # Simulate tar -tzf / -tvzf output for traversal, absolute path, symlink, hardlink
    run_out() {
        case "$1" in
            *"tar -tzf"*)  printf '../../etc/cron.d/pwn\n' ;;
            *"tar -tvzf"*) printf -- '-rw-r--r-- root/root 10 2026-01-01 00:00 ../../etc/cron.d/pwn\n' ;;
        esac
    }
    assert_fail "reject .. traversal" _validate_tar_archive "/fake.tar.gz"

    run_out() {
        case "$1" in
            *"tar -tzf"*)  printf '/etc/passwd\n' ;;
            *"tar -tvzf"*) printf -- '-rw-r--r-- root/root 10 2026-01-01 00:00 /etc/passwd\n' ;;
        esac
    }
    assert_fail "reject absolute path" _validate_tar_archive "/fake.tar.gz"

    run_out() {
        case "$1" in
            *"tar -tzf"*)  printf 'backup/compose.yaml\n' ;;
            *"tar -tvzf"*) printf 'lrwxrwxrwx root/root 0 2026-01-01 00:00 backup/compose.yaml -> /etc/shadow\n' ;;
        esac
    }
    assert_fail "reject symlink entry" _validate_tar_archive "/fake.tar.gz"

    run_out() {
        case "$1" in
            *"tar -tzf"*)  printf 'backup/compose.yaml\n' ;;
            *"tar -tvzf"*) printf 'hrw-r--r-- root/root 0 2026-01-01 00:00 backup/compose.yaml link to /etc/shadow\n' ;;
        esac
    }
    assert_fail "reject hardlink entry" _validate_tar_archive "/fake.tar.gz"

    # Restore real run_out
    run_out() {
        if $REMOTE; then
            ssh_cmd "$@" 2>/dev/null
        else
            bash -c "$1" 2>/dev/null
        fi
    }
}

# ─── 6. Stdin Credential Passing (No Secret in argv) ────────────────────────
test_stdin_credentials() {
    REMOTE=false
    local mock_bin="$TEST_TMP/mock-bin"
    mkdir -p "$mock_bin"
    local argv_log="$TEST_TMP/docker-argv.log"
    local xui_log="$TEST_TMP/xui-args.log"

    cat > "$mock_bin/mock-xui" <<'SH'
#!/usr/bin/env sh
: > "$MOCK_XUI_LOG"
for a in "$@"; do
    printf '%s\n' "$a" >> "$MOCK_XUI_LOG"
done
SH
    chmod +x "$mock_bin/mock-xui"

    cat > "$mock_bin/docker" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" > "$MOCK_DOCKER_ARGV"
# Expected: exec -i 3xui_app sh -c <script> _ <user> <port> <webpath>
shift 5
script="$1"
shift
# Redirect /app/x-ui to mock-xui inside test sh script
patched=$(printf '%s' "$script" | sed "s|b=/app/x-ui; \[ -x \"\$b\" \] \|\| b=/usr/local/x-ui/x-ui|b=$MOCK_XUI_BIN|")
exec sh -c "$patched" "$@"
SH
    chmod +x "$mock_bin/docker"

    local secret_pw='Tr!cky$Pass "with" '\''quotes'\'' -lead'
    local old_path="$PATH"
    export PATH="$mock_bin:$PATH"
    export MOCK_DOCKER_ARGV="$argv_log"
    export MOCK_XUI_LOG="$xui_log"
    export MOCK_XUI_BIN="$mock_bin/mock-xui"

    _xui_set_credentials_stdin "secadmin" "$secret_pw" "9443" "/secret/" >/dev/null
    export PATH="$old_path"

    local docker_argv xui_args
    docker_argv=$(< "$argv_log")
    xui_args=$(< "$xui_log")

    assert_not_contains "$docker_argv" 'Tr!cky' "password absent from docker argv"
    assert_contains "$xui_args" "-username=secadmin" "x-ui received username"
    assert_contains "$xui_args" "-password=${secret_pw}" "x-ui received exact password via stdin"
    assert_contains "$xui_args" "-port=9443" "x-ui received port"
    assert_contains "$xui_args" "-webBasePath=/secret/" "x-ui received webBasePath"
}

# ─── 7. SSH Config Persistence (No Password Stored) ─────────────────────────
test_ssh_config_hardening() {
    CONFIG_FILE="$TEST_TMP/home/.3xui-manager.conf"
    SSH_HOST="203.0.113.50"
    SSH_PORT="2222"
    SSH_USER="ops"
    SSH_KEY=""
    SSH_PASS="SuperSecretPass123!"

    save_config >/dev/null
    local conf_txt
    conf_txt=$(< "$CONFIG_FILE")
    assert_contains "$conf_txt" 'SSH_PASS_B64=""' "save_config never persists SSH_PASS_B64"
    assert_not_contains "$conf_txt" "SuperSecretPass123" "plaintext/b64 password absent"

    # Legacy file detection
    printf 'SSH_HOST="203.0.113.50"\nSSH_PORT="2222"\nSSH_USER="ops"\nSSH_KEY=""\nSSH_PASS_B64="U3VwZXJTZWNyZXQ="\n' > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    SSH_PASS=""
    load_config
    assert_eq "true" "$_LEGACY_SAVED_PASS" "load_config flags legacy SSH_PASS_B64"

    # World-writable config rejection on POSIX filesystems
    if [[ "$(uname -s)" == "Linux" ]]; then
        chmod 666 "$CONFIG_FILE"
        SSH_HOST=""
        load_config >/dev/null 2>&1 || true
        assert_eq "" "$SSH_HOST" "load_config refuses world-writable config"
    fi
}

# ─── 8. Subscription Verification Logic ─────────────────────────────────────
test_subscription_verification() {
    local sub_cfg="$TEST_TMP/sub-install"
    mkdir -p "$sub_cfg/caddy"
    INSTALL_DIR="$sub_cfg"
    cat > "$sub_cfg/caddy/proxy.conf" <<'CONF'
PROXY_ENABLED="true"
PROXY_DOMAIN="panel.example.com"
PROXY_PORT="8443"
PROXY_EMAIL="ops@example.com"
SUB_MODE="dedicated"
SUB_DOMAIN="sub.example.com"
SUB_PORT="2096"
SUB_PATH="/sub/"
SUB_JSON_PATH="/json/"
CONF

    # Save and override stubs
    is_running() { return 0; }
    is_caddy_running() { return 0; }
    _is_postgres_backend() { return 1; }

    # Case 1: DB mismatch (missing subDomain / subJsonEnable)
    run_out() {
        case "$1" in
            *"cat "*) cat "$INSTALL_DIR/caddy/proxy.conf" ;;
            *"sqlite3"*|*"SELECT key"*)
                printf 'webListen\t127.0.0.1\nwebDomain\tpanel.example.com\nsubEnable\ttrue\nsubListen\t127.0.0.1\nsubDomain\t\nsubPort\t2096\nsubPath\t/sub/\nsubJsonEnable\tfalse\nsubJsonPath\t/json/\nsubURI\thttps://sub.example.com:8443/sub/\nsubJsonURI\thttps://sub.example.com:8443/json/\n'
                ;;
            *"/app/x-ui"*|*"getent"*|*"ipify"*|*"hostname"*) return 0 ;;
        esac
    }
    run_q() {
        case "$1" in
            "command -v curl"|*"command -v sqlite3"*) return 0 ;;
        esac
        return 1
    }
    assert_fail "detects subscription DB mismatch" verify_subscription_endpoint 1
    assert_eq "db_mismatch" "$SUB_VERIFY_STATUS" "status is db_mismatch"
    assert_eq "true" "$SUB_ENABLE_DB" "DB mock parsed subEnable"
    assert_eq "127.0.0.1" "$SUB_LISTEN_DB" "DB mock parsed subListen"
    assert_eq "false" "$SUB_JSON_ENABLE_DB" "DB mock parsed subJsonEnable"

    # Case 2: Backend rejects Host with 403
    run_out() {
        case "$1" in
            *"cat "*) cat "$INSTALL_DIR/caddy/proxy.conf" ;;
            *"SELECT key"*)
                printf 'webListen\t127.0.0.1\nwebDomain\tpanel.example.com\nsubEnable\ttrue\nsubListen\t127.0.0.1\nsubDomain\tsub.example.com\nsubPort\t2096\nsubPath\t/sub/\nsubJsonEnable\ttrue\nsubJsonPath\t/json/\nsubURI\thttps://sub.example.com:8443/sub/\nsubJsonURI\thttps://sub.example.com:8443/json/\n'
                ;;
            *"127.0.0.1:2096"*)
                printf 'HTTP/1.1 403 Forbidden\r\n\r\n\n__HTTP_CODE__:403\n'
                ;;
        esac
    }
    assert_fail "detects 403 domain rejection" verify_subscription_endpoint 1
    assert_eq "domain_rejected" "$SUB_VERIFY_STATUS" "status is domain_rejected"

    # Case 3: Caddy returns decoy instead of routing to sub upstream
    run_out() {
        case "$1" in
            *"cat "*) cat "$INSTALL_DIR/caddy/proxy.conf" ;;
            *"SELECT key"*)
                printf 'webListen\t127.0.0.1\nwebDomain\tpanel.example.com\nsubEnable\ttrue\nsubListen\t127.0.0.1\nsubDomain\tsub.example.com\nsubPort\t2096\nsubPath\t/sub/\nsubJsonEnable\ttrue\nsubJsonPath\t/json/\nsubURI\thttps://sub.example.com:8443/sub/\nsubJsonURI\thttps://sub.example.com:8443/json/\n'
                ;;
            *"http://127.0.0.1:2096"*)
                printf 'HTTP/1.1 404 Not Found\r\n\r\n\n__HTTP_CODE__:404\n'
                ;;
            *"https://sub.example.com:8443"*)
                printf 'HTTP/2 200\r\ncontent-type: text/html\r\n\r\n<h1>Service Status Portal</h1>\n__HTTP_CODE__:200\n'
                ;;
        esac
    }
    assert_fail "detects Caddy serving decoy on sub path" verify_subscription_endpoint 1
    assert_eq "proxy_failed" "$SUB_VERIFY_STATUS" "status is proxy_failed"

    # Case 4: Full success (backend + Caddy Cache-Control: no-store + DNS match)
    run_out() {
        case "$1" in
            *"cat "*) cat "$INSTALL_DIR/caddy/proxy.conf" ;;
            *"SELECT key"*)
                printf 'webListen\t127.0.0.1\nwebDomain\tpanel.example.com\nsubEnable\ttrue\nsubListen\t127.0.0.1\nsubDomain\tsub.example.com\nsubPort\t2096\nsubPath\t/sub/\nsubJsonEnable\ttrue\nsubJsonPath\t/json/\nsubURI\thttps://sub.example.com:8443/sub/\nsubJsonURI\thttps://sub.example.com:8443/json/\n'
                ;;
            *"http://127.0.0.1:2096"*)
                printf 'HTTP/1.1 404 Not Found\r\n\r\n\n__HTTP_CODE__:404\n'
                ;;
            *"https://sub.example.com:8443"*)
                printf 'HTTP/2 404\r\ncache-control: no-store\r\n\r\n\n__HTTP_CODE__:404\n'
                ;;
            *"getent ahosts"*)
                printf '203.0.113.10\n'
                ;;
            *"https://api.ipify.org"*)
                printf '203.0.113.10\n'
                ;;
        esac
    }
    assert_ok "verifies working subscription proxy end-to-end" verify_subscription_endpoint 1
    assert_eq "ok_proxy" "$SUB_VERIFY_STATUS" "status is ok_proxy"

    # Case 5: Optional JSON subscription disabled (subJsonEnable=false) still verifies cleanly
    run_out() {
        case "$1" in
            *"cat "*) cat "$INSTALL_DIR/caddy/proxy.conf" ;;
            *"SELECT key"*)
                printf 'webListen\t127.0.0.1\nwebDomain\tpanel.example.com\nsubEnable\ttrue\nsubListen\t127.0.0.1\nsubDomain\tsub.example.com\nsubPort\t2096\nsubPath\t/sub/\nsubJsonEnable\tfalse\nsubJsonPath\t/json/\nsubURI\thttps://sub.example.com:8443/sub/\nsubJsonURI\t\n'
                ;;
            *"http://127.0.0.1:2096/sub/"*)
                printf 'HTTP/1.1 404 Not Found\r\n\r\n\n__HTTP_CODE__:404\n'
                ;;
            *"https://sub.example.com:8443/sub/"*)
                printf 'HTTP/2 404\r\ncache-control: no-store\r\n\r\n\n__HTTP_CODE__:404\n'
                ;;
            *"getent ahosts"*)
                printf '203.0.113.10\n'
                ;;
            *"https://api.ipify.org"*)
                printf '203.0.113.10\n'
                ;;
        esac
    }
    assert_ok "verifies subscription proxy when subJsonEnable=false" verify_subscription_endpoint 1
    assert_eq "ok_proxy" "$SUB_VERIFY_STATUS" "status is ok_proxy with json disabled"

    INSTALL_DIR="$XUI_INSTALL_DIR"
}

# ─── 9. Security Audit Smoke Test ───────────────────────────────────────────
test_security_audit() {
    REMOTE=false
    local aud_dir="$TEST_TMP/audit-install"
    mkdir -p "$aud_dir/caddy/data" "$aud_dir/caddy/config"
    INSTALL_DIR="$aud_dir"
    CONFIG_FILE="$TEST_TMP/home/.3xui-manager.conf"
    : > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true

    # On Windows/NTFS (Git Bash), chmod 600/700 is a no-op so stat returns 644/755; keep real stat on Linux/macOS CI.
    if [[ "$(uname -s)" != "Linux" && "$(uname -s)" != "Darwin" ]]; then
        _remote_file_mode() {
            [[ -d "$1" ]] && { echo "700"; return 0; }
            [[ -f "$1" ]] && { echo "600"; return 0; }
            return 0
        }
    fi

    generate_caddyfile "panel.example.com" "8443" "ops@example.com" "2053" "/sec/" \
        "dedicated" "sub.example.com" "2096" "/sub/" "/json/" "false" "false"
    generate_compose "postgres" "v2.5.0" "xui_usr" "StrongPgPass!2026"
    cat > "$aud_dir/caddy/proxy.conf" <<'CONF'
PROXY_ENABLED="true"
PROXY_DOMAIN="panel.example.com"
PROXY_PORT="8443"
PROXY_EMAIL="ops@example.com"
SUB_MODE="dedicated"
SUB_DOMAIN="sub.example.com"
SUB_PORT="2096"
SUB_PATH="/sub/"
SUB_JSON_PATH="/json/"
CONF

    is_deployed() { return 0; }
    is_running() { return 0; }
    is_caddy_running() { return 0; }
    is_pg_running() { return 0; }
    _is_postgres_backend() { return 0; }
    run_q() {
        local cmd="$1"
        case "$cmd" in
            *"command -v curl"*) return 0 ;;
            *"fail2ban-client"*) return 0 ;;
            *"ufw status"*) return 0 ;;
            *"docker "*) return 1 ;;
            *) bash -c "$cmd" &>/dev/null ;;
        esac
    }
    run_out() {
        local cmd="$1"
        case "$cmd" in
            *"/app/x-ui"*"-show=true"*)
                printf 'port: 2053\nwebBasePath: /sec/\nusername: opsadmin\nhasDefaultCredential: false\n'
                ;;
            *"/app/x-ui"*"-getListen=true"*)
                printf 'listenIP: 127.0.0.1\n'
                ;;
            *"/app/x-ui"*"-getCert=true"*)
                return 0
                ;;
            *"SELECT key"*)
                printf 'webDomain\tpanel.example.com\nwebListen\t127.0.0.1\ntwoFactorEnable\ttrue\nsessionMaxAge\t60\nsubEnable\ttrue\nsubListen\t127.0.0.1\nsubDomain\tsub.example.com\nsubPort\t2096\nsubPath\t/sub/\nsubJsonEnable\ttrue\nsubJsonPath\t/json/\nsubURI\thttps://sub.example.com:8443/sub/\nsubJsonURI\thttps://sub.example.com:8443/json/\nsubEncrypt\ttrue\n'
                ;;
            *) bash -c "$cmd" 2>/dev/null ;;
        esac
    }

    local aud_out=""
    aud_out=$(security_audit)
    assert_ok "security_audit exits 0 on hardened stack" security_audit >/dev/null
    assert_contains "$aud_out" "Two-Factor Authentication (2FA) is enabled" "audit detects 2FA"
    assert_contains "$aud_out" "Subscription proxy locked to 127.0.0.1" "audit checks subscription proxy"
    assert_contains "$aud_out" "PostgreSQL DSN isolated in .env" "audit checks DSN isolation"

    # Negative test: loose .env permissions (644) trigger FAIL
    _remote_file_mode() {
        case "$1" in
            *".env") echo "644" ;;
            *)
                if [[ "$(uname -s)" != "Linux" && "$(uname -s)" != "Darwin" ]]; then
                    [[ -d "$1" ]] && { echo "700"; return 0; }
                    [[ -f "$1" ]] && { echo "600"; return 0; }
                else
                    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
                fi
                ;;
        esac
    }
    assert_fail "security_audit fails on loose .env mode (644)" security_audit >/dev/null
    _remote_file_mode() {
        local p="$1"
        run_out "stat -c '%a' $(quote_sh "$p") 2>/dev/null || stat -f '%Lp' $(quote_sh "$p") 2>/dev/null" || true
    }

    # Negative test: default credentials trigger FAIL (exit 1)
    run_out() {
        local cmd="$1"
        case "$cmd" in
            *"/app/x-ui"*"-show=true"*)
                printf 'port: 2053\nwebBasePath: /\nusername: admin\nhasDefaultCredential: true\n'
                ;;
            *"/app/x-ui"*"-getListen=true"*)
                printf 'listenIP: 0.0.0.0\n'
                ;;
            *"SELECT key"*)
                printf 'webDomain\t\nwebListen\t0.0.0.0\n'
                ;;
            *) bash -c "$cmd" 2>/dev/null ;;
        esac
    }
    assert_fail "security_audit fails on default credentials + non-loopback" security_audit >/dev/null

    INSTALL_DIR="$XUI_INSTALL_DIR"
}

# ─── 10. Cert Revocation, Caddy Fallback & Firewall Lockout Guards ──────────
test_extended_cli_and_guards() {
    REMOTE=false
    AUTO_YES=true
    INTERACTIVE=false
    local ext_dir="$TEST_TMP/ext-install"
    mkdir -p "$ext_dir/cert/rev.example.com" "$ext_dir/caddy"
    INSTALL_DIR="$ext_dir"
    : > "$ext_dir/cert/rev.example.com/fullchain.pem"
    : > "$ext_dir/cert/rev.example.com/privkey.pem"

    cat > "$ext_dir/caddy/proxy.conf" <<'CONF'
PROXY_ENABLED="true"
PROXY_DOMAIN="rev.example.com"
PROXY_PORT="443"
PROXY_EMAIL="ops@example.com"
SUB_MODE="none"
CONF
    cat > "$ext_dir/caddy/Caddyfile" <<'CADDY'
rev.example.com {
    tls /root/cert/rev.example.com/fullchain.pem /root/cert/rev.example.com/privkey.pem
}
CADDY

    local INBOUNDS_OVERRIDE=""
    is_deployed() { return 0; }
    _is_postgres_backend() { return 1; }
    is_running() { return 1; }
    is_pg_running() { return 1; }
    is_caddy_running() { return 1; }
    get_panel_info() { PANEL_PORT="2053"; PANEL_PATH="/sec/"; load_proxy_conf; return 1; }
    run_q() {
        case "$1" in
            "command -v certbot") return 1 ;;
            *) bash -c "$1" &>/dev/null ;;
        esac
    }
    run_out() { bash -c "$1" 2>/dev/null; }
    run() { bash -c "$1"; }

    assert_fail "cert_revoke rejects invalid reason" cert_revoke "rev.example.com" "bogus" >/dev/null 2>&1
    assert_fail "cert_revoke rejects traversal domain" cert_revoke "../etc" "unspecified" >/dev/null 2>&1
    assert_ok   "cert_revoke deletes local cert dir & updates Caddy" cert_revoke "rev.example.com" "superseded" >/dev/null
    assert_fail "cert_revoke removed local cert dir" test -d "$ext_dir/cert/rev.example.com"
    assert_not_contains "$(< "$ext_dir/caddy/Caddyfile")" "tls /root/cert/rev.example.com/" "Caddyfile reverted away from deleted cert"

    # Firewall lockout protection refuses closing SSH port 22 or active proxy port 443
    _fw_detect_backend() { printf 'ufw'; }
    SSH_PORT="22"
    assert_fail "firewall_cli_dispatch refuses closing SSH port 22" firewall_cli_dispatch close 22 tcp >/dev/null 2>&1
    assert_fail "firewall_cli_dispatch refuses closing active proxy port 443" firewall_cli_dispatch close 443 tcp >/dev/null 2>&1

    # panel_settings_show prints structured KEY=VALUE lines
    local kv_out
    kv_out=$(panel_settings_show)
    assert_contains "$kv_out" "PROXY_DOMAIN=rev.example.com" "panel_settings_show prints PROXY_DOMAIN"
    assert_contains "$kv_out" "PANEL_PATH=/sec/" "panel_settings_show prints PANEL_PATH"

    INSTALL_DIR="$XUI_INSTALL_DIR"
}

test_versioning_and_self_update() {
    local v_file v_script v_wp
    v_file=$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")
    v_script=$(_deploy_extract_script_version "$REPO_ROOT/manage.sh")
    v_wp=$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/webpanel/__init__.py" | head -n 1)

    assert_eq "$v_file" "$DEPLOY_VERSION" "VERSION matches DEPLOY_VERSION"
    assert_eq "$v_file" "$v_script" "VERSION matches extract script version"
    assert_eq "$v_file" "$v_wp" "VERSION matches webpanel.__version__"
    assert_contains "$(< "$REPO_ROOT/CHANGELOG.md")" "## [v${v_file}]" "CHANGELOG.md documents current version"

    assert_eq "1"  "$(_semver_compare "2.0.1" "2.0.0")" "_semver_compare 2.0.1 > 2.0.0"
    assert_eq "0"  "$(_semver_compare "2.0.0" "2.0.0")" "_semver_compare 2.0.0 == 2.0.0"
    assert_eq "-1" "$(_semver_compare "1.9.9" "2.0.0")" "_semver_compare 1.9.9 < 2.0.0"

    assert_ok   "_deploy_validate_ref accepts v2.0.0" _deploy_validate_ref "v2.0.0"
    assert_ok   "_deploy_validate_ref accepts v2.1.0-rc.1" _deploy_validate_ref "v2.1.0-rc.1"
    assert_ok   "_deploy_validate_ref accepts main" _deploy_validate_ref "main"
    assert_fail "_deploy_validate_ref rejects bad ref" _deploy_validate_ref "../main"
    assert_fail "_deploy_validate_ref rejects short tag" _deploy_validate_ref "v2.0"
    assert_fail "_deploy_validate_ref rejects injection" _deploy_validate_ref "v2.0.0;id"

    local v_out
    v_out=$(deploy_version_cmd)
    assert_contains "$v_out" "3xui-deploy v${DEPLOY_VERSION}" "deploy_version_cmd reports current version"

    local orig_install="$INSTALL_DIR"
    local orig_bin="$BIN_INSTALL_PATH"
    local upd_dir="$TEST_TMP/ver-test"
    mkdir -p "$upd_dir/webpanel/static" "$upd_dir/bin"
    INSTALL_DIR="$upd_dir"
    BIN_INSTALL_PATH="$upd_dir/bin/3xui-deploy"
    printf '__version__ = "%s"\n' "$DEPLOY_VERSION" > "$upd_dir/webpanel/__init__.py"
    printf '# mock\n' > "$upd_dir/webpanel/server.py"

    _deploy_latest_release_ref() { printf 'v9.9.9|9.9.9|release'; }
    local chk_out
    chk_out=$(_deploy_version_info --check)
    assert_contains "$chk_out" "DEPLOY_UPDATE_AVAILABLE=true" "version check detects newer release"
    assert_contains "$chk_out" "DEPLOY_LATEST_VERSION=9.9.9" "version check prints latest version"
    assert_contains "$chk_out" "DEPLOY_CHANNEL=release" "version check reports release channel"

    _deploy_latest_release_ref() { printf 'v%s|%s|release' "$DEPLOY_VERSION" "$DEPLOY_VERSION"; }
    local skip_out
    skip_out=$(self_update)
    assert_contains "$skip_out" "Already up to date" "self_update skips matching version without --force"

    assert_fail "self_update rejects invalid ref" self_update "not-a-tag" >/dev/null 2>&1
    assert_fail "self_update rejects unknown option" self_update "--bogus" >/dev/null 2>&1

    # Mock newer release download + SHA-256 verification + WebPanel sync
    local mock_remote="$TEST_TMP/mock-remote"
    mkdir -p "$mock_remote/webpanel/static"
    cat > "$mock_remote/manage.sh" <<'EOF'
#!/usr/bin/env bash
# 3X-UI Manager
DEPLOY_VERSION="2.9.0"
exit 0
EOF
    printf '__version__ = "2.9.0"\n' > "$mock_remote/webpanel/__init__.py"
    printf 'AUTH=1\n' > "$mock_remote/webpanel/auth.py"
    printf 'PROBE=1\n' > "$mock_remote/webpanel/probe.py"
    printf 'OPS=1\n' > "$mock_remote/webpanel/ops.py"
    printf 'SERVER=1\n' > "$mock_remote/webpanel/server.py"
    printf '<!doctype html>\n' > "$mock_remote/webpanel/static/index.html"
    printf 'body{}\n' > "$mock_remote/webpanel/static/app.css"
    printf 'console.log(1);\n' > "$mock_remote/webpanel/static/app.js"
    (cd "$mock_remote" && if command -v sha256sum >/dev/null 2>&1; then sha256sum manage.sh webpanel/__init__.py webpanel/auth.py webpanel/probe.py webpanel/ops.py webpanel/server.py webpanel/static/index.html webpanel/static/app.css webpanel/static/app.js; else shasum -a 256 manage.sh webpanel/__init__.py webpanel/auth.py webpanel/probe.py webpanel/ops.py webpanel/server.py webpanel/static/index.html webpanel/static/app.css webpanel/static/app.js; fi) > "$mock_remote/SHA256SUMS.txt"

    # Negative checksum check
    printf 'tampered\n' > "$mock_remote/tampered.sh"
    assert_fail "_verify_checksum_if_present rejects tampered manage.sh" _verify_checksum_if_present "$mock_remote/SHA256SUMS.txt" "manage.sh" "$mock_remote/tampered.sh" >/dev/null 2>&1

    _deploy_latest_release_ref() { printf 'v2.9.0|2.9.0|release'; }
    _download_release_checksums() { cp "$mock_remote/SHA256SUMS.txt" "$2"; }
    _deploy_http_get() {
        local url="$1" dst="${2:-}"
        local rel="${url#*v2.9.0/}"
        if [[ -n "$dst" ]]; then
            cp "$mock_remote/$rel" "$dst"
        else
            cat "$mock_remote/$rel"
        fi
    }
    run_q() {
        case "$1" in
            *"test -f "*) bash -c "$1" &>/dev/null ;;
            *"systemctl is-active --quiet 3xui-deploy-web"*) return 0 ;;
            *) return 1 ;;
        esac
    }

    local upd_out
    upd_out=$(WEBPANEL_NO_SELF_RESTART=1 self_update)
    assert_contains "$upd_out" "UPDATED_FROM=${DEPLOY_VERSION}" "self_update reports previous version"
    assert_contains "$upd_out" "UPDATED_TO=2.9.0" "self_update reports updated script version"
    assert_contains "$upd_out" "UPDATED_REF=v2.9.0" "self_update reports applied ref"
    assert_contains "$upd_out" "WEBPANEL_RESTART_REQUIRED=true" "self_update signals deferred WebPanel restart"
    assert_eq "2.9.0" "$(_deploy_extract_script_version "$BIN_INSTALL_PATH")" "self_update installed new CLI binary"
    assert_contains "$(< "$upd_dir/webpanel/__init__.py")" "2.9.0" "self_update synced WebPanel version"
    assert_ok "self_update synced webpanel/manage.sh" test -x "$upd_dir/webpanel/manage.sh"

    INSTALL_DIR="$orig_install"
    BIN_INSTALL_PATH="$orig_bin"
}

test_validators
test_panel_parsing_and_urls
test_caddy_and_decoy
test_compose_generation
test_tar_validation
test_stdin_credentials
test_ssh_config_hardening
test_subscription_verification
test_security_audit
test_extended_cli_and_guards
test_versioning_and_self_update

printf 'Tests complete: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
(( FAIL_COUNT == 0 ))
