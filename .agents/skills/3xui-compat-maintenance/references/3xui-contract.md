# 3x-ui Upstream Contract Reference

## Supported Version Policy (`manage.sh`)
- `XUI_COMPAT_MIN_VERSION="2.0.0"` (`< 2.0.0` classified as `unsupported_legacy`)
- `XUI_COMPAT_SUPPORTED_MAJORS="2 3"`
- `XUI_COMPAT_MAX_TESTED_MAJOR="3"` (`>= 4.0.0` classified as `unsupported_major`)
- Non-semver tags (`latest`, `dev-latest`) classified as `unknown_tag` (triggers warning and confirmation when interactive).

## Binary & Directory Discovery Order
- **Go binary (`_xui_find_binary`)**: `/app/x-ui`, `/usr/local/x-ui/x-ui`, `/app/3x-ui`, `/proc/1/exe` — always verifies executable does NOT begin with `#!` (rejects `x-ui.sh` shell wrapper).
- **Important Test Hook**: `_xui_set_credentials_stdin` must keep the literal snippet `b=/app/x-ui; [ -x "$b" ] || b=/usr/local/x-ui/x-ui` so `tests/test_manage.sh` can mock it via `sed`.
- **Database path (`_xui_detect_db_path`)**: `$XUI_DB_FOLDER/x-ui.db` -> `/etc/x-ui/x-ui.db` -> first `*.db` in `$XUI_DB_FOLDER`. Host SQLite path prefers `$INSTALL_DIR/db/<db_name>` before falling back to container `sqlite3`.
- **GeoIP/GeoSite directory (`_xui_detect_bin_dir`)**: `$XUI_BIN_FOLDER` -> `/app/bin` -> `/usr/local/x-ui/bin`.

## Database Schema Contract (`_xui_check_db_schema`)
- `settings` table: requires `key`, `value`.
  - Managed keys: `webDomain`, `webListen`, `webPort`, `webBasePath`, `webCertFile`, `webKeyFile`, `twoFactorEnable`, `sessionMaxAge`, `subEnable`, `subListen`, `subDomain`, `subPort`, `subPath`, `subJsonEnable`, `subJsonPath`, `subURI`, `subJsonURI`, `subEncrypt`, `subCertFile`, `subKeyFile`.
- `inbounds` table: requires `id`, `enable`, `protocol`, `listen`, `port`, `remark`, and either `stream_settings` or `streamSettings`.

## CLI Flags Probed (`setting -h`)
- `-show`, `-getListen`, `-getCert`, `-port`, `-listenIP`, `-webBasePath`, `-username`, `-password`, `-resetTwoFactor`, `-webCert`, `-webCertKey`.

## Protocol Firewall Mapping (`_inbound_fw_proto`)
- UDP-only protocols: `wireguard`, `amneziawg`, `hysteria`, `hysteria2`, `tuic`, `masque`, and transports `kcp`, `mkcp`, `quic`.
- TCP+UDP protocols: `shadowsocks`, `dokodemo-door`, `mixed`, `socks`.
- Default: `tcp`.
