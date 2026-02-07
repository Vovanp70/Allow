#!/bin/sh
#
# Управление логированием компонентов ALLOW: start | stop | status.
# Вывод в формате KEY=value для разбора CGI.
# Использование: allow-logging.sh <component> <start|stop|status>
# Компоненты: dnsmasq-full, dnsmasq-family, stubby, stubby-family, sing-box
#
# BusyBox/ash compatible: no [[:space:]], use [ \t] in sed.
#

PATH="/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin"; export PATH

ETC_ALLOW="${ETC_ALLOW:-/opt/etc/allow}"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
MANAGED_DIR="${SCRIPT_DIR}"

# --- dnsmasq-full ---
do_dnsmasq_full_status() {
    CONF="/opt/etc/allow/dnsmasq-full/dnsmasq.conf"
    LOG_FILE="/opt/var/log/allow/dnsmasq.log"
    LOGGING_ENABLED="no"
    [ -f "$CONF" ] && grep -q '^[ \t]*log-queries[ \t]*$' "$CONF" 2>/dev/null && LOGGING_ENABLED="yes"
    echo "LOGGING_ENABLED=$LOGGING_ENABLED"
    echo "LOG_FILE=$LOG_FILE"
}

do_dnsmasq_full_start() {
    CONF="/opt/etc/allow/dnsmasq-full/dnsmasq.conf"
    LOG_FILE="/opt/var/log/allow/dnsmasq.log"
    [ ! -f "$CONF" ] && echo "SUCCESS=no" && echo "MESSAGE=Config not found" && return 1
    _tmp="/tmp/dnsmasq-logging.$$"
    sed 's/^[ \t]*#*[ \t]*log-queries[ \t]*$/log-queries/' "$CONF" > "$_tmp" 2>/dev/null
    if [ -s "$_tmp" ]; then
        if ! grep -q '^[ \t]*log-queries[ \t]*$' "$_tmp" 2>/dev/null; then
            echo "log-queries" >> "$_tmp"
            echo "log-facility=$LOG_FILE" >> "$_tmp"
        fi
        mv "$_tmp" "$CONF" 2>/dev/null || { rm -f "$_tmp"; echo "SUCCESS=no"; echo "MESSAGE=Failed to write config"; return 1; }
    else
        rm -f "$_tmp"
        echo "SUCCESS=no"
        echo "MESSAGE=Failed to update config"
        return 1
    fi
    [ -x "${MANAGED_DIR}/dnsmasq.sh" ] && "${MANAGED_DIR}/dnsmasq.sh" restart >/dev/null 2>&1 || true
    echo "SUCCESS=yes"
    echo "MESSAGE=Logging enabled"
}

do_dnsmasq_full_stop() {
    CONF="/opt/etc/allow/dnsmasq-full/dnsmasq.conf"
    [ ! -f "$CONF" ] && echo "SUCCESS=no" && echo "MESSAGE=Config not found" && return 1
    _tmp="/tmp/dnsmasq-logging.$$"
    sed 's/^[ \t]*log-queries[ \t]*$/# log-queries/' "$CONF" > "$_tmp" 2>/dev/null
    if [ -s "$_tmp" ]; then
        mv "$_tmp" "$CONF" 2>/dev/null || { rm -f "$_tmp"; echo "SUCCESS=no"; echo "MESSAGE=Failed to write config"; return 1; }
    else
        rm -f "$_tmp"
        echo "SUCCESS=no"
        echo "MESSAGE=Failed to update config"
        return 1
    fi
    [ -x "${MANAGED_DIR}/dnsmasq.sh" ] && "${MANAGED_DIR}/dnsmasq.sh" restart >/dev/null 2>&1 || true
    echo "SUCCESS=yes"
    echo "MESSAGE=Logging disabled"
}

# --- dnsmasq-family ---
do_dnsmasq_family_status() {
    CONF="/opt/etc/allow/dnsmasq-full/dnsmasq-family.conf"
    LOG_FILE="/opt/var/log/allow/dnsmasq-family.log"
    LOGGING_ENABLED="no"
    [ -f "$CONF" ] && grep -q '^[ \t]*log-queries[ \t]*$' "$CONF" 2>/dev/null && LOGGING_ENABLED="yes"
    echo "LOGGING_ENABLED=$LOGGING_ENABLED"
    echo "LOG_FILE=$LOG_FILE"
}

do_dnsmasq_family_start() {
    CONF="/opt/etc/allow/dnsmasq-full/dnsmasq-family.conf"
    LOG_FILE="/opt/var/log/allow/dnsmasq-family.log"
    [ ! -f "$CONF" ] && echo "SUCCESS=no" && echo "MESSAGE=Config not found" && return 1
    _tmp="/tmp/dnsmasq-family-logging.$$"
    sed 's/^[ \t]*#*[ \t]*log-queries[ \t]*$/log-queries/' "$CONF" > "$_tmp" 2>/dev/null
    if [ -s "$_tmp" ]; then
        if ! grep -q '^[ \t]*log-queries[ \t]*$' "$_tmp" 2>/dev/null; then
            echo "log-queries" >> "$_tmp"
            echo "log-facility=$LOG_FILE" >> "$_tmp"
        fi
        mv "$_tmp" "$CONF" 2>/dev/null || { rm -f "$_tmp"; echo "SUCCESS=no"; echo "MESSAGE=Failed to write config"; return 1; }
    else
        rm -f "$_tmp"
        echo "SUCCESS=no"
        echo "MESSAGE=Failed to update config"
        return 1
    fi
    [ -x "${MANAGED_DIR}/dnsmasq-family.sh" ] && "${MANAGED_DIR}/dnsmasq-family.sh" restart >/dev/null 2>&1 || true
    echo "SUCCESS=yes"
    echo "MESSAGE=Logging enabled"
}

do_dnsmasq_family_stop() {
    CONF="/opt/etc/allow/dnsmasq-full/dnsmasq-family.conf"
    [ ! -f "$CONF" ] && echo "SUCCESS=no" && echo "MESSAGE=Config not found" && return 1
    _tmp="/tmp/dnsmasq-family-logging.$$"
    sed 's/^[ \t]*log-queries[ \t]*$/# log-queries/' "$CONF" > "$_tmp" 2>/dev/null
    if [ -s "$_tmp" ]; then
        mv "$_tmp" "$CONF" 2>/dev/null || { rm -f "$_tmp"; echo "SUCCESS=no"; echo "MESSAGE=Failed to write config"; return 1; }
    else
        rm -f "$_tmp"
        echo "SUCCESS=no"
        echo "MESSAGE=Failed to update config"
        return 1
    fi
    [ -x "${MANAGED_DIR}/dnsmasq-family.sh" ] && "${MANAGED_DIR}/dnsmasq-family.sh" restart >/dev/null 2>&1 || true
    echo "SUCCESS=yes"
    echo "MESSAGE=Logging disabled"
}

# --- stubby: flag file /opt/etc/allow/stubby/.logging_disabled ---
STUBBY_FLAG="/opt/etc/allow/stubby/.logging_disabled"
STUBBY_LOG_FILE="/opt/var/log/allow/stubby.log"

do_stubby_status() {
    LOG_FILE="$STUBBY_LOG_FILE"
    LOGGING_ENABLED="yes"
    [ -f "$STUBBY_FLAG" ] && LOGGING_ENABLED="no"
    echo "LOGGING_ENABLED=$LOGGING_ENABLED"
    echo "LOG_FILE=$LOG_FILE"
}

do_stubby_start() {
    rm -f "$STUBBY_FLAG" 2>/dev/null || true
    [ -x "${MANAGED_DIR}/stubby.sh" ] && "${MANAGED_DIR}/stubby.sh" restart >/dev/null 2>&1 || true
    echo "SUCCESS=yes"
    echo "MESSAGE=Logging enabled"
}

do_stubby_stop() {
    mkdir -p "/opt/etc/allow/stubby" 2>/dev/null || true
    : > "$STUBBY_FLAG" 2>/dev/null || true
    [ -x "${MANAGED_DIR}/stubby.sh" ] && "${MANAGED_DIR}/stubby.sh" restart >/dev/null 2>&1 || true
    echo "SUCCESS=yes"
    echo "MESSAGE=Logging disabled"
}

# --- stubby-family: flag file /opt/etc/allow/stubby/.logging_family_disabled ---
STUBBY_FAMILY_FLAG="/opt/etc/allow/stubby/.logging_family_disabled"
STUBBY_FAMILY_LOG_FILE="/opt/var/log/allow/stubby-family.log"

do_stubby_family_status() {
    LOG_FILE="$STUBBY_FAMILY_LOG_FILE"
    LOGGING_ENABLED="yes"
    [ -f "$STUBBY_FAMILY_FLAG" ] && LOGGING_ENABLED="no"
    echo "LOGGING_ENABLED=$LOGGING_ENABLED"
    echo "LOG_FILE=$LOG_FILE"
}

do_stubby_family_start() {
    rm -f "$STUBBY_FAMILY_FLAG" 2>/dev/null || true
    [ -x "${MANAGED_DIR}/stubby-family.sh" ] && "${MANAGED_DIR}/stubby-family.sh" restart >/dev/null 2>&1 || true
    echo "SUCCESS=yes"
    echo "MESSAGE=Logging enabled"
}

do_stubby_family_stop() {
    mkdir -p "/opt/etc/allow/stubby" 2>/dev/null || true
    : > "$STUBBY_FAMILY_FLAG" 2>/dev/null || true
    [ -x "${MANAGED_DIR}/stubby-family.sh" ] && "${MANAGED_DIR}/stubby-family.sh" restart >/dev/null 2>&1 || true
    echo "SUCCESS=yes"
    echo "MESSAGE=Logging disabled"
}

# --- sing-box ---
SINGBOX_CONF="/opt/etc/allow/sing-box/config.json"
SINGBOX_LOG="/opt/var/log/allow/sing-box/sing-box.log"
SINGBOX_INIT=""
for n in S98sing-box X98sing-box; do
    if [ -x "${ETC_ALLOW}/init.d/${n}" ]; then SINGBOX_INIT="${ETC_ALLOW}/init.d/${n}"; break; fi
    if [ -x "/opt/etc/init.d/${n}" ]; then SINGBOX_INIT="/opt/etc/init.d/${n}"; break; fi
done

do_singbox_status() {
    LOGGING_ENABLED="no"
    LOG_FILE="$SINGBOX_LOG"
    [ -f "$SINGBOX_CONF" ] && grep -q '"disabled"[ \t]*:[ \t]*false' "$SINGBOX_CONF" 2>/dev/null && LOGGING_ENABLED="yes"
    out="$(grep -o '"output"[ \t]*:[ \t]*"[^"]*"' "$SINGBOX_CONF" 2>/dev/null | head -1)"
    [ -n "$out" ] && LOG_FILE="$(echo "$out" | sed 's/.*:[ \t]*"\([^"]*\)".*/\1/')"
    echo "LOGGING_ENABLED=$LOGGING_ENABLED"
    echo "LOG_FILE=$LOG_FILE"
}

do_singbox_start() {
    [ ! -f "$SINGBOX_CONF" ] && echo "SUCCESS=no" && echo "MESSAGE=Config not found" && return 1
    _tmp="/tmp/singbox-logging.$$"
    sed 's/"disabled"[ \t]*:[ \t]*true/"disabled": false/' "$SINGBOX_CONF" > "$_tmp" 2>/dev/null
    if [ -s "$_tmp" ]; then
        mv "$_tmp" "$SINGBOX_CONF" 2>/dev/null || { rm -f "$_tmp"; echo "SUCCESS=no"; echo "MESSAGE=Failed to write config"; return 1; }
    else
        rm -f "$_tmp"
        echo "SUCCESS=no"
        echo "MESSAGE=Failed to update config"
        return 1
    fi
    [ -x "$SINGBOX_INIT" ] && "$SINGBOX_INIT" restart >/dev/null 2>&1 || true
    echo "SUCCESS=yes"
    echo "MESSAGE=Logging enabled"
}

do_singbox_stop() {
    [ ! -f "$SINGBOX_CONF" ] && echo "SUCCESS=no" && echo "MESSAGE=Config not found" && return 1
    _tmp="/tmp/singbox-logging.$$"
    sed 's/"disabled"[ \t]*:[ \t]*false/"disabled": true/' "$SINGBOX_CONF" > "$_tmp" 2>/dev/null
    if [ -s "$_tmp" ]; then
        mv "$_tmp" "$SINGBOX_CONF" 2>/dev/null || { rm -f "$_tmp"; echo "SUCCESS=no"; echo "MESSAGE=Failed to write config"; return 1; }
    else
        rm -f "$_tmp"
        echo "SUCCESS=no"
        echo "MESSAGE=Failed to update config"
        return 1
    fi
    [ -x "$SINGBOX_INIT" ] && "$SINGBOX_INIT" restart >/dev/null 2>&1 || true
    echo "SUCCESS=yes"
    echo "MESSAGE=Logging disabled"
}

# --- main ---
COMPONENT="${1:-}"
CMD="${2:-}"

case "$CMD" in
    start|stop|status) ;;
    *) echo "Usage: $0 <component> <start|stop|status>" >&2; echo "Components: dnsmasq-full, dnsmasq-family, stubby, stubby-family, sing-box" >&2; exit 1 ;;
esac

case "$COMPONENT" in
    dnsmasq-full)
        case "$CMD" in
            status) do_dnsmasq_full_status ;;
            start)  do_dnsmasq_full_start ;;
            stop)   do_dnsmasq_full_stop ;;
        esac
        ;;
    dnsmasq-family)
        case "$CMD" in
            status) do_dnsmasq_family_status ;;
            start)  do_dnsmasq_family_start ;;
            stop)   do_dnsmasq_family_stop ;;
        esac
        ;;
    stubby)
        case "$CMD" in
            status) do_stubby_status ;;
            start)  do_stubby_start ;;
            stop)   do_stubby_stop ;;
        esac
        ;;
    stubby-family)
        case "$CMD" in
            status) do_stubby_family_status ;;
            start)  do_stubby_family_start ;;
            stop)   do_stubby_family_stop ;;
        esac
        ;;
    sing-box)
        case "$CMD" in
            status) do_singbox_status ;;
            start)  do_singbox_start ;;
            stop)   do_singbox_stop ;;
        esac
        ;;
    *)
        echo "Usage: $0 <component> <start|stop|status>" >&2
        echo "Components: dnsmasq-full, dnsmasq-family, stubby, stubby-family, sing-box" >&2
        exit 1
        ;;
esac
