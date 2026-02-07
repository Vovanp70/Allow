#!/bin/sh
#
# Управление DNSMASQ full для монитора: status, restart.
# Вывод в формате KEY=value для разбора CGI.
# Использование: dnsmasq.sh status | restart
#

PATH="/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin"; export PATH

ETC_ALLOW="${ETC_ALLOW:-/opt/etc/allow}"
INIT_ALLOW="${ETC_ALLOW}/init.d"
INIT_SYSTEM="/opt/etc/init.d"
DNSMASQ_INIT=""
for n in S98dnsmasq-full X98dnsmasq-full; do
    if [ -x "${INIT_ALLOW}/${n}" ]; then DNSMASQ_INIT="${INIT_ALLOW}/${n}"; break; fi
    if [ -x "${INIT_SYSTEM}/${n}" ]; then DNSMASQ_INIT="${INIT_SYSTEM}/${n}"; break; fi
done
DNSMASQ_CONF="/opt/etc/allow/dnsmasq-full/dnsmasq.conf"
DNSMASQ_LOG="/opt/var/log/allow/dnsmasq.log"
DEFAULT_PORT="5300"

get_kv() {
    key="$1"
    [ -x "$DNSMASQ_INIT" ] || return 1
    out="$("$DNSMASQ_INIT" status --kv 2>/dev/null)" || true
    line="$(echo "$out" | grep "^${key}=" | head -1)"
    [ -n "$line" ] && echo "${line#*=}" && return 0
    return 1
}

check_port_udp() {
    port="$1"
    if command -v nc >/dev/null 2>&1; then
        nc -z -u 127.0.0.1 "$port" 2>/dev/null && return 0
    fi
    return 1
}

cmd_status() {
    STATUS="stopped"
    PORT="$DEFAULT_PORT"
    PID=""
    PORT_OPEN="no"
    CONFIG_PORT=""
    ACTIVE_PORT=""
    EFFECTIVE_PORT=""
    MISMATCH="no"
    LOGGING_ENABLED="no"
    LOG_FILE="$DNSMASQ_LOG"

    [ -x "$DNSMASQ_INIT" ] && out="$("$DNSMASQ_INIT" status --kv 2>/dev/null)" || out=""
    [ -n "$out" ] && STATUS="$(echo "$out" | grep "^STATUS=" | head -1 | sed 's/^STATUS=//')"
    [ -n "$out" ] && PORT="$(echo "$out" | grep "^EFFECTIVE_PORT=" | head -1 | sed 's/^EFFECTIVE_PORT=//')"
    [ -z "$PORT" ] && PORT="$(echo "$out" | grep "^CONFIG_PORT=" | head -1 | sed 's/^CONFIG_PORT=//')"
    [ -z "$PORT" ] && PORT="$DEFAULT_PORT"
    [ -n "$out" ] && PID="$(echo "$out" | grep "^PID=" | head -1 | sed 's/^PID=//')"
    [ -n "$out" ] && CONFIG_PORT="$(echo "$out" | grep "^CONFIG_PORT=" | head -1 | sed 's/^CONFIG_PORT=//')"
    [ -n "$out" ] && ACTIVE_PORT="$(echo "$out" | grep "^ACTIVE_PORT=" | head -1 | sed 's/^ACTIVE_PORT=//')"
    [ -n "$out" ] && EFFECTIVE_PORT="$(echo "$out" | grep "^EFFECTIVE_PORT=" | head -1 | sed 's/^EFFECTIVE_PORT=//')"
    [ -n "$out" ] && tmp="$(echo "$out" | grep "^MISMATCH=" | head -1 | sed 's/^MISMATCH=//')" && [ "$tmp" = "yes" ] && MISMATCH="yes"
    [ -n "$out" ] && LOG_FILE="$(echo "$out" | grep "^LOG_FILE=" | head -1 | sed 's/^LOG_FILE=//')"
    [ -z "$LOG_FILE" ] && LOG_FILE="$DNSMASQ_LOG"
    [ -z "$CONFIG_PORT" ] && CONFIG_PORT="$PORT"
    [ -z "$ACTIVE_PORT" ] && ACTIVE_PORT="$PORT"
    [ -z "$EFFECTIVE_PORT" ] && EFFECTIVE_PORT="$PORT"

    if [ "$STATUS" = "running" ] && [ -n "$PORT" ]; then
        check_port_udp "$PORT" && PORT_OPEN="yes"
    fi

    if [ -f "$DNSMASQ_CONF" ]; then
        grep -q '^[[:space:]]*log-queries' "$DNSMASQ_CONF" 2>/dev/null && LOGGING_ENABLED="yes" || true
    fi

    echo "STATUS=$STATUS"
    echo "PORT=$PORT"
    echo "PID=$PID"
    echo "PORT_OPEN=$PORT_OPEN"
    echo "CONFIG_PORT=$CONFIG_PORT"
    echo "ACTIVE_PORT=$ACTIVE_PORT"
    echo "EFFECTIVE_PORT=$EFFECTIVE_PORT"
    echo "MISMATCH=$MISMATCH"
    echo "LOGGING_ENABLED=$LOGGING_ENABLED"
    echo "LOG_FILE=$LOG_FILE"
}

cmd_restart() {
    if [ -x "$DNSMASQ_INIT" ]; then
        "$DNSMASQ_INIT" restart >/dev/null 2>&1 && true
        sleep 2
        out="$("$DNSMASQ_INIT" status --kv 2>/dev/null)" || true
        st="$(echo "$out" | grep "^STATUS=" | head -1 | sed 's/^STATUS=//')"
        if [ "$st" = "running" ]; then
            echo "SUCCESS=yes"
            echo "MESSAGE=DNSMASQ restarted successfully"
        else
            echo "SUCCESS=no"
            echo "MESSAGE=Failed to start"
        fi
    else
        echo "SUCCESS=no"
        echo "MESSAGE=Init script not found"
    fi
}

case "${1:-}" in
    status)  cmd_status ;;
    restart) cmd_restart ;;
    *)       echo "Usage: $0 status|restart" >&2; exit 1 ;;
esac
