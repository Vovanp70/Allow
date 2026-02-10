#!/bin/sh
#
# CGI dispatcher for allow monitor API (shell, no Python).
# Reads PATH_INFO, REQUEST_METHOD; dispatches to manage.d scripts; outputs JSON.
# Без токена: доступ только с локальной сети роутера.
#
# lighttpd CGI runs with minimal PATH; ensure tr, sed, dirname etc. are found
PATH="/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin"; export PATH

CONFIG_DIR="${CONFIG_DIR:-/opt/etc/allow/monitor}"
MANAGED_DIR="${MANAGED_DIR:-/opt/etc/allow/manage.d/keenetic-entware}"
AUTOSTART_SCRIPT="${MANAGED_DIR}/autostart.sh"
ETC_ALLOW="${ETC_ALLOW:-/opt/etc/allow}"
DEBUG_LOG="/opt/var/log/allow/monitor/cgi_debug.log"

# --- Dnsmasq log and config paths (same as manage.d) ---
DNSMASQ_LOG="/opt/var/log/allow/dnsmasq.log"
DNSMASQ_FAMILY_LOG="/opt/var/log/allow/dnsmasq-family.log"
DNSMASQ_CONF="/opt/etc/allow/dnsmasq-full/dnsmasq.conf"
DNSMASQ_FAMILY_CONF="/opt/etc/allow/dnsmasq-full/dnsmasq-family.conf"
STUBBY_LOG="/opt/var/log/allow/stubby.log"
STUBBY_FAMILY_LOG="/opt/var/log/allow/stubby-family.log"
SINGBOX_LOG="/opt/var/log/allow/sing-box/sing-box.log"
SYNC_ALLOW_LOG="/opt/var/log/allow/sync-allow-lists.log"
SYNC_SCRIPT="/opt/etc/allow/dnsmasq-full/sync-allow-lists.sh"

export ETC_ALLOW

# --- Read env (save raw for debug) ---
PATH_INFO_RAW="${PATH_INFO:-}"
PATH_INFO="$(echo "${PATH_INFO:-}" | tr -d '\r\n' | sed 's#^/##;s#/$##')"
# Fallback: lighttpd url.rewrite-once may not set PATH_INFO; derive from REQUEST_URI
if [ -z "$PATH_INFO" ] && [ -n "${REQUEST_URI:-}" ]; then
    _uri="$(echo "${REQUEST_URI}" | tr -d '\r\n' | sed 's#?.*##')"
    case "$_uri" in
        /api/*) PATH_INFO="${_uri#/api/}" ;;
        /cgi-bin/api.cgi/*) PATH_INFO="${_uri#/cgi-bin/api.cgi/}" ;;
        *) ;;
    esac
    PATH_INFO="$(echo "$PATH_INFO" | sed 's#^/##;s#/$##')"
fi
REQUEST_METHOD="$(echo "${REQUEST_METHOD:-GET}" | tr 'a-z' 'A-Z')"
CONTENT_LENGTH="${CONTENT_LENGTH:-0}"

# --- Read POST body (stdin, CONTENT_LENGTH bytes) ---
read_body() {
    [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null || { echo ""; return 0; }
    head -c "$CONTENT_LENGTH" 2>/dev/null || dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null || true
}

# --- JSON escape (simple: " and \ ) ---
json_esc() {
    printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g;s/	/\\t/g'
}

# --- Output JSON response ---
cgi_header() {
    printf 'Content-Type: application/json; charset=utf-8\r\n\r\n'
}
status_header() {
    printf 'Status: %s\r\n' "$1"
}
json_404() {
    # #region agent log
    [ -n "$DEBUG_LOG" ] && mkdir -p "$(dirname "$DEBUG_LOG")" 2>/dev/null && echo "resp 404 path=$path" >> "$DEBUG_LOG" 2>/dev/null || true
    # #endregion
    status_header 404
    cgi_header
    printf '{"error":"Not found"}\n'
}
json_500() {
    status_header 500
    cgi_header
    err="$(json_esc "$1")"
    printf '{"error":"%s"}\n' "$err"
}

# --- Parse KEY=value from script output ---
get_kv() {
    _key="$1"
    _out="$2"
    echo "$_out" | grep "^${_key}=" | head -1 | sed "s/^${_key}=//"
}

# --- Autostart status: output "true" or "false". If script missing/error, return "true" so we do not show "Отключен" by mistake.
get_autostart_active() {
    _comp="$1"
    [ -x "$AUTOSTART_SCRIPT" ] || { echo "true"; return 0; }
    _out="$(cd "$(dirname "$AUTOSTART_SCRIPT")" 2>/dev/null && sh "$AUTOSTART_SCRIPT" "$_comp" status 2>/dev/null)" || true
    _out="$(echo "$_out" | tr -d '\r\n' | head -1)"
    [ "$_out" = "active" ] && { echo "true"; return 0; }
    echo "false"
}

# --- /system/info GET ---
route_system_info() {
    script="${MANAGED_DIR}/system-info.sh"
    if [ ! -x "$script" ]; then
        cgi_header
        printf '{"internet":{"status":false,"connected":false},"external_ip":null}\n'
        return 0
    fi
    out="$("$script" 2>/dev/null)" || true
    internet="$(get_kv "INTERNET" "$out")"
    external_ip="$(get_kv "EXTERNAL_IP" "$out")"
    if [ "$internet" = "ok" ]; then
        conn="true"
    else
        conn="false"
    fi
    [ -z "$external_ip" ] && external_ip="null" || external_ip="$(json_esc "$external_ip")"
    cgi_header
    if [ "$external_ip" = "null" ]; then
        printf '{"internet":{"status":%s,"connected":%s},"external_ip":null}\n' "$conn" "$conn"
    else
        printf '{"internet":{"status":%s,"connected":%s},"external_ip":"%s"}\n' "$conn" "$conn" "$external_ip"
    fi
}

# --- /dns-mode GET ---
route_dns_mode_get() {
    script="${MANAGED_DIR}/dns-mode.sh"
    if [ ! -x "$script" ]; then
        cgi_header
        printf '{"mode":"adblock"}\n'
        return 0
    fi
    mode="$(cd "$(dirname "$script")" 2>/dev/null && sh "$script" status 2>/dev/null)" || mode="adblock"
    mode="$(echo "$mode" | tr -d '\r\n' | head -1)"
    [ -z "$mode" ] && mode="adblock"
    mode_esc="$(json_esc "$mode")"
    cgi_header
    printf '{"mode":"%s"}\n' "$mode_esc"
}

# --- /dns-mode POST ---
route_dns_mode_post() {
    body="$1"
    mode=""
    if [ -n "$body" ]; then
        mode="$(echo "$body" | grep -o '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:"\([^"]*\)".*/\1/')"
    fi
    [ -z "$mode" ] && mode="adblock"
    case "$mode" in
        adblock|stable) ;;
        *) status_header 400; cgi_header; printf '{"error":"Invalid mode","success":false}\n'; return 0 ;;
    esac
    script="${MANAGED_DIR}/dns-mode.sh"
    if [ ! -x "$script" ]; then
        status_header 503
        cgi_header
        printf '{"success":false,"error":"dns-mode script not found"}\n'
        return 0
    fi
    dir="$(dirname "$script")"
    errout="$(cd "$dir" 2>/dev/null && sh "$script" set "$mode" 2>&1)" || true
    out="$(cd "$dir" 2>/dev/null && sh "$script" status 2>/dev/null)" || true
    out_mode="$(echo "$out" | tr -d '\r\n' | head -1)"
    [ -z "$out_mode" ] && out_mode="$mode"
    dns_check=""
    if echo "$errout" | grep -q "STUBBY_CHECK="; then
        line="$(echo "$errout" | grep "STUBBY_CHECK=" | head -1)"
        rest="${line#STUBBY_CHECK=}"
        if [ "$rest" = "ok" ]; then
            dns_check=',"dns_check":{"ok":true}'
        else
            err="${rest#fail:}"
            err_esc="$(json_esc "$err")"
            dns_check=",\"dns_check\":{\"ok\":false,\"error\":\"$err_esc\"}"
        fi
    fi
    cgi_header
    mode_esc="$(json_esc "$out_mode")"
    printf '{"success":true,"mode":"%s"%s}\n' "$mode_esc" "$dns_check"
}

# --- /settings/children-filter GET ---
route_children_filter_get() {
    stubby_as="$(get_autostart_active "stubby-family")"
    dnsmasq_as="$(get_autostart_active "dnsmasq-full-family")"
    stubby_out="$("${MANAGED_DIR}/stubby-family.sh" status 2>/dev/null)" || true
    stubby_status="$(get_kv "STATUS" "$stubby_out")"
    stubby_running="false"
    [ "$stubby_status" = "running" ] && stubby_running="true"
    dnsmasq_out="$("${MANAGED_DIR}/dnsmasq-family.sh" status 2>/dev/null)" || true
    dnsmasq_status="$(get_kv "STATUS" "$dnsmasq_out")"
    dnsmasq_running="false"
    [ "$dnsmasq_status" = "running" ] && dnsmasq_running="true"
    enabled="false"
    [ "$stubby_as" = "true" ] && [ "$stubby_running" = "true" ] && [ "$dnsmasq_as" = "true" ] && [ "$dnsmasq_running" = "true" ] && enabled="true"
    cgi_header
    printf '{"enabled":%s}\n' "$enabled"
}

# --- /settings/children-filter POST ---
route_children_filter_post() {
    _body="$1"
    _enabled="false"
    echo "$_body" | grep -q '"enabled"[[:space:]]*:[[:space:]]*true' && _enabled="true"
    [ ! -x "$AUTOSTART_SCRIPT" ] && status_header 503 && cgi_header && printf '{"success":false,"message":"autostart.sh not found"}\n' && return 0
    _dir="$(dirname "$AUTOSTART_SCRIPT")"
    if [ "$_enabled" = "true" ]; then
        (cd "$_dir" 2>/dev/null && sh "$AUTOSTART_SCRIPT" "dnsmasq-full-family" activate 2>/dev/null) || true
        (cd "$_dir" 2>/dev/null && sh "$AUTOSTART_SCRIPT" "stubby-family" activate 2>/dev/null) || true
        _msg="Фильтрация контента для детей включена"
    else
        (cd "$_dir" 2>/dev/null && sh "$AUTOSTART_SCRIPT" "stubby-family" deactivate 2>/dev/null) || true
        (cd "$_dir" 2>/dev/null && sh "$AUTOSTART_SCRIPT" "dnsmasq-full-family" deactivate 2>/dev/null) || true
        _msg="Фильтрация контента для детей выключена"
    fi
    _msg_esc="$(json_esc "$_msg")"
    cgi_header
    printf '{"success":true,"message":"%s"}\n' "$_msg_esc"
}

# --- /sync-allow-lists/status GET ---
route_sync_allow_status() {
    enabled="false"
    last_update="null"
    if [ -x "$SYNC_SCRIPT" ]; then
        _out="$(sh "$SYNC_SCRIPT" autoupdate status 2>/dev/null)" || true
        echo "$_out" | grep -q "включено" && enabled="true"
    fi
    if [ -f "$SYNC_ALLOW_LOG" ]; then
        _line="$(grep "sync-allow-lists finished" "$SYNC_ALLOW_LOG" 2>/dev/null | tail -1)"
        if [ -n "$_line" ]; then
            _dt="$(echo "$_line" | sed -n 's/.*finished \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\).*/\1/p')"
            [ -n "$_dt" ] && last_update="\"$(json_esc "$_dt")\""
        fi
    fi
    cgi_header
    printf '{"enabled":%s,"last_update":%s}\n' "$enabled" "$last_update"
}

# --- /sync-allow-lists/autoupdate POST ---
route_sync_allow_autoupdate_post() {
    _body="$1"
    _enabled="false"
    echo "$_body" | grep -q '"enabled"[[:space:]]*:[[:space:]]*true' && _enabled="true"
    [ ! -x "$SYNC_SCRIPT" ] && status_header 503 && cgi_header && printf '{"success":false,"message":"sync-allow-lists.sh not found"}\n' && return 0
    if [ "$_enabled" = "true" ]; then
        sh "$SYNC_SCRIPT" autoupdate enable >/dev/null 2>&1 || true
    else
        sh "$SYNC_SCRIPT" autoupdate disable >/dev/null 2>&1 || true
    fi
    cgi_header
    printf '{"success":true}\n'
}

# --- /sync-allow-lists/run POST ---
route_sync_allow_run() {
    [ ! -x "$SYNC_SCRIPT" ] && status_header 503 && cgi_header && printf '{"success":false,"message":"sync-allow-lists.sh not found"}\n' && return 0
    (nohup sh "$SYNC_SCRIPT" >/dev/null 2>&1 &) 2>/dev/null || true
    _msg_esc="$(json_esc "Обновление запущено")"
    cgi_header
    printf '{"success":true,"message":"%s"}\n' "$_msg_esc"
}

# --- /sync-allow-lists/logs GET ---
route_sync_allow_logs() {
    lines="$(get_query_lines)"
    cgi_header
    if [ ! -f "$SYNC_ALLOW_LOG" ] || [ ! -s "$SYNC_ALLOW_LOG" ]; then
        printf '{"logs":[],"message":"Логи пусты"}\n'
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        tail -n "$lines" "$SYNC_ALLOW_LOG" 2>/dev/null | jq -R . | jq -s '{logs: .}'
    else
        tail -n "$lines" "$SYNC_ALLOW_LOG" 2>/dev/null | awk '
            BEGIN { printf "{\"logs\":["; first=1 }
            function json_esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/\r/,"\\r",s); gsub(/\n/,"\\n",s); return s }
            { s=json_esc($0); if (!first) printf ","; first=0; printf "\""; printf "%s", s; printf "\"" }
            END { printf "]}\n" }
        '
    fi
}

# --- /stubby/status GET ---
route_stubby_status() {
    script="${MANAGED_DIR}/stubby.sh"
    if [ ! -x "$script" ]; then
        logging_out=""
        [ -x "${MANAGED_DIR}/allow-logging.sh" ] && logging_out="$("${MANAGED_DIR}/allow-logging.sh" stubby status 2>/dev/null)" || true
        log_enabled="$(get_kv "LOGGING_ENABLED" "$logging_out")"
        log_file="$(get_kv "LOG_FILE" "$logging_out")"
        [ -z "$log_file" ] && log_file="$STUBBY_LOG"
        logging_enabled="false"
        [ "$log_enabled" = "yes" ] && logging_enabled="true"
        log_file_esc="$(json_esc "$log_file")"
        autostart_active="$(get_autostart_active "stubby")"
        cgi_header
        printf '{"running":false,"port_open":false,"pid":"","port":"41500","status":"stopped","logging_enabled":%s,"log_file":"%s","autostart_active":%s}\n' "$logging_enabled" "$log_file_esc" "$autostart_active"
        return 0
    fi
    out="$("$script" status 2>/dev/null)" || true
    logging_out=""
    [ -x "${MANAGED_DIR}/allow-logging.sh" ] && logging_out="$("${MANAGED_DIR}/allow-logging.sh" stubby status 2>/dev/null)" || true
    status="$(get_kv "STATUS" "$out")"
    port="$(get_kv "PORT" "$out")"
    pid="$(get_kv "PID" "$out")"
    port_open="$(get_kv "PORT_OPEN" "$out")"
    config_port="$(get_kv "CONFIG_PORT" "$out")"
    active_port="$(get_kv "ACTIVE_PORT" "$out")"
    effective_port="$(get_kv "EFFECTIVE_PORT" "$out")"
    mismatch="$(get_kv "MISMATCH" "$out")"
    log_enabled="$(get_kv "LOGGING_ENABLED" "$logging_out")"
    log_file="$(get_kv "LOG_FILE" "$logging_out")"
    [ -z "$status" ] && status="stopped"
    [ -z "$port" ] && port="41500"
    [ -z "$port_open" ] && port_open="no"
    [ -z "$config_port" ] && config_port="$port"
    [ -z "$active_port" ] && active_port="$port"
    [ -z "$effective_port" ] && effective_port="$port"
    [ -z "$mismatch" ] && mismatch="no"
    [ -z "$log_file" ] && log_file="$STUBBY_LOG"
    running="false"
    [ "$status" = "running" ] && running="true"
    port_open_bool="false"
    [ "$port_open" = "yes" ] && port_open_bool="true"
    mismatch_bool="false"
    [ "$mismatch" = "yes" ] && mismatch_bool="true"
    logging_enabled="false"
    [ "$log_enabled" = "yes" ] && logging_enabled="true"
    [ -z "$config_port" ] && config_port="41500"
    [ -z "$active_port" ] && active_port="$port"
    [ -z "$effective_port" ] && effective_port="$port"
    pid_esc="$(json_esc "$pid")"
    log_file_esc="$(json_esc "$log_file")"
    autostart_active="$(get_autostart_active "stubby")"
    cgi_header
    printf '{"running":%s,"port_open":%s,"pid":"%s","port":"%s","config_port":%s,"active_port":%s,"effective_port":%s,"mismatch":%s,"status":"%s","logging_enabled":%s,"log_file":"%s","autostart_active":%s}\n' \
        "$running" "$port_open_bool" "$pid_esc" "$port" "$config_port" "$active_port" "$effective_port" \
        "$mismatch_bool" "$status" "$logging_enabled" "$log_file_esc" "$autostart_active"
}

# --- /stubby/start, /stop, /restart POST ---
route_stubby_action() {
    action="$1"
    script="${MANAGED_DIR}/stubby.sh"
    if [ ! -x "$script" ]; then
        status_header 503
        cgi_header
        printf '{"success":false,"message":"stubby script not found"}\n'
        return 0
    fi
    out="$("$script" "$action" 2>/dev/null)" || true
    success="$(get_kv "SUCCESS" "$out")"
    message="$(get_kv "MESSAGE" "$out")"
    [ -z "$success" ] && success="no"
    [ -z "$message" ] && message="Done"
    msg_esc="$(json_esc "$message")"
    if [ "$success" = "yes" ]; then
        cgi_header
        printf '{"success":true,"message":"%s"}\n' "$msg_esc"
    else
        status_header 500
        cgi_header
        printf '{"success":false,"message":"%s"}\n' "$msg_esc"
    fi
}

# --- /stubby-family/status GET ---
route_stubby_family_status() {
    script="${MANAGED_DIR}/stubby-family.sh"
    if [ ! -x "$script" ]; then
        logging_out=""
        [ -x "${MANAGED_DIR}/allow-logging.sh" ] && logging_out="$("${MANAGED_DIR}/allow-logging.sh" stubby-family status 2>/dev/null)" || true
        log_enabled="$(get_kv "LOGGING_ENABLED" "$logging_out")"
        log_file="$(get_kv "LOG_FILE" "$logging_out")"
        [ -z "$log_file" ] && log_file="$STUBBY_FAMILY_LOG"
        logging_enabled="false"
        [ "$log_enabled" = "yes" ] && logging_enabled="true"
        log_file_esc="$(json_esc "$log_file")"
        autostart_active="$(get_autostart_active "stubby-family")"
        cgi_header
        printf '{"running":false,"port_open":false,"pid":"","port":"41501","status":"stopped","logging_enabled":%s,"log_file":"%s","autostart_active":%s}\n' "$logging_enabled" "$log_file_esc" "$autostart_active"
        return 0
    fi
    out="$("$script" status 2>/dev/null)" || true
    logging_out=""
    [ -x "${MANAGED_DIR}/allow-logging.sh" ] && logging_out="$("${MANAGED_DIR}/allow-logging.sh" stubby-family status 2>/dev/null)" || true
    status="$(get_kv "STATUS" "$out")"
    port="$(get_kv "PORT" "$out")"
    pid="$(get_kv "PID" "$out")"
    port_open="$(get_kv "PORT_OPEN" "$out")"
    config_port="$(get_kv "CONFIG_PORT" "$out")"
    active_port="$(get_kv "ACTIVE_PORT" "$out")"
    effective_port="$(get_kv "EFFECTIVE_PORT" "$out")"
    mismatch="$(get_kv "MISMATCH" "$out")"
    log_enabled="$(get_kv "LOGGING_ENABLED" "$logging_out")"
    log_file="$(get_kv "LOG_FILE" "$logging_out")"
    [ -z "$status" ] && status="stopped"
    [ -z "$port" ] && port="41501"
    [ -z "$port_open" ] && port_open="no"
    [ -z "$config_port" ] && config_port="$port"
    [ -z "$active_port" ] && active_port="$port"
    [ -z "$effective_port" ] && effective_port="$port"
    [ -z "$mismatch" ] && mismatch="no"
    [ -z "$log_file" ] && log_file="$STUBBY_FAMILY_LOG"
    running="false"
    [ "$status" = "running" ] && running="true"
    port_open_bool="false"
    [ "$port_open" = "yes" ] && port_open_bool="true"
    mismatch_bool="false"
    [ "$mismatch" = "yes" ] && mismatch_bool="true"
    logging_enabled="false"
    [ "$log_enabled" = "yes" ] && logging_enabled="true"
    pid_esc="$(json_esc "$pid")"
    log_file_esc="$(json_esc "$log_file")"
    autostart_active="$(get_autostart_active "stubby-family")"
    cgi_header
    printf '{"running":%s,"port_open":%s,"pid":"%s","port":"%s","config_port":%s,"active_port":%s,"effective_port":%s,"mismatch":%s,"status":"%s","logging_enabled":%s,"log_file":"%s","autostart_active":%s}\n' \
        "$running" "$port_open_bool" "$pid_esc" "$port" "$config_port" "$active_port" "$effective_port" \
        "$mismatch_bool" "$status" "$logging_enabled" "$log_file_esc" "$autostart_active"
}

# --- /stubby-family/start, /stop, /restart POST ---
route_stubby_family_action() {
    action="$1"
    script="${MANAGED_DIR}/stubby-family.sh"
    if [ ! -x "$script" ]; then
        status_header 503
        cgi_header
        printf '{"success":false,"message":"stubby-family script not found"}\n'
        return 0
    fi
    out="$("$script" "$action" 2>/dev/null)" || true
    success="$(get_kv "SUCCESS" "$out")"
    message="$(get_kv "MESSAGE" "$out")"
    [ -z "$success" ] && success="no"
    [ -z "$message" ] && message="Done"
    msg_esc="$(json_esc "$message")"
    if [ "$success" = "yes" ]; then
        cgi_header
        printf '{"success":true,"message":"%s"}\n' "$msg_esc"
    else
        status_header 500
        cgi_header
        printf '{"success":false,"message":"%s"}\n' "$msg_esc"
    fi
}

# --- /singbox/status GET ---
route_singbox_status() {
    script="${MANAGED_DIR}/sing-box.sh"
    if [ ! -x "$script" ]; then
        autostart_active="$(get_autostart_active "sing-box")"
        cgi_header
        printf '{"running":false,"pid":"","status":"stopped","autostart_active":%s}\n' "$autostart_active"
        return 0
    fi
    out="$("$script" status 2>/dev/null)" || true
    status="$(get_kv "STATUS" "$out")"
    pid="$(get_kv "PID" "$out")"
    [ -z "$status" ] && status="stopped"
    [ -z "$pid" ] && pid=""
    running="false"
    [ "$status" = "running" ] && running="true"
    pid_esc="$(json_esc "$pid")"
    status_esc="$(json_esc "$status")"
    autostart_active="$(get_autostart_active "sing-box")"
    cgi_header
    printf '{"running":%s,"pid":"%s","status":"%s","autostart_active":%s}\n' "$running" "$pid_esc" "$status_esc" "$autostart_active"
}

# --- /singbox/start, /stop, /restart POST ---
route_singbox_action() {
    action="$1"
    script="${MANAGED_DIR}/sing-box.sh"
    if [ ! -x "$script" ]; then
        status_header 503
        cgi_header
        printf '{"success":false,"message":"sing-box script not found"}\n'
        return 0
    fi
    out="$("$script" "$action" 2>/dev/null)" || true
    success="$(get_kv "SUCCESS" "$out")"
    message="$(get_kv "MESSAGE" "$out")"
    [ -z "$success" ] && success="no"
    [ -z "$message" ] && message="Done"
    msg_esc="$(json_esc "$message")"
    if [ "$success" = "yes" ]; then
        cgi_header
        printf '{"success":true,"message":"%s"}\n' "$msg_esc"
    else
        status_header 500
        cgi_header
        printf '{"success":false,"message":"%s"}\n' "$msg_esc"
    fi
}

# --- Sing-box logs ---
route_singbox_logs() {
    lines="$(get_query_lines)"
    warning=""
    out=""
    log_enabled="no"
    log_file="$SINGBOX_LOG"
    if [ -x "${MANAGED_DIR}/allow-logging.sh" ]; then
        out="$("${MANAGED_DIR}/allow-logging.sh" sing-box status 2>/dev/null)" || out=""
        tmp_enabled="$(get_kv "LOGGING_ENABLED" "$out")"
        [ -n "$tmp_enabled" ] && log_enabled="$tmp_enabled"
        tmp_log="$(get_kv "LOG_FILE" "$out")"
        [ -n "$tmp_log" ] && log_file="$tmp_log"
    fi
    [ "$log_enabled" = "yes" ] || warning='Логирование выключено'
    cgi_header
    if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
        if [ -n "$warning" ]; then
            warn_esc="$(json_esc "$warning")"
            printf '{"logs":[],"message":"Логи пусты","warning":"%s"}\n' "$warn_esc"
        else
            printf '{"logs":[],"message":"Логи пусты"}\n'
        fi
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        if [ -n "$warning" ]; then
            tail -n "$lines" "$log_file" 2>/dev/null | jq -R . | jq -s --arg w "$warning" 'if $w != "" then {logs: ., warning: $w} else {logs: .} end'
        else
            tail -n "$lines" "$log_file" 2>/dev/null | jq -R . | jq -s '{logs: .}'
        fi
    else
        export WARN_ESC="$warning"
        tail -n "$lines" "$log_file" 2>/dev/null | awk '
            BEGIN { printf "{\"logs\":["; first=1; w=ENVIRON["WARN_ESC"] }
            function json_esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/\r/,"\\r",s); gsub(/\n/,"\\n",s); return s }
            { s=json_esc($0); if (!first) printf ","; first=0; printf "\""; printf "%s", s; printf "\"" }
            END {
                if (w != "") {
                    printf "],\"warning\":\""; t=json_esc(w); printf "%s", t; printf "\"}\n"
                } else {
                    printf "]}\n"
                }
            }
        '
    fi
}

route_singbox_logs_size() {
    cgi_header
    log_file="$SINGBOX_LOG"
    if [ -x "${MANAGED_DIR}/allow-logging.sh" ]; then
        out="$("${MANAGED_DIR}/allow-logging.sh" sing-box status 2>/dev/null)" || out=""
        tmp_log="$(get_kv "LOG_FILE" "$out")"
        [ -n "$tmp_log" ] && log_file="$tmp_log"
    fi
    if [ ! -f "$log_file" ]; then
        printf '{"size":0,"size_formatted":"0 B"}\n'
        return 0
    fi
    sz="$(wc -c < "$log_file" 2>/dev/null)" || sz=0
    [ -z "$sz" ] && sz=0
    fmt="$(format_size "$sz")"
    fmt_esc="$(json_esc "$fmt")"
    printf '{"size":%s,"size_formatted":"%s"}\n' "$sz" "$fmt_esc"
}

route_singbox_logs_clear() {
    cgi_header
    log_file="$SINGBOX_LOG"
    if [ -x "${MANAGED_DIR}/allow-logging.sh" ]; then
        out="$("${MANAGED_DIR}/allow-logging.sh" sing-box status 2>/dev/null)" || out=""
        tmp_log="$(get_kv "LOG_FILE" "$out")"
        [ -n "$tmp_log" ] && log_file="$tmp_log"
    fi
    if [ -f "$log_file" ]; then
        : > "$log_file" 2>/dev/null || true
    fi
    printf '{"success":true}\n'
}

# --- Sing-box logging toggle ---
route_singbox_logging_get() {
    enabled="false"
    if [ -x "${MANAGED_DIR}/allow-logging.sh" ]; then
        out="$("${MANAGED_DIR}/allow-logging.sh" sing-box status 2>/dev/null)" || out=""
        log_enabled="$(get_kv "LOGGING_ENABLED" "$out")"
        [ "$log_enabled" = "yes" ] && enabled="true"
    fi
    cgi_header
    printf '{"enabled":%s}\n' "$enabled"
}

route_singbox_logging_post() {
    _enabled="false"
    [ -n "$body" ] && echo "$body" | grep -q '"enabled"[ \t]*:[ \t]*true' && _enabled="true"
    if [ ! -x "${MANAGED_DIR}/allow-logging.sh" ]; then
        status_header 503
        cgi_header
        printf '{"success":false,"message":"allow-logging.sh not found"}\n'
        return 0
    fi
    if [ "$_enabled" = "true" ]; then
        out="$("${MANAGED_DIR}/allow-logging.sh" sing-box start 2>/dev/null)" || out=""
    else
        out="$("${MANAGED_DIR}/allow-logging.sh" sing-box stop 2>/dev/null)" || out=""
    fi
    success="$(get_kv "SUCCESS" "$out")"
    message="$(get_kv "MESSAGE" "$out")"
    [ -z "$success" ] && success="no"
    [ -z "$message" ] && message="Done"
    msg_esc="$(json_esc "$message")"
    if [ "$success" = "yes" ]; then
        cgi_header
        printf '{"success":true,"message":"%s"}\n' "$msg_esc"
    else
        status_header 500
        cgi_header
        printf '{"success":false,"message":"%s"}\n' "$msg_esc"
    fi
}

# --- /dnsmasq/status GET ---
route_dnsmasq_status() {
    script="${MANAGED_DIR}/dnsmasq.sh"
    if [ ! -x "$script" ]; then
        autostart_active="$(get_autostart_active "dnsmasq-full")"
        cgi_header
        printf '{"running":false,"port_open":false,"pid":"","port":"5300","status":"stopped","logging_enabled":false,"log_file":"/opt/var/log/allow/dnsmasq.log","autostart_active":%s}\n' "$autostart_active"
        return 0
    fi
    out="$("$script" status 2>/dev/null)" || true
    status="$(get_kv "STATUS" "$out")"
    port="$(get_kv "PORT" "$out")"
    pid="$(get_kv "PID" "$out")"
    port_open="$(get_kv "PORT_OPEN" "$out")"
    config_port="$(get_kv "CONFIG_PORT" "$out")"
    active_port="$(get_kv "ACTIVE_PORT" "$out")"
    effective_port="$(get_kv "EFFECTIVE_PORT" "$out")"
    mismatch="$(get_kv "MISMATCH" "$out")"
    logging_enabled="$(get_kv "LOGGING_ENABLED" "$out")"
    log_file="$(get_kv "LOG_FILE" "$out")"
    [ -z "$status" ] && status="stopped"
    [ -z "$port" ] && port="5300"
    [ -z "$port_open" ] && port_open="no"
    [ -z "$config_port" ] && config_port="$port"
    [ -z "$active_port" ] && active_port="$port"
    [ -z "$effective_port" ] && effective_port="$port"
    [ -z "$logging_enabled" ] && logging_enabled="no"
    [ -z "$log_file" ] && log_file="/opt/var/log/allow/dnsmasq.log"
    running="false"
    [ "$status" = "running" ] && running="true"
    port_open_bool="false"
    [ "$port_open" = "yes" ] && port_open_bool="true"
    mismatch_bool="false"
    [ "$mismatch" = "yes" ] && mismatch_bool="true"
    logging_bool="false"
    [ "$logging_enabled" = "yes" ] && logging_bool="true"
    pid_esc="$(json_esc "$pid")"
    log_file_esc="$(json_esc "$log_file")"
    autostart_active="$(get_autostart_active "dnsmasq-full")"
    cgi_header
    printf '{"running":%s,"port_open":%s,"pid":"%s","port":"%s","config_port":%s,"active_port":%s,"effective_port":%s,"mismatch":%s,"logging_enabled":%s,"log_file":"%s","status":"%s","autostart_active":%s}\n' \
        "$running" "$port_open_bool" "$pid_esc" "$port" "$config_port" "$active_port" "$effective_port" \
        "$mismatch_bool" "$logging_bool" "$log_file_esc" "$status" "$autostart_active"
}

# --- /dnsmasq/restart POST ---
route_dnsmasq_restart() {
    script="${MANAGED_DIR}/dnsmasq.sh"
    if [ ! -x "$script" ]; then
        status_header 503
        cgi_header
        printf '{"success":false,"message":"dnsmasq script not found"}\n'
        return 0
    fi
    out="$("$script" restart 2>/dev/null)" || true
    success="$(get_kv "SUCCESS" "$out")"
    message="$(get_kv "MESSAGE" "$out")"
    [ -z "$success" ] && success="no"
    [ -z "$message" ] && message="Done"
    msg_esc="$(json_esc "$message")"
    if [ "$success" = "yes" ]; then
        cgi_header
        printf '{"success":true,"message":"%s"}\n' "$msg_esc"
    else
        status_header 500
        cgi_header
        printf '{"success":false,"message":"%s"}\n' "$msg_esc"
    fi
}

# --- Autostart POST helper: body must contain "action":"activate" or "action":"deactivate"
route_autostart_post() {
    _comp="$1"
    _body="$2"
    _action=""
    echo "$_body" | grep -q '"action"[[:space:]]*:[[:space:]]*"activate"' && _action="activate"
    [ -z "$_action" ] && echo "$_body" | grep -q '"action"[[:space:]]*:[[:space:]]*"deactivate"' && _action="deactivate"
    if [ -z "$_action" ]; then
        status_header 400
        cgi_header
        printf '{"success":false,"error":"Missing or invalid action"}\n'
        return 0
    fi
    [ ! -x "$AUTOSTART_SCRIPT" ] && status_header 503 && cgi_header && printf '{"success":false,"message":"autostart.sh not found"}\n' && return 0
    _dir="$(dirname "$AUTOSTART_SCRIPT")"
    _out="$(cd "$_dir" 2>/dev/null && sh "$AUTOSTART_SCRIPT" "$_comp" "$_action" 2>&1)" || true
    _ret=$?
    _msg="$(echo "$_out" | head -1)"
    [ -z "$_msg" ] && _msg="Done"
    _msg_esc="$(json_esc "$_msg")"
    cgi_header
    if [ "$_ret" -eq 0 ]; then
        printf '{"success":true,"message":"%s"}\n' "$_msg_esc"
    else
        status_header 500
        printf '{"success":false,"message":"%s"}\n' "$_msg_esc"
    fi
}

route_dnsmasq_autostart() { route_autostart_post "dnsmasq-full" "$1"; }
route_dnsmasq_family_autostart() { route_autostart_post "dnsmasq-full-family" "$1"; }
route_stubby_autostart() { route_autostart_post "stubby" "$1"; }
route_stubby_family_autostart() { route_autostart_post "stubby-family" "$1"; }
route_singbox_autostart() { route_autostart_post "sing-box" "$1"; }

# --- /singbox/route-by-mark/marks GET (список mark из iptables-save | grep MARK) ---
route_singbox_route_by_mark_marks() {
    _marks=""
    _raw="$(iptables-save 2>/dev/null | grep MARK)" || true
    _marks="$(echo "$_raw" | sed -n 's/.*--set-xmark \(0x[0-9a-fA-F][0-9a-fA-F]*\)\/.*/\1/p'; echo "$_raw" | sed -n 's/.*--set-xndmmark \(0x[0-9a-fA-F][0-9a-fA-F]*\)\/.*/\1/p')"
    _marks="$(echo "$_marks" | grep -E '^0x[0-9a-fA-F]+$' | sort -u)"
    _json_marks=""
    _first=1
    for _m in $_marks; do
        [ -z "$_m" ] && continue
        if [ "$_first" = 1 ]; then
            _json_marks="\"$(json_esc "$_m")\""
            _first=0
        else
            _json_marks="${_json_marks},\"$(json_esc "$_m")\""
        fi
    done
    cgi_header
    printf '{"marks":[%s]}\n' "$_json_marks"
}

# --- /singbox/route-by-mark/iptables-rules GET (полный вывод iptables-save | grep MARK) ---
route_singbox_route_by_mark_iptables_rules() {
    _out="$(iptables-save 2>/dev/null | grep MARK)" || true
    [ -z "$_out" ] && _out="(пусто или команда недоступна)"
    _json_lines=""
    _first=1
    while IFS= read -r _line; do
        _esc="$(json_esc "$_line")"
        [ "$_first" = 1 ] && _first=0 || _json_lines="${_json_lines},"
        _json_lines="${_json_lines}\"${_esc}\""
    done <<EOF
$_out
EOF
    cgi_header
    printf '{"lines":[%s]}\n' "$_json_lines"
}

# --- /singbox/route-by-mark/status GET (текущий активный интерфейс из route-by-mark.state) ---
ROUTE_BY_MARK_STATE="/opt/etc/allow/route-by-mark.state"
route_singbox_route_by_mark_status() {
    _current="none"
    if [ -f "$ROUTE_BY_MARK_STATE" ]; then
        _line="$(grep '^IFACE_SRC=' "$ROUTE_BY_MARK_STATE" 2>/dev/null | head -1)"
        [ -n "$_line" ] && _current="${_line#IFACE_SRC=}"
    fi
    [ -z "$_current" ] && _current="none"
    cgi_header
    printf '{"current_iface":"%s"}\n' "$(json_esc "$_current")"
}

# --- /singbox/route-by-mark POST (addrule <iface> | delrule) ---
route_singbox_route_by_mark_post() {
    ROUTE_BY_MARK_SCRIPT="${ETC_ALLOW}/route-by-mark.sh"
    [ ! -x "$ROUTE_BY_MARK_SCRIPT" ] && [ -x "${ETC_ALLOW}/markalltovpn/route-by-mark.sh" ] && ROUTE_BY_MARK_SCRIPT="${ETC_ALLOW}/markalltovpn/route-by-mark.sh"
    [ ! -x "$ROUTE_BY_MARK_SCRIPT" ] && [ -f "${ETC_ALLOW}/markalltovpn/route-by-mark.sh" ] && ROUTE_BY_MARK_SCRIPT="${ETC_ALLOW}/markalltovpn/route-by-mark.sh"
    if [ ! -f "$ROUTE_BY_MARK_SCRIPT" ]; then
        status_header 503
        cgi_header
        printf '{"success":false,"error":"route-by-mark.sh not found"}\n'
        return 0
    fi
    _body="$(echo "$body" | tr -d '\n\r')"
    _action="$(echo "$_body" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    _iface="$(echo "$_body" | sed -n 's/.*"iface"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    _mark="$(echo "$_body" | sed -n 's/.*"mark"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    # Для обратной совместимости: если iface не передали, но есть mark — используем его как iface.
    [ -z "$_iface" ] && _iface="$_mark"
    _out=""
    case "$_action" in
        addrule|addiface|addmark)
            if [ -z "$_iface" ]; then
                status_header 400
                cgi_header
                printf '{"success":false,"error":"iface required for addrule"}\n'
                return 0
            fi
            _out="$("$ROUTE_BY_MARK_SCRIPT" addrule "$_iface" 2>&1)"
            _ret=$?
            ;;
        delrule|deliface|delmark)
            _out="$("$ROUTE_BY_MARK_SCRIPT" delrule 2>&1)"
            _ret=$?
            ;;
        *)
            status_header 400
            cgi_header
            printf '{"success":false,"error":"action must be addrule or delrule"}\n'
            return 0
            ;;
    esac
    cgi_header
    if command -v jq >/dev/null 2>&1; then
        _out_esc="$(printf '%s' "$_out" | jq -Rs .)"
    else
        _out_esc="$(json_esc "$_out")"
        _out_esc="\"$_out_esc\""
    fi
    if [ "$_ret" = 0 ]; then
        printf '{"success":true,"message":%s,"output":%s}\n' "$_out_esc" "$_out_esc"
    else
        printf '{"success":false,"error":%s,"output":%s}\n' "$_out_esc" "$_out_esc"
    fi
}

# --- /dnsmasq-family/status GET ---
route_dnsmasq_family_status() {
    script="${MANAGED_DIR}/dnsmasq-family.sh"
    if [ ! -x "$script" ]; then
        autostart_active="$(get_autostart_active "dnsmasq-full-family")"
        cgi_header
        printf '{"running":false,"port_open":false,"pid":"","port":"5301","status":"stopped","logging_enabled":false,"log_file":"/opt/var/log/allow/dnsmasq-family.log","autostart_active":%s}\n' "$autostart_active"
        return 0
    fi
    out="$("$script" status 2>/dev/null)" || true
    status="$(get_kv "STATUS" "$out")"
    port="$(get_kv "PORT" "$out")"
    pid="$(get_kv "PID" "$out")"
    port_open="$(get_kv "PORT_OPEN" "$out")"
    config_port="$(get_kv "CONFIG_PORT" "$out")"
    active_port="$(get_kv "ACTIVE_PORT" "$out")"
    effective_port="$(get_kv "EFFECTIVE_PORT" "$out")"
    mismatch="$(get_kv "MISMATCH" "$out")"
    logging_enabled="$(get_kv "LOGGING_ENABLED" "$out")"
    log_file="$(get_kv "LOG_FILE" "$out")"
    [ -z "$status" ] && status="stopped"
    [ -z "$port" ] && port="5301"
    [ -z "$port_open" ] && port_open="no"
    [ -z "$config_port" ] && config_port="$port"
    [ -z "$active_port" ] && active_port="$port"
    [ -z "$effective_port" ] && effective_port="$port"
    [ -z "$logging_enabled" ] && logging_enabled="no"
    [ -z "$log_file" ] && log_file="/opt/var/log/allow/dnsmasq-family.log"
    running="false"
    [ "$status" = "running" ] && running="true"
    port_open_bool="false"
    [ "$port_open" = "yes" ] && port_open_bool="true"
    mismatch_bool="false"
    [ "$mismatch" = "yes" ] && mismatch_bool="true"
    logging_bool="false"
    [ "$logging_enabled" = "yes" ] && logging_bool="true"
    pid_esc="$(json_esc "$pid")"
    log_file_esc="$(json_esc "$log_file")"
    autostart_active="$(get_autostart_active "dnsmasq-full-family")"
    cgi_header
    printf '{"running":%s,"port_open":%s,"pid":"%s","port":"%s","config_port":%s,"active_port":%s,"effective_port":%s,"mismatch":%s,"logging_enabled":%s,"log_file":"%s","status":"%s","autostart_active":%s}\n' \
        "$running" "$port_open_bool" "$pid_esc" "$port" "$config_port" "$active_port" "$effective_port" \
        "$mismatch_bool" "$logging_bool" "$log_file_esc" "$status" "$autostart_active"
}

# --- /dnsmasq-family/restart POST ---
route_dnsmasq_family_restart() {
    script="${MANAGED_DIR}/dnsmasq-family.sh"
    if [ ! -x "$script" ]; then
        status_header 503
        cgi_header
        printf '{"success":false,"message":"dnsmasq-family script not found"}\n'
        return 0
    fi
    out="$("$script" restart 2>/dev/null)" || true
    success="$(get_kv "SUCCESS" "$out")"
    message="$(get_kv "MESSAGE" "$out")"
    [ -z "$success" ] && success="no"
    [ -z "$message" ] && message="Done"
    msg_esc="$(json_esc "$message")"
    if [ "$success" = "yes" ]; then
        cgi_header
        printf '{"success":true,"message":"%s"}\n' "$msg_esc"
    else
        status_header 500
        cgi_header
        printf '{"success":false,"message":"%s"}\n' "$msg_esc"
    fi
}

# --- Parse lines= from QUERY_STRING (default 100, clamp 10-1000) ---
get_query_lines() {
    _n=100
    if [ -n "${QUERY_STRING:-}" ]; then
        _v="$(echo "$QUERY_STRING" | sed -n 's/^lines=\([0-9]*\).*/\1/p')"
        [ -z "$_v" ] && _v="$(echo "$QUERY_STRING" | sed -n 's/.*&lines=\([0-9]*\).*/\1/p')"
        [ -n "$_v" ] && _n="$_v"
    fi
    [ "$_n" -lt 10 ] 2>/dev/null && _n=10
    [ "$_n" -gt 1000 ] 2>/dev/null && _n=1000
    echo "$_n"
}

# --- Format byte size for display ---
format_size() {
    _b="$1"
    [ -z "$_b" ] && _b=0
    if [ "$_b" -eq 0 ] 2>/dev/null; then
        echo "0 B"
    elif [ "$_b" -lt 1024 ] 2>/dev/null; then
        echo "${_b} B"
    elif [ "$_b" -lt 1048576 ] 2>/dev/null; then
        _k=$((_b / 1024))
        echo "${_k} K"
    else
        _m=$((_b / 1048576))
        echo "${_m} M"
    fi
}

# --- /dnsmasq/logs GET (jq for correct JSON escaping) ---
route_dnsmasq_logs() {
    lines="$(get_query_lines)"
    warning=""
    [ -x "${MANAGED_DIR}/dnsmasq.sh" ] && out="$("${MANAGED_DIR}/dnsmasq.sh" status 2>/dev/null)" || out=""
    log_enabled="$(get_kv "LOGGING_ENABLED" "$out")"
    [ "$log_enabled" = "yes" ] || warning='Логирование выключено'
    cgi_header
    if [ ! -f "$DNSMASQ_LOG" ] || [ ! -s "$DNSMASQ_LOG" ]; then
        [ -n "$warning" ] && warn_esc="$(json_esc "$warning")" && printf '{"logs":[],"message":"Логи пусты","warning":"%s"}\n' "$warn_esc"
        [ -z "$warning" ] && printf '{"logs":[],"message":"Логи пусты"}\n'
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        tail -n "$lines" "$DNSMASQ_LOG" 2>/dev/null | jq -R . | jq -s --arg w "$warning" 'if $w != "" then {logs: ., warning: $w} else {logs: .} end'
    else
        export WARN_ESC="$warning"
        tail -n "$lines" "$DNSMASQ_LOG" 2>/dev/null | awk '
            BEGIN { printf "{\"logs\":["; first=1; w=ENVIRON["WARN_ESC"] }
            function json_esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/\r/,"\\r",s); gsub(/\n/,"\\n",s); return s }
            { s=json_esc($0); if (!first) printf ","; first=0; printf "\""; printf "%s", s; printf "\"" }
            END { if (w != "") { printf "],\"warning\":\""; t=json_esc(w); printf "%s", t; printf "\"}\n" } else { printf "]}\n" } }
        '
    fi
}

# --- /dnsmasq/logs/size GET ---
route_dnsmasq_logs_size() {
    cgi_header
    if [ ! -f "$DNSMASQ_LOG" ]; then
        printf '{"size":0,"size_formatted":"0 B"}\n'
        return 0
    fi
    sz="$(wc -c < "$DNSMASQ_LOG" 2>/dev/null)" || sz=0
    [ -z "$sz" ] && sz=0
    fmt="$(format_size "$sz")"
    fmt_esc="$(json_esc "$fmt")"
    printf '{"size":%s,"size_formatted":"%s"}\n' "$sz" "$fmt_esc"
}

# --- /dnsmasq/logs/clear POST ---
route_dnsmasq_logs_clear() {
    cgi_header
    if [ -f "$DNSMASQ_LOG" ]; then
        : > "$DNSMASQ_LOG" 2>/dev/null || true
    fi
    printf '{"success":true}\n'
}

# --- /dnsmasq-family/logs GET (jq for correct JSON escaping) ---
route_dnsmasq_family_logs() {
    lines="$(get_query_lines)"
    warning=""
    [ -x "${MANAGED_DIR}/dnsmasq-family.sh" ] && out="$("${MANAGED_DIR}/dnsmasq-family.sh" status 2>/dev/null)" || out=""
    log_enabled="$(get_kv "LOGGING_ENABLED" "$out")"
    [ "$log_enabled" = "yes" ] || warning='Логирование выключено'
    cgi_header
    if [ ! -f "$DNSMASQ_FAMILY_LOG" ] || [ ! -s "$DNSMASQ_FAMILY_LOG" ]; then
        [ -n "$warning" ] && warn_esc="$(json_esc "$warning")" && printf '{"logs":[],"message":"Логи пусты","warning":"%s"}\n' "$warn_esc"
        [ -z "$warning" ] && printf '{"logs":[],"message":"Логи пусты"}\n'
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        tail -n "$lines" "$DNSMASQ_FAMILY_LOG" 2>/dev/null | jq -R . | jq -s --arg w "$warning" 'if $w != "" then {logs: ., warning: $w} else {logs: .} end'
    else
        export WARN_ESC="$warning"
        tail -n "$lines" "$DNSMASQ_FAMILY_LOG" 2>/dev/null | awk '
            BEGIN { printf "{\"logs\":["; first=1; w=ENVIRON["WARN_ESC"] }
            function json_esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/\r/,"\\r",s); gsub(/\n/,"\\n",s); return s }
            { s=json_esc($0); if (!first) printf ","; first=0; printf "\""; printf "%s", s; printf "\"" }
            END { if (w != "") { printf "],\"warning\":\""; t=json_esc(w); printf "%s", t; printf "\"}\n" } else { printf "]}\n" } }
        '
    fi
}

# --- /dnsmasq-family/logs/size GET ---
route_dnsmasq_family_logs_size() {
    cgi_header
    if [ ! -f "$DNSMASQ_FAMILY_LOG" ]; then
        printf '{"size":0,"size_formatted":"0 B"}\n'
        return 0
    fi
    sz="$(wc -c < "$DNSMASQ_FAMILY_LOG" 2>/dev/null)" || sz=0
    [ -z "$sz" ] && sz=0
    fmt="$(format_size "$sz")"
    fmt_esc="$(json_esc "$fmt")"
    printf '{"size":%s,"size_formatted":"%s"}\n' "$sz" "$fmt_esc"
}

# --- /dnsmasq-family/logs/clear POST ---
route_dnsmasq_family_logs_clear() {
    cgi_header
    if [ -f "$DNSMASQ_FAMILY_LOG" ]; then
        : > "$DNSMASQ_FAMILY_LOG" 2>/dev/null || true
    fi
    printf '{"success":true}\n'
}

# --- /stubby/logs GET ---
route_stubby_logs() {
    lines="$(get_query_lines)"
    warning=""
    [ -x "${MANAGED_DIR}/allow-logging.sh" ] && out="$("${MANAGED_DIR}/allow-logging.sh" stubby status 2>/dev/null)" || out=""
    log_enabled="$(get_kv "LOGGING_ENABLED" "$out")"
    [ "$log_enabled" = "yes" ] || warning='Логирование выключено'
    cgi_header
    if [ ! -f "$STUBBY_LOG" ] || [ ! -s "$STUBBY_LOG" ]; then
        [ -n "$warning" ] && warn_esc="$(json_esc "$warning")" && printf '{"logs":[],"message":"Логи пусты","warning":"%s"}\n' "$warn_esc"
        [ -z "$warning" ] && printf '{"logs":[],"message":"Логи пусты"}\n'
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        tail -n "$lines" "$STUBBY_LOG" 2>/dev/null | jq -R . | jq -s --arg w "$warning" 'if $w != "" then {logs: ., warning: $w} else {logs: .} end'
    else
        export WARN_ESC="$warning"
        tail -n "$lines" "$STUBBY_LOG" 2>/dev/null | awk '
            BEGIN { printf "{\"logs\":["; first=1; w=ENVIRON["WARN_ESC"] }
            function json_esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/\r/,"\\r",s); gsub(/\n/,"\\n",s); return s }
            { s=json_esc($0); if (!first) printf ","; first=0; printf "\""; printf "%s", s; printf "\"" }
            END { if (w != "") { printf "],\"warning\":\""; t=json_esc(w); printf "%s", t; printf "\"}\n" } else { printf "]}\n" } }
        '
    fi
}

# --- /stubby/logs/size GET ---
route_stubby_logs_size() {
    cgi_header
    if [ ! -f "$STUBBY_LOG" ]; then
        printf '{"size":0,"size_formatted":"0 B"}\n'
        return 0
    fi
    sz="$(wc -c < "$STUBBY_LOG" 2>/dev/null)" || sz=0
    [ -z "$sz" ] && sz=0
    fmt="$(format_size "$sz")"
    fmt_esc="$(json_esc "$fmt")"
    printf '{"size":%s,"size_formatted":"%s"}\n' "$sz" "$fmt_esc"
}

# --- /stubby/logs/clear POST ---
route_stubby_logs_clear() {
    cgi_header
    if [ -f "$STUBBY_LOG" ]; then
        : > "$STUBBY_LOG" 2>/dev/null || true
    fi
    printf '{"success":true}\n'
}

# --- /stubby-family/logs GET ---
route_stubby_family_logs() {
    lines="$(get_query_lines)"
    warning=""
    [ -x "${MANAGED_DIR}/allow-logging.sh" ] && out="$("${MANAGED_DIR}/allow-logging.sh" stubby-family status 2>/dev/null)" || out=""
    log_enabled="$(get_kv "LOGGING_ENABLED" "$out")"
    [ "$log_enabled" = "yes" ] || warning='Логирование выключено'
    cgi_header
    if [ ! -f "$STUBBY_FAMILY_LOG" ] || [ ! -s "$STUBBY_FAMILY_LOG" ]; then
        [ -n "$warning" ] && warn_esc="$(json_esc "$warning")" && printf '{"logs":[],"message":"Логи пусты","warning":"%s"}\n' "$warn_esc"
        [ -z "$warning" ] && printf '{"logs":[],"message":"Логи пусты"}\n'
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        tail -n "$lines" "$STUBBY_FAMILY_LOG" 2>/dev/null | jq -R . | jq -s --arg w "$warning" 'if $w != "" then {logs: ., warning: $w} else {logs: .} end'
    else
        export WARN_ESC="$warning"
        tail -n "$lines" "$STUBBY_FAMILY_LOG" 2>/dev/null | awk '
            BEGIN { printf "{\"logs\":["; first=1; w=ENVIRON["WARN_ESC"] }
            function json_esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/\t/,"\\t",s); gsub(/\r/,"\\r",s); gsub(/\n/,"\\n",s); return s }
            { s=json_esc($0); if (!first) printf ","; first=0; printf "\""; printf "%s", s; printf "\"" }
            END { if (w != "") { printf "],\"warning\":\""; t=json_esc(w); printf "%s", t; printf "\"}\n" } else { printf "]}\n" } }
        '
    fi
}

# --- /stubby-family/logs/size GET ---
route_stubby_family_logs_size() {
    cgi_header
    if [ ! -f "$STUBBY_FAMILY_LOG" ]; then
        printf '{"size":0,"size_formatted":"0 B"}\n'
        return 0
    fi
    sz="$(wc -c < "$STUBBY_FAMILY_LOG" 2>/dev/null)" || sz=0
    [ -z "$sz" ] && sz=0
    fmt="$(format_size "$sz")"
    fmt_esc="$(json_esc "$fmt")"
    printf '{"size":%s,"size_formatted":"%s"}\n' "$sz" "$fmt_esc"
}

# --- /stubby-family/logs/clear POST ---
route_stubby_family_logs_clear() {
    cgi_header
    if [ -f "$STUBBY_FAMILY_LOG" ]; then
        : > "$STUBBY_FAMILY_LOG" 2>/dev/null || true
    fi
    printf '{"success":true}\n'
}

# --- /stubby/logging POST ---
route_stubby_logging_post() {
    _enabled="false"
    [ -n "$body" ] && _enabled="$(echo "$body" | grep -o '"enabled"[ \t]*:[ \t]*true')"
    if [ -n "$_enabled" ] && echo "$body" | grep -q '"enabled"[ \t]*:[ \t]*true'; then
        _cmd="start"
    else
        _cmd="stop"
    fi
    [ ! -x "${MANAGED_DIR}/allow-logging.sh" ] && status_header 503 && cgi_header && printf '{"success":false,"message":"allow-logging.sh not found"}\n' && return 0
    out="$("${MANAGED_DIR}/allow-logging.sh" stubby "$_cmd" 2>/dev/null)" || true
    success="$(get_kv "SUCCESS" "$out")"
    message="$(get_kv "MESSAGE" "$out")"
    [ -z "$message" ] && message="Done"
    msg_esc="$(json_esc "$message")"
    if [ "$success" = "yes" ]; then
        cgi_header
        printf '{"success":true,"message":"%s"}\n' "$msg_esc"
    else
        status_header 500
        cgi_header
        printf '{"success":false,"message":"%s"}\n' "$msg_esc"
    fi
}

# --- /stubby-family/logging POST ---
route_stubby_family_logging_post() {
    _enabled="false"
    [ -n "$body" ] && _enabled="$(echo "$body" | grep -o '"enabled"[ \t]*:[ \t]*true')"
    if [ -n "$_enabled" ] && echo "$body" | grep -q '"enabled"[ \t]*:[ \t]*true'; then
        _cmd="start"
    else
        _cmd="stop"
    fi
    [ ! -x "${MANAGED_DIR}/allow-logging.sh" ] && status_header 503 && cgi_header && printf '{"success":false,"message":"allow-logging.sh not found"}\n' && return 0
    out="$("${MANAGED_DIR}/allow-logging.sh" stubby-family "$_cmd" 2>/dev/null)" || true
    success="$(get_kv "SUCCESS" "$out")"
    message="$(get_kv "MESSAGE" "$out")"
    [ -z "$message" ] && message="Done"
    msg_esc="$(json_esc "$message")"
    if [ "$success" = "yes" ]; then
        cgi_header
        printf '{"success":true,"message":"%s"}\n' "$msg_esc"
    else
        status_header 500
        cgi_header
        printf '{"success":false,"message":"%s"}\n' "$msg_esc"
    fi
}

# --- Parse value from conf: key=value (uncommented) ---
conf_get() {
    _key="$1"
    _file="$2"
    _default="$3"
    [ -f "$_file" ] || { echo "$_default"; return 0; }
    _v="$(awk -v k="$_key" '
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            sub(/^[^=]*=[[:space:]]*/, "");
            gsub(/[[:space:]]*#.*/, "");
            gsub(/^[[:space:]]|[[:space:]]$/, "");
            if (length($0) > 0) { print; exit }
        }
    ' "$_file" 2>/dev/null)"
    [ -n "$_v" ] && echo "$_v" || echo "$_default"
}

# --- Check uncommented log-queries in conf ---
conf_logging_enabled() {
    _file="$1"
    [ -f "$_file" ] || { echo "no"; return 0; }
    grep -q '^[[:space:]]*log-queries[[:space:]]*$' "$_file" 2>/dev/null && echo "yes" || echo "no"
}

# --- /dnsmasq/config GET ---
route_dnsmasq_config_get() {
    cgi_header
    if [ ! -f "$DNSMASQ_CONF" ]; then
        printf '{"editable":{"cache-size":"10000","min-cache-ttl":"300","max-cache-ttl":"3600","logging":false},"full_config":[]}\n'
        return 0
    fi
    cache_size="$(conf_get "cache-size" "$DNSMASQ_CONF" "10000")"
    min_ttl="$(conf_get "min-cache-ttl" "$DNSMASQ_CONF" "300")"
    max_ttl="$(conf_get "max-cache-ttl" "$DNSMASQ_CONF" "3600")"
    log_enabled="$(conf_logging_enabled "$DNSMASQ_CONF")"
    [ "$log_enabled" = "yes" ] && log_bool="true" || log_bool="false"
    cs_esc="$(json_esc "$cache_size")"
    min_esc="$(json_esc "$min_ttl")"
    max_esc="$(json_esc "$max_ttl")"
    printf '{"editable":{"cache-size":"%s","min-cache-ttl":"%s","max-cache-ttl":"%s","logging":%s},"full_config":[' "$cs_esc" "$min_esc" "$max_esc" "$log_bool"
    _first=1
    while IFS= read -r _line; do
        _le="$(echo "$_line" | sed 's/\\/\\\\/g;s/"/\\"/g;s/	/\\t/g')"
        [ "$_first" -eq 1 ] && _first=0 || printf ','
        printf '"%s"' "$_le"
    done < "$DNSMASQ_CONF" 2>/dev/null
    printf ']}\n'
}

# --- /dnsmasq/config POST ---
route_dnsmasq_config_post() {
    body="$1"
    cache_size="10000"
    min_ttl="300"
    max_ttl="3600"
    logging="false"
    echo "$body" | grep -q '"cache-size"' && cache_size="$(echo "$body" | sed -n 's/.*"cache-size"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -z "$cache_size" ] && cache_size="$(echo "$body" | sed -n 's/.*"cache-size"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
    [ -z "$cache_size" ] && cache_size="10000"
    echo "$body" | grep -q '"min-cache-ttl"' && min_ttl="$(echo "$body" | sed -n 's/.*"min-cache-ttl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -z "$min_ttl" ] && min_ttl="$(echo "$body" | sed -n 's/.*"min-cache-ttl"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
    [ -z "$min_ttl" ] && min_ttl="300"
    echo "$body" | grep -q '"max-cache-ttl"' && max_ttl="$(echo "$body" | sed -n 's/.*"max-cache-ttl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -z "$max_ttl" ] && max_ttl="$(echo "$body" | sed -n 's/.*"max-cache-ttl"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
    [ -z "$max_ttl" ] && max_ttl="3600"
    echo "$body" | grep -q '"logging"[[:space:]]*:[[:space:]]*true' && logging="true"
    [ ! -f "$DNSMASQ_CONF" ] && { status_header 404; cgi_header; printf '{"success":false,"message":"Config file not found"}\n'; return 0; }
    _tmp="/tmp/dnsmasq.conf.$$"
    awk -v cs="$cache_size" -v min="$min_ttl" -v max="$max_ttl" '
        /^[[:space:]]*cache-size[[:space:]]*=/ { print "cache-size=" cs; next }
        /^[[:space:]]*min-cache-ttl[[:space:]]*=/ { print "min-cache-ttl=" min; next }
        /^[[:space:]]*max-cache-ttl[[:space:]]*=/ { print "max-cache-ttl=" max; next }
        { print }
    ' "$DNSMASQ_CONF" > "$_tmp" 2>/dev/null
    if [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"
        status_header 500
        cgi_header
        printf '{"success":false,"message":"Failed to update config"}\n'
        return 0
    fi
    mv "$_tmp" "$DNSMASQ_CONF" 2>/dev/null || { rm -f "$_tmp"; status_header 500; cgi_header; printf '{"success":false,"message":"Failed to write config"}\n'; return 0; }
    # Logging toggle via allow-logging.sh (updates log-queries and restarts)
    if [ -x "${MANAGED_DIR}/allow-logging.sh" ]; then
        _cmd="stop"
        [ "$logging" = "true" ] && _cmd="start"
        out="$("${MANAGED_DIR}/allow-logging.sh" "dnsmasq-full" "$_cmd" 2>/dev/null)" || true
        success="$(get_kv "SUCCESS" "$out")"
        message="$(get_kv "MESSAGE" "$out")"
    else
        out="$("${MANAGED_DIR}/dnsmasq.sh" restart 2>/dev/null)" || true
        success="$(get_kv "SUCCESS" "$out")"
        message="$(get_kv "MESSAGE" "$out")"
    fi
    [ -z "$success" ] && success="no"
    [ -z "$message" ] && message="Done"
    msg_esc="$(json_esc "$message")"
    cgi_header
    if [ "$success" = "yes" ]; then
        printf '{"success":true,"message":"%s"}\n' "$msg_esc"
    else
        printf '{"success":false,"message":"%s"}\n' "$msg_esc"
    fi
}

# --- /dnsmasq/config/full GET ---
route_dnsmasq_config_full_get() {
    cgi_header
    if [ ! -f "$DNSMASQ_CONF" ]; then
        printf '{"full_config":[]}\n'
        return 0
    fi
    printf '{"full_config":['
    _first=1
    while IFS= read -r _line; do
        _le="$(echo "$_line" | sed 's/\\/\\\\/g;s/"/\\"/g;s/	/\\t/g')"
        [ "$_first" -eq 1 ] && _first=0 || printf ','
        printf '"%s"' "$_le"
    done < "$DNSMASQ_CONF" 2>/dev/null
    printf ']}\n'
}

# --- /dnsmasq/config/full POST ---
route_dnsmasq_config_full_post() {
    body="$1"
    # Frontend sends JSON: {"config":"line1\nline2\n..."}
    _content=""
    echo "$body" | grep -q '"config"' && _content="$(echo "$body" | sed -n 's/.*"config"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')"
    [ -z "$_content" ] && _content="$body"
    # Unescape JSON: \\ first (use placeholder), then \", \n, \t, then restore \
    _content="$(printf '%s' "$_content" | sed 's/\\\\/\x00/g;s/\\"/"/g;s/\\n/\n/g;s/\\t/\t/g;s/\x00/\\/g')"
    _tmp="/tmp/dnsmasq-full.conf.$$"
    printf '%s' "$_content" > "$_tmp" 2>/dev/null
    if [ ! -f "$_tmp" ]; then
        status_header 500
        cgi_header
        printf '{"success":false,"message":"Failed to write temp file"}\n'
        return 0
    fi
    mv "$_tmp" "$DNSMASQ_CONF" 2>/dev/null || { rm -f "$_tmp"; status_header 500; cgi_header; printf '{"success":false,"message":"Failed to replace config"}\n'; return 0; }
    out="$("${MANAGED_DIR}/dnsmasq.sh" restart 2>/dev/null)" || true
    success="$(get_kv "SUCCESS" "$out")"
    message="$(get_kv "MESSAGE" "$out")"
    [ -z "$success" ] && success="no"
    [ -z "$message" ] && message="Done"
    msg_esc="$(json_esc "$message")"
    cgi_header
    [ "$success" = "yes" ] && printf '{"success":true,"message":"%s"}\n' "$msg_esc" || printf '{"success":false,"message":"%s"}\n' "$msg_esc"
}

# --- /dnsmasq-family/config GET ---
route_dnsmasq_family_config_get() {
    cgi_header
    if [ ! -f "$DNSMASQ_FAMILY_CONF" ]; then
        printf '{"editable":{"cache-size":"1536","min-cache-ttl":"300","max-cache-ttl":"3600","logging":false},"full_config":[]}\n'
        return 0
    fi
    cache_size="$(conf_get "cache-size" "$DNSMASQ_FAMILY_CONF" "1536")"
    min_ttl="$(conf_get "min-cache-ttl" "$DNSMASQ_FAMILY_CONF" "300")"
    max_ttl="$(conf_get "max-cache-ttl" "$DNSMASQ_FAMILY_CONF" "3600")"
    log_enabled="$(conf_logging_enabled "$DNSMASQ_FAMILY_CONF")"
    [ "$log_enabled" = "yes" ] && log_bool="true" || log_bool="false"
    cs_esc="$(json_esc "$cache_size")"
    min_esc="$(json_esc "$min_ttl")"
    max_esc="$(json_esc "$max_ttl")"
    printf '{"editable":{"cache-size":"%s","min-cache-ttl":"%s","max-cache-ttl":"%s","logging":%s},"full_config":[' "$cs_esc" "$min_esc" "$max_esc" "$log_bool"
    _first=1
    while IFS= read -r _line; do
        _le="$(echo "$_line" | sed 's/\\/\\\\/g;s/"/\\"/g;s/	/\\t/g')"
        [ "$_first" -eq 1 ] && _first=0 || printf ','
        printf '"%s"' "$_le"
    done < "$DNSMASQ_FAMILY_CONF" 2>/dev/null
    printf ']}\n'
}

# --- /dnsmasq-family/config POST ---
route_dnsmasq_family_config_post() {
    body="$1"
    cache_size="1536"
    min_ttl="0"
    max_ttl="0"
    logging="false"
    echo "$body" | grep -q '"cache-size"' && cache_size="$(echo "$body" | sed -n 's/.*"cache-size"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -z "$cache_size" ] && cache_size="$(echo "$body" | sed -n 's/.*"cache-size"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
    [ -z "$cache_size" ] && cache_size="1536"
    echo "$body" | grep -q '"min-cache-ttl"' && min_ttl="$(echo "$body" | sed -n 's/.*"min-cache-ttl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -z "$min_ttl" ] && min_ttl="$(echo "$body" | sed -n 's/.*"min-cache-ttl"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
    [ -z "$min_ttl" ] && min_ttl="0"
    echo "$body" | grep -q '"max-cache-ttl"' && max_ttl="$(echo "$body" | sed -n 's/.*"max-cache-ttl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -z "$max_ttl" ] && max_ttl="$(echo "$body" | sed -n 's/.*"max-cache-ttl"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
    [ -z "$max_ttl" ] && max_ttl="0"
    echo "$body" | grep -q '"logging"[[:space:]]*:[[:space:]]*true' && logging="true"
    [ ! -f "$DNSMASQ_FAMILY_CONF" ] && { status_header 404; cgi_header; printf '{"success":false,"message":"Config file not found"}\n'; return 0; }
    _tmp="/tmp/dnsmasq-family.conf.$$"
    awk -v cs="$cache_size" -v min="$min_ttl" -v max="$max_ttl" '
        /^[[:space:]]*cache-size[[:space:]]*=/ { print "cache-size=" cs; next }
        /^[[:space:]]*min-cache-ttl[[:space:]]*=/ { print "min-cache-ttl=" min; next }
        /^[[:space:]]*max-cache-ttl[[:space:]]*=/ { print "max-cache-ttl=" max; next }
        { print }
    ' "$DNSMASQ_FAMILY_CONF" > "$_tmp" 2>/dev/null
    if [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"
        status_header 500
        cgi_header
        printf '{"success":false,"message":"Failed to update config"}\n'
        return 0
    fi
    mv "$_tmp" "$DNSMASQ_FAMILY_CONF" 2>/dev/null || { rm -f "$_tmp"; status_header 500; cgi_header; printf '{"success":false,"message":"Failed to write config"}\n'; return 0; }
    if [ -x "${MANAGED_DIR}/allow-logging.sh" ]; then
        _cmd="stop"
        [ "$logging" = "true" ] && _cmd="start"
        out="$("${MANAGED_DIR}/allow-logging.sh" "dnsmasq-family" "$_cmd" 2>/dev/null)" || true
        success="$(get_kv "SUCCESS" "$out")"
        message="$(get_kv "MESSAGE" "$out")"
    else
        out="$("${MANAGED_DIR}/dnsmasq-family.sh" restart 2>/dev/null)" || true
        success="$(get_kv "SUCCESS" "$out")"
        message="$(get_kv "MESSAGE" "$out")"
    fi
    [ -z "$success" ] && success="no"
    [ -z "$message" ] && message="Done"
    msg_esc="$(json_esc "$message")"
    cgi_header
    if [ "$success" = "yes" ]; then
        printf '{"success":true,"message":"%s"}\n' "$msg_esc"
    else
        printf '{"success":false,"message":"%s"}\n' "$msg_esc"
    fi
}

# --- /dnsmasq-family/config/full GET ---
route_dnsmasq_family_config_full_get() {
    cgi_header
    if [ ! -f "$DNSMASQ_FAMILY_CONF" ]; then
        printf '{"full_config":[]}\n'
        return 0
    fi
    printf '{"full_config":['
    _first=1
    while IFS= read -r _line; do
        _le="$(echo "$_line" | sed 's/\\/\\\\/g;s/"/\\"/g;s/	/\\t/g')"
        [ "$_first" -eq 1 ] && _first=0 || printf ','
        printf '"%s"' "$_le"
    done < "$DNSMASQ_FAMILY_CONF" 2>/dev/null
    printf ']}\n'
}

# --- /dnsmasq-family/config/full POST ---
route_dnsmasq_family_config_full_post() {
    body="$1"
    _content=""
    echo "$body" | grep -q '"config"' && _content="$(echo "$body" | sed -n 's/.*"config"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')"
    [ -z "$_content" ] && _content="$body"
    _content="$(printf '%s' "$_content" | sed 's/\\\\/\x00/g;s/\\"/"/g;s/\\n/\n/g;s/\\t/\t/g;s/\x00/\\/g')"
    _tmp="/tmp/dnsmasq-family-full.conf.$$"
    printf '%s' "$_content" > "$_tmp" 2>/dev/null
    if [ ! -f "$_tmp" ]; then
        status_header 500
        cgi_header
        printf '{"success":false,"message":"Failed to write temp file"}\n'
        return 0
    fi
    mv "$_tmp" "$DNSMASQ_FAMILY_CONF" 2>/dev/null || { rm -f "$_tmp"; status_header 500; cgi_header; printf '{"success":false,"message":"Failed to replace config"}\n'; return 0; }
    out="$("${MANAGED_DIR}/dnsmasq-family.sh" restart 2>/dev/null)" || true
    success="$(get_kv "SUCCESS" "$out")"
    message="$(get_kv "MESSAGE" "$out")"
    [ -z "$success" ] && success="no"
    [ -z "$message" ] && message="Done"
    msg_esc="$(json_esc "$message")"
    cgi_header
    [ "$success" = "yes" ] && printf '{"success":true,"message":"%s"}\n' "$msg_esc" || printf '{"success":false,"message":"%s"}\n' "$msg_esc"
}

# --- Debug: append one line to DEBUG_LOG (hypotheses A,B,D,E) ---
# #region agent log
debug_log() {
    _msg="$1"
    [ -n "$DEBUG_LOG" ] && mkdir -p "$(dirname "$DEBUG_LOG")" 2>/dev/null && echo "$_msg" >> "$DEBUG_LOG" 2>/dev/null || true
}
# #endregion

# --- Main dispatch ---
main() {
    # #region agent log
    debug_log "req PATH_INFO_RAW=[$PATH_INFO_RAW] PATH_INFO=[$PATH_INFO] REQUEST_METHOD=$REQUEST_METHOD"
    # #endregion
    # Normalize path: no leading/trailing slash for comparison
    case "$PATH_INFO" in
        system/info) path="/system/info" ;;
        dns-mode)    path="/dns-mode" ;;
        settings/children-filter) path="/settings/children-filter" ;;
        sync-allow-lists/status) path="/sync-allow-lists/status" ;;
        sync-allow-lists/autoupdate) path="/sync-allow-lists/autoupdate" ;;
        sync-allow-lists/run) path="/sync-allow-lists/run" ;;
        sync-allow-lists/logs) path="/sync-allow-lists/logs" ;;
        stubby/status)  path="/stubby/status" ;;
        stubby/start)   path="/stubby/start" ;;
        stubby/stop)    path="/stubby/stop" ;;
        stubby/restart) path="/stubby/restart" ;;
        stubby/autostart) path="/stubby/autostart" ;;
        stubby/logs)    path="/stubby/logs" ;;
        stubby/logs/size)  path="/stubby/logs/size" ;;
        stubby/logs/clear)  path="/stubby/logs/clear" ;;
        stubby/logging) path="/stubby/logging" ;;
        stubby-family/status)  path="/stubby-family/status" ;;
        stubby-family/start)   path="/stubby-family/start" ;;
        stubby-family/stop)    path="/stubby-family/stop" ;;
        stubby-family/restart) path="/stubby-family/restart" ;;
        stubby-family/autostart) path="/stubby-family/autostart" ;;
        stubby-family/logs)    path="/stubby-family/logs" ;;
        stubby-family/logs/size)  path="/stubby-family/logs/size" ;;
        stubby-family/logs/clear)  path="/stubby-family/logs/clear" ;;
        stubby-family/logging) path="/stubby-family/logging" ;;
        dnsmasq/status)  path="/dnsmasq/status" ;;
        dnsmasq/restart) path="/dnsmasq/restart" ;;
        dnsmasq/autostart) path="/dnsmasq/autostart" ;;
        dnsmasq/logs)    path="/dnsmasq/logs" ;;
        dnsmasq/logs/size)  path="/dnsmasq/logs/size" ;;
        dnsmasq/logs/clear)  path="/dnsmasq/logs/clear" ;;
        dnsmasq/config)  path="/dnsmasq/config" ;;
        dnsmasq/config/full) path="/dnsmasq/config/full" ;;
        dnsmasq-family/status)  path="/dnsmasq-family/status" ;;
        dnsmasq-family/restart) path="/dnsmasq-family/restart" ;;
        dnsmasq-family/autostart) path="/dnsmasq-family/autostart" ;;
        dnsmasq-family/logs)    path="/dnsmasq-family/logs" ;;
        dnsmasq-family/logs/size)  path="/dnsmasq-family/logs/size" ;;
        dnsmasq-family/logs/clear)  path="/dnsmasq-family/logs/clear" ;;
        dnsmasq-family/config)  path="/dnsmasq-family/config" ;;
        dnsmasq-family/config/full) path="/dnsmasq-family/config/full" ;;
        singbox/status)  path="/singbox/status" ;;
        singbox/start)   path="/singbox/start" ;;
        singbox/stop)    path="/singbox/stop" ;;
        singbox/restart) path="/singbox/restart" ;;
        singbox/autostart) path="/singbox/autostart" ;;
        singbox/logs)    path="/singbox/logs" ;;
        singbox/logs/size)  path="/singbox/logs/size" ;;
        singbox/logs/clear) path="/singbox/logs/clear" ;;
        singbox/logging) path="/singbox/logging" ;;
        singbox/route-by-mark/marks)         path="/singbox/route-by-mark/marks" ;;
        singbox/route-by-mark/status)        path="/singbox/route-by-mark/status" ;;
        singbox/route-by-mark/iptables-rules) path="/singbox/route-by-mark/iptables-rules" ;;
        singbox/route-by-mark)              path="/singbox/route-by-mark" ;;
        *)           path="/unknown" ;;
    esac
    # #region agent log
    debug_log "dispatch path=$path"
    # #endregion

    body=""
    if [ "$REQUEST_METHOD" = "POST" ]; then
        body="$(read_body)"
    fi

    case "$path" in
        /system/info)
            [ "$REQUEST_METHOD" = "GET" ] && route_system_info || json_404
            ;;
        /dns-mode)
            if [ "$REQUEST_METHOD" = "GET" ]; then
                route_dns_mode_get
            elif [ "$REQUEST_METHOD" = "POST" ]; then
                route_dns_mode_post "$body"
            else
                json_404
            fi
            ;;
        /settings/children-filter)
            if [ "$REQUEST_METHOD" = "GET" ]; then
                route_children_filter_get
            elif [ "$REQUEST_METHOD" = "POST" ]; then
                route_children_filter_post "$body"
            else
                json_404
            fi
            ;;
        /sync-allow-lists/status)
            [ "$REQUEST_METHOD" = "GET" ] && route_sync_allow_status || json_404
            ;;
        /sync-allow-lists/autoupdate)
            [ "$REQUEST_METHOD" = "POST" ] && route_sync_allow_autoupdate_post "$body" || json_404
            ;;
        /sync-allow-lists/run)
            [ "$REQUEST_METHOD" = "POST" ] && route_sync_allow_run || json_404
            ;;
        /sync-allow-lists/logs)
            [ "$REQUEST_METHOD" = "GET" ] && route_sync_allow_logs || json_404
            ;;
        /stubby/status)
            [ "$REQUEST_METHOD" = "GET" ] && route_stubby_status || json_404
            ;;
        /stubby/start|/stubby/stop|/stubby/restart)
            if [ "$REQUEST_METHOD" = "POST" ]; then
                route_stubby_action "${path#/stubby/}"
            else
                json_404
            fi
            ;;
        /stubby/autostart)
            [ "$REQUEST_METHOD" = "POST" ] && route_stubby_autostart "$body" || json_404
            ;;
        /stubby-family/status)
            [ "$REQUEST_METHOD" = "GET" ] && route_stubby_family_status || json_404
            ;;
        /stubby-family/start|/stubby-family/stop|/stubby-family/restart)
            if [ "$REQUEST_METHOD" = "POST" ]; then
                route_stubby_family_action "${path#/stubby-family/}"
            else
                json_404
            fi
            ;;
        /stubby-family/autostart)
            [ "$REQUEST_METHOD" = "POST" ] && route_stubby_family_autostart "$body" || json_404
            ;;
        /stubby/logs)
            [ "$REQUEST_METHOD" = "GET" ] && route_stubby_logs || json_404
            ;;
        /stubby/logs/size)
            [ "$REQUEST_METHOD" = "GET" ] && route_stubby_logs_size || json_404
            ;;
        /stubby/logs/clear)
            [ "$REQUEST_METHOD" = "POST" ] && route_stubby_logs_clear || json_404
            ;;
        /stubby/logging)
            [ "$REQUEST_METHOD" = "POST" ] && route_stubby_logging_post || json_404
            ;;
        /stubby-family/logs)
            [ "$REQUEST_METHOD" = "GET" ] && route_stubby_family_logs || json_404
            ;;
        /stubby-family/logs/size)
            [ "$REQUEST_METHOD" = "GET" ] && route_stubby_family_logs_size || json_404
            ;;
        /stubby-family/logs/clear)
            [ "$REQUEST_METHOD" = "POST" ] && route_stubby_family_logs_clear || json_404
            ;;
        /stubby-family/logging)
            [ "$REQUEST_METHOD" = "POST" ] && route_stubby_family_logging_post || json_404
            ;;
        /dnsmasq/status)
            [ "$REQUEST_METHOD" = "GET" ] && route_dnsmasq_status || json_404
            ;;
        /dnsmasq/restart)
            [ "$REQUEST_METHOD" = "POST" ] && route_dnsmasq_restart || json_404
            ;;
        /dnsmasq/autostart)
            [ "$REQUEST_METHOD" = "POST" ] && route_dnsmasq_autostart "$body" || json_404
            ;;
        /dnsmasq/logs)
            [ "$REQUEST_METHOD" = "GET" ] && route_dnsmasq_logs || json_404
            ;;
        /dnsmasq/logs/size)
            [ "$REQUEST_METHOD" = "GET" ] && route_dnsmasq_logs_size || json_404
            ;;
        /dnsmasq/logs/clear)
            [ "$REQUEST_METHOD" = "POST" ] && route_dnsmasq_logs_clear || json_404
            ;;
        /dnsmasq/config)
            if [ "$REQUEST_METHOD" = "GET" ]; then
                route_dnsmasq_config_get
            elif [ "$REQUEST_METHOD" = "POST" ]; then
                route_dnsmasq_config_post "$body"
            else
                json_404
            fi
            ;;
        /dnsmasq/config/full)
            if [ "$REQUEST_METHOD" = "GET" ]; then
                route_dnsmasq_config_full_get
            elif [ "$REQUEST_METHOD" = "POST" ]; then
                route_dnsmasq_config_full_post "$body"
            else
                json_404
            fi
            ;;
        /dnsmasq-family/status)
            [ "$REQUEST_METHOD" = "GET" ] && route_dnsmasq_family_status || json_404
            ;;
        /dnsmasq-family/restart)
            [ "$REQUEST_METHOD" = "POST" ] && route_dnsmasq_family_restart || json_404
            ;;
        /dnsmasq-family/autostart)
            [ "$REQUEST_METHOD" = "POST" ] && route_dnsmasq_family_autostart "$body" || json_404
            ;;
        /dnsmasq-family/logs)
            [ "$REQUEST_METHOD" = "GET" ] && route_dnsmasq_family_logs || json_404
            ;;
        /dnsmasq-family/logs/size)
            [ "$REQUEST_METHOD" = "GET" ] && route_dnsmasq_family_logs_size || json_404
            ;;
        /dnsmasq-family/logs/clear)
            [ "$REQUEST_METHOD" = "POST" ] && route_dnsmasq_family_logs_clear || json_404
            ;;
        /dnsmasq-family/config)
            if [ "$REQUEST_METHOD" = "GET" ]; then
                route_dnsmasq_family_config_get
            elif [ "$REQUEST_METHOD" = "POST" ]; then
                route_dnsmasq_family_config_post "$body"
            else
                json_404
            fi
            ;;
        /dnsmasq-family/config/full)
            if [ "$REQUEST_METHOD" = "GET" ]; then
                route_dnsmasq_family_config_full_get
            elif [ "$REQUEST_METHOD" = "POST" ]; then
                route_dnsmasq_family_config_full_post "$body"
            else
                json_404
            fi
            ;;
        /singbox/status)
            [ "$REQUEST_METHOD" = "GET" ] && route_singbox_status || json_404
            ;;
        /singbox/start|/singbox/stop|/singbox/restart)
            if [ "$REQUEST_METHOD" = "POST" ]; then
                route_singbox_action "${path#/singbox/}"
            else
                json_404
            fi
            ;;
        /singbox/autostart)
            [ "$REQUEST_METHOD" = "POST" ] && route_singbox_autostart "$body" || json_404
            ;;
        /singbox/logs)
            [ "$REQUEST_METHOD" = "GET" ] && route_singbox_logs || json_404
            ;;
        /singbox/logs/size)
            [ "$REQUEST_METHOD" = "GET" ] && route_singbox_logs_size || json_404
            ;;
        /singbox/logs/clear)
            [ "$REQUEST_METHOD" = "POST" ] && route_singbox_logs_clear || json_404
            ;;
        /singbox/logging)
            if [ "$REQUEST_METHOD" = "GET" ]; then
                route_singbox_logging_get
            elif [ "$REQUEST_METHOD" = "POST" ]; then
                route_singbox_logging_post
            else
                json_404
            fi
            ;;
        /singbox/route-by-mark/marks)
            [ "$REQUEST_METHOD" = "GET" ] && route_singbox_route_by_mark_marks || json_404
            ;;
        /singbox/route-by-mark/status)
            [ "$REQUEST_METHOD" = "GET" ] && route_singbox_route_by_mark_status || json_404
            ;;
        /singbox/route-by-mark/iptables-rules)
            [ "$REQUEST_METHOD" = "GET" ] && route_singbox_route_by_mark_iptables_rules || json_404
            ;;
        /singbox/route-by-mark)
            [ "$REQUEST_METHOD" = "POST" ] && route_singbox_route_by_mark_post "$body" || json_404
            ;;
        *)
            json_404
            ;;
    esac
}

# PATH_INFO from env may be /auth-token or auth-token; normalize
PATH_INFO="/${PATH_INFO#/}"
PATH_INFO="${PATH_INFO%/}"
PATH_INFO="${PATH_INFO#/}"
main
