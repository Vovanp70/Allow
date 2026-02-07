#!/bin/sh
#
# CGI for reading/saving config files (stubby, stubby-family, dnsmasq, dnsmasq-family).
# GET /api/<service>/config/full -> JSON { config, file_path }
# POST /api/<service>/config/full body { "config": "..." } -> validate, save, JSON { success, error? }
# Requires: jq (installed with monitor).
#
PATH="/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin"; export PATH
ETC_ALLOW="${ETC_ALLOW:-/opt/etc/allow}"
# Дебаг sing-box: включить через env DEBUG_SINGBOX_CONFIG=1 или флаг-файл (lighttpd не передаёт env в CGI)
DEBUG_SINGBOX_ACTIVE=0
[ "${DEBUG_SINGBOX_CONFIG:-0}" = "1" ] && DEBUG_SINGBOX_ACTIVE=1
[ -f "${ETC_ALLOW}/monitor/.debug_singbox_config" ] && DEBUG_SINGBOX_ACTIVE=1
echo "config.cgi RUN DEBUG_SINGBOX_ACTIVE=$DEBUG_SINGBOX_ACTIVE" >&2
CONTENT_LENGTH="${CONTENT_LENGTH:-0}"

# Normalize PATH_INFO
PATH_INFO="$(echo "${PATH_INFO:-}" | tr -d '\r\n' | sed 's#^/##;s#/$##')"
if [ -z "$PATH_INFO" ] && [ -n "${REQUEST_URI:-}" ]; then
    _uri="$(echo "${REQUEST_URI}" | tr -d '\r\n' | sed 's#?.*##')"
    case "$_uri" in
        /api/*) PATH_INFO="${_uri#/api/}" ;;
        /cgi-bin/config.cgi/*) PATH_INFO="${_uri#/cgi-bin/config.cgi/}" ;;
        *) ;;
    esac
    PATH_INFO="$(echo "$PATH_INFO" | sed 's#^/##;s#/$##')"
fi
REQUEST_METHOD="$(echo "${REQUEST_METHOD:-GET}" | tr 'a-z' 'A-Z')"

cgi_header() {
    printf 'Content-Type: application/json; charset=utf-8\r\n\r\n'
}
status_header() {
    printf 'Status: %s\r\n' "$1"
}
json_esc() {
    printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g;s/	/\\t/g'
}

read_body() {
    [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null || { echo ""; return 0; }
    head -c "$CONTENT_LENGTH" 2>/dev/null || dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null || true
}

# Дебаг sing-box POST: при DEBUG_SINGBOX_ACTIVE=1 пишем в лог и в stderr (видно в консоли при lighttpd -D)
debug_singbox_config() {
    [ "${DEBUG_SINGBOX_ACTIVE:-0}" = "1" ] || return 0
    _log="/opt/var/log/allow/singbox-config-debug.log"
    mkdir -p /opt/var/log/allow 2>/dev/null || true
    _blen=0; _clen=0
    [ -n "$1" ] && _blen="${#1}"
    [ -n "$2" ] && _clen="${#2}"
    _line="$(printf '%s body_len=%s config_len=%s' "$(date -Iseconds 2>/dev/null || date 2>/dev/null)" "$_blen" "$_clen")"
    printf '%s\n' "$_line" >>"$_log" 2>/dev/null || true
    printf '%s\n' "$_line" >&2
    if [ -n "$2" ]; then
        printf 'hex bytes 0-80:\n' >>"$_log" 2>/dev/null || true
        printf 'hex bytes 0-80:\n' >&2
        _hex="$(printf '%s' "$2" | head -c 80 | od -A x -t x1 2>/dev/null)"
        printf '%s\n' "$_hex" >>"$_log" 2>/dev/null || true
        printf '%s\n' "$_hex" >&2
    fi
}

# Resolve config file path for service (stubby, stubby-family, dnsmasq, dnsmasq-family, sing-box)
get_config_path() {
    _s="$1"
    case "$_s" in
        stubby) echo "${ETC_ALLOW}/stubby/stubby.yml" ;;
        stubby-family) echo "${ETC_ALLOW}/stubby/stubby-family.yml" ;;
        dnsmasq)
            if [ -f "${ETC_ALLOW}/dnsmasq-full/dnsmasq.conf" ]; then
                echo "${ETC_ALLOW}/dnsmasq-full/dnsmasq.conf"
            elif [ -f "/opt/etc/dnsmasq-full.conf" ]; then
                echo "/opt/etc/dnsmasq-full.conf"
            else
                echo "${ETC_ALLOW}/dnsmasq-full/dnsmasq.conf"
            fi
            ;;
        dnsmasq-family) echo "${ETC_ALLOW}/dnsmasq-full/dnsmasq-family.conf" ;;
        sing-box) echo "${ETC_ALLOW}/sing-box/config.json" ;;
        *) echo "" ;;
    esac
}

# Validate config: $1=service, $2=path_to_tmp_file. Return 0 if valid.
validate_config() {
    _svc="$1"
    _tmp="$2"
    case "$_svc" in
        stubby|stubby-family)
            stubby -C "$_tmp" -i >/dev/null 2>&1
            ;;
        dnsmasq|dnsmasq-family)
            dnsmasq --test -C "$_tmp" >/dev/null 2>&1
            ;;
        sing-box)
            if command -v sing-box >/dev/null 2>&1; then
                sing-box check -c "$_tmp" >/dev/null 2>&1
            else
                # Нет бинаря sing-box — пропускаем валидацию
                return 0
            fi
            ;;
        *) return 1 ;;
    esac
}

# Get validation error message (stderr)
validate_config_stderr() {
    _svc="$1"
    _tmp="$2"
    case "$_svc" in
        stubby|stubby-family)
            stubby -C "$_tmp" -i 2>&1
            ;;
        dnsmasq|dnsmasq-family)
            dnsmasq --test -C "$_tmp" 2>&1
            ;;
        sing-box)
            if command -v sing-box >/dev/null 2>&1; then
                sing-box check -c "$_tmp" 2>&1
            else
                echo "sing-box binary not found"
            fi
            ;;
        *) echo "Unknown service" ;;
    esac
}

# GET: output JSON { "config": ["line1", ...], "file_path": "..." }
route_get() {
    _svc="$1"
    _path="$(get_config_path "$_svc")"
    [ -z "$_path" ] && { status_header 404; cgi_header; printf '{"error":"Not found"}\n'; return 0; }
    _path_esc="$(json_esc "$_path")"
    cgi_header
    printf '{"config":'
    if [ -f "$_path" ]; then
        first=1
        printf '['
        while IFS= read -r line || [ -n "$line" ]; do
            [ "$first" -eq 1 ] && first=0 || printf ','
            line_esc="$(json_esc "$line")"
            printf '"%s"' "$line_esc"
        done < "$_path"
        printf ']'
    else
        printf '[]'
    fi
    printf ',"file_path":"%s"}\n' "$_path_esc"
}

# POST: body JSON { "config": "..." }; validate, save, output { success, error?, message? }
route_post() {
    _svc="$1"
    _path="$(get_config_path "$_svc")"
    [ -z "$_path" ] && { status_header 404; cgi_header; printf '{"success":false,"error":"Not found"}\n'; return 0; }
    body="$(read_body)"
    [ -z "$body" ] && { status_header 400; cgi_header; printf '{"success":false,"error":"No body"}\n'; return 0; }
    if ! command -v jq >/dev/null 2>&1; then
        status_header 503
        cgi_header
        printf '{"success":false,"error":"jq not found. Install with: opkg install jq"}\n'
        return 0
    fi
    config_content="$(printf '%s' "$body" | jq -r '.config // empty')"
    # jq -r '.config' returns raw string; if config is missing we get empty
    if [ -z "$config_content" ] && [ "$(printf '%s' "$body" | jq -r 'has("config")')" = "false" ]; then
        status_header 400
        cgi_header
        printf '{"success":false,"error":"No configuration data provided"}\n'
        return 0
    fi
    # Для sing-box: убрать недопустимые символы; затем форматировать через jq, чтобы конфиг был читаемым
    if [ "$_svc" = "sing-box" ] && [ -n "$config_content" ]; then
        debug_singbox_config "$body" "$config_content"
        config_content="$(printf '%s' "$config_content" | tr -d '\000-\011\013\014\016-\037\177')"
        _pretty="$(printf '%s' "$config_content" | jq '.' 2>/dev/null)"
        [ -n "$_pretty" ] && config_content="$_pretty"
    fi
    _dir="$(dirname "$_path")"
    _tmp="${_path}.tmp"
    mkdir -p "$_dir" 2>/dev/null || true
    printf '%s' "$config_content" > "$_tmp" 2>/dev/null || {
        status_header 500
        cgi_header
        printf '{"success":false,"error":"Failed to write temp file"}\n'
        return 0
    }
    if ! validate_config "$_svc" "$_tmp"; then
        err_msg="$(validate_config_stderr "$_svc" "$_tmp")"
        if [ "$_svc" = "sing-box" ] && [ "${DEBUG_SINGBOX_ACTIVE:-0}" = "1" ]; then
            _log="/opt/var/log/allow/singbox-config-debug.log"
            _vf="validate failed: $(echo "$err_msg" | tr '\n' ' ')"
            printf '%s\n' "$_vf" >>"$_log" 2>/dev/null || true
            printf '%s\n' "$_vf" >&2
        fi
        err_esc="$(json_esc "$err_msg")"
        rm -f "$_tmp" 2>/dev/null || true
        status_header 400
        cgi_header
        printf '{"success":false,"error":"%s","message":"Configuration has errors"}\n' "$err_esc"
        return 0
    fi
    mv -f "$_tmp" "$_path" 2>/dev/null || {
        status_header 500
        cgi_header
        printf '{"success":false,"error":"Failed to save file"}\n'
        rm -f "$_tmp" 2>/dev/null || true
        return 0
    }
    cgi_header
    printf '{"success":true,"message":"Configuration saved and validated"}\n'
}

# Main dispatch
case "$PATH_INFO" in
    stubby/config/full)
        if [ "$REQUEST_METHOD" = "GET" ]; then
            route_get stubby
        elif [ "$REQUEST_METHOD" = "POST" ]; then
            route_post stubby
        else
            status_header 405
            cgi_header
            printf '{"error":"Method not allowed"}\n'
        fi
        ;;
    stubby-family/config/full)
        if [ "$REQUEST_METHOD" = "GET" ]; then
            route_get stubby-family
        elif [ "$REQUEST_METHOD" = "POST" ]; then
            route_post stubby-family
        else
            status_header 405
            cgi_header
            printf '{"error":"Method not allowed"}\n'
        fi
        ;;
    dnsmasq/config/full)
        if [ "$REQUEST_METHOD" = "GET" ]; then
            route_get dnsmasq
        elif [ "$REQUEST_METHOD" = "POST" ]; then
            route_post dnsmasq
        else
            status_header 405
            cgi_header
            printf '{"error":"Method not allowed"}\n'
        fi
        ;;
    dnsmasq-family/config/full)
        if [ "$REQUEST_METHOD" = "GET" ]; then
            route_get dnsmasq-family
        elif [ "$REQUEST_METHOD" = "POST" ]; then
            route_post dnsmasq-family
        else
            status_header 405
            cgi_header
            printf '{"error":"Method not allowed"}\n'
        fi
        ;;
    sing-box/config/full)
        if [ "$REQUEST_METHOD" = "GET" ]; then
            route_get sing-box
        elif [ "$REQUEST_METHOD" = "POST" ]; then
            route_post sing-box
        else
            status_header 405
            cgi_header
            printf '{"error":"Method not allowed"}\n'
        fi
        ;;
    *)
        status_header 404
        cgi_header
        printf '{"error":"Not found"}\n'
        ;;
esac
