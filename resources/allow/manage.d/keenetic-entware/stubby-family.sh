#!/bin/sh
#
# Управление Stubby Family для монитора: status, start, stop, restart.
# Вывод в формате KEY=value (по одной строке) для разбора CGI.
# Использование: stubby-family.sh status | start | stop | restart
#

set -e

PATH="/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin"; export PATH

ETC_ALLOW="${ETC_ALLOW:-/opt/etc/allow}"
VAR_RUN="${VAR_RUN:-/opt/var/run}"
STUBBY_ETC="${ETC_ALLOW}/stubby"
STUBBY_FAMILY_CONFIG="${STUBBY_ETC}/stubby-family.yml"
STUBBY_FAMILY_PID="${VAR_RUN}/stubby-family.pid"
INIT_ALLOW="${ETC_ALLOW}/init.d"
INIT_SYSTEM="/opt/etc/init.d"
STUBBY_FAMILY_INIT=""
for n in S97stubby-family X97stubby-family; do
    if [ -x "${INIT_ALLOW}/${n}" ]; then STUBBY_FAMILY_INIT="${INIT_ALLOW}/${n}"; break; fi
    if [ -x "${INIT_SYSTEM}/${n}" ]; then STUBBY_FAMILY_INIT="${INIT_SYSTEM}/${n}"; break; fi
done

DEFAULT_PORT="41501"

# --- Проверка порта TCP (nc или /dev/tcp) ---
check_port() {
    port="$1"
    if command -v nc >/dev/null 2>&1; then
        nc -z 127.0.0.1 "$port" 2>/dev/null && return 0
        return 1
    fi
    if [ -n "$(command -v timeout)" ]; then
        timeout 1 sh -c "echo >/dev/tcp/127.0.0.1/$port" 2>/dev/null && return 0
    fi
    return 1
}

# --- Парсинг status --kv: одна строка KEY=VALUE ---
get_kv() {
    key="$1"
    [ -x "$STUBBY_FAMILY_INIT" ] || return 1
    out="$("$STUBBY_FAMILY_INIT" status --kv 2>/dev/null)" || true
    line="$(echo "$out" | grep "^${key}=" | head -1)"
    [ -n "$line" ] && echo "${line#*=}" && return 0
    return 1
}

# --- Проверка процесса stubby-family (pid или ps) ---
is_stubby_family_running() {
    if [ -f "$STUBBY_FAMILY_PID" ]; then
        pid="$(cat "$STUBBY_FAMILY_PID" 2>/dev/null | tr -d '\r\n')"
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            cmd="$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ')"
            case "$cmd" in *stubby*stubby-family.yml*) return 0 ;; esac
        fi
    fi
    ps w 2>/dev/null | grep -v grep | grep "stubby" | grep -q "stubby-family.yml" && return 0
    return 1
}

# --- status: вывод KEY=value ---
cmd_status() {
    STATUS="stopped"
    PORT="$DEFAULT_PORT"
    PID=""
    PORT_OPEN="no"
    CONFIG_PORT=""
    ACTIVE_PORT=""
    EFFECTIVE_PORT=""
    MISMATCH="no"

    kv_status="$(get_kv "STATUS")" && [ -n "$kv_status" ] && STATUS="$kv_status"
    kv_port="$(get_kv "EFFECTIVE_PORT")" && [ -n "$kv_port" ] && PORT="$kv_port"
    kv_port="$(get_kv "CONFIG_PORT")" && [ -n "$kv_port" ] && CONFIG_PORT="$kv_port"
    kv_port="$(get_kv "ACTIVE_PORT")" && [ -n "$kv_port" ] && ACTIVE_PORT="$kv_port"
    kv_port="$(get_kv "EFFECTIVE_PORT")" && [ -n "$kv_port" ] && EFFECTIVE_PORT="$kv_port"
    kv_mismatch="$(get_kv "MISMATCH")" && [ "$kv_mismatch" = "yes" ] && MISMATCH="yes"
    kv_pid="$(get_kv "PID")" && [ -n "$kv_pid" ] && PID="$kv_pid"

    if is_stubby_family_running; then
        STATUS="running"
        [ -z "$PID" ] && [ -f "$STUBBY_FAMILY_PID" ] && PID="$(cat "$STUBBY_FAMILY_PID" 2>/dev/null | tr -d '\r\n')"
        [ -z "$PID" ] && PID="$(ps w 2>/dev/null | grep -v grep | grep 'stubby.*stubby-family.yml' | awk '{print $1}' | head -1)"
    else
        STATUS="stopped"
    fi

    if [ "$STATUS" = "running" ] && [ -n "$PORT" ]; then
        check_port "$PORT" && PORT_OPEN="yes"
    fi

    [ -z "$CONFIG_PORT" ] && CONFIG_PORT="$PORT"
    [ -z "$ACTIVE_PORT" ] && ACTIVE_PORT="$PORT"
    [ -z "$EFFECTIVE_PORT" ] && EFFECTIVE_PORT="$PORT"

    echo "STATUS=$STATUS"
    echo "PORT=$PORT"
    echo "PID=$PID"
    echo "PORT_OPEN=$PORT_OPEN"
    echo "CONFIG_PORT=$CONFIG_PORT"
    echo "ACTIVE_PORT=$ACTIVE_PORT"
    echo "EFFECTIVE_PORT=$EFFECTIVE_PORT"
    echo "MISMATCH=$MISMATCH"
}

# --- start ---
cmd_start() {
    if is_stubby_family_running; then
        echo "SUCCESS=no"
        echo "MESSAGE=Stubby Family already running"
        exit 0
    fi
    if [ -f "$STUBBY_FAMILY_CONFIG" ] && command -v stubby >/dev/null 2>&1; then
        if ! stubby -C "$STUBBY_FAMILY_CONFIG" -i >/dev/null 2>&1; then
            echo "SUCCESS=no"
            echo "MESSAGE=Stubby Family configuration is invalid"
            exit 0
        fi
    fi
    if [ -x "$STUBBY_FAMILY_INIT" ]; then
        "$STUBBY_FAMILY_INIT" start >/dev/null 2>&1 || true
        sleep 2
    fi
    if is_stubby_family_running; then
        echo "SUCCESS=yes"
        echo "MESSAGE=Stubby Family started successfully"
    else
        echo "SUCCESS=no"
        echo "MESSAGE=Failed to start"
    fi
}

# --- stop ---
cmd_stop() {
    if ! is_stubby_family_running; then
        echo "SUCCESS=no"
        echo "MESSAGE=Stubby Family is not running"
        exit 0
    fi
    [ -x "$STUBBY_FAMILY_INIT" ] && "$STUBBY_FAMILY_INIT" stop 2>/dev/null || true
    sleep 2
    if is_stubby_family_running; then
        pids="$(pgrep -f 'stubby.*stubby-family.yml' 2>/dev/null)" || true
        for p in $pids; do
            [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true
        done
        sleep 1
    fi
    if ! is_stubby_family_running; then
        echo "SUCCESS=yes"
        echo "MESSAGE=Stubby Family stopped successfully"
    else
        echo "SUCCESS=no"
        echo "MESSAGE=Failed to stop"
    fi
}

# --- restart ---
cmd_restart() {
    [ -x "$STUBBY_FAMILY_INIT" ] && "$STUBBY_FAMILY_INIT" stop 2>/dev/null || true
    sleep 2
    [ -x "$STUBBY_FAMILY_INIT" ] && "$STUBBY_FAMILY_INIT" start 2>/dev/null || true
    sleep 2
    if is_stubby_family_running; then
        echo "SUCCESS=yes"
        echo "MESSAGE=Stubby Family restarted successfully"
    else
        echo "SUCCESS=no"
        echo "MESSAGE=Failed to start"
    fi
}

# --- main ---
case "${1:-}" in
    status)  cmd_status ;;
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    *)       echo "Usage: $0 status|start|stop|restart" >&2; exit 1 ;;
esac
