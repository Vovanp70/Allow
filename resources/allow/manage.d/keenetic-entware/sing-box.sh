#!/bin/sh
#
# Управление sing-box для монитора: status, start, stop, restart.
# Вывод в формате KEY=value для разбора CGI.
# Использование: sing-box.sh status | start | stop | restart
#

PATH="/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin"; export PATH

ETC_ALLOW="${ETC_ALLOW:-/opt/etc/allow}"
INIT_ALLOW="${ETC_ALLOW}/init.d"
INIT_SYSTEM="/opt/etc/init.d"

SINGBOX_INIT=""
for n in S98sing-box X98sing-box; do
    if [ -x "${INIT_ALLOW}/${n}" ]; then SINGBOX_INIT="${INIT_ALLOW}/${n}"; break; fi
    if [ -x "${INIT_SYSTEM}/${n}" ]; then SINGBOX_INIT="${INIT_SYSTEM}/${n}"; break; fi
done

SINGBOX_LOG="/opt/var/log/allow/sing-box/sing-box.log"

cmd_status() {
    STATUS="stopped"
    PID=""

    if [ -x "$SINGBOX_INIT" ]; then
        out="$("$SINGBOX_INIT" status --kv 2>/dev/null)" || out=""
        [ -n "$out" ] && STATUS="$(echo "$out" | grep "^STATUS=" | head -1 | sed 's/^STATUS=//')"
        [ -n "$out" ] && PID="$(echo "$out" | grep "^PID=" | head -1 | sed 's/^PID=//')"
    fi

    [ -z "$STATUS" ] && STATUS="stopped"

    echo "STATUS=$STATUS"
    echo "PID=$PID"
}

cmd_action() {
    action="$1"

    if [ ! -x "$SINGBOX_INIT" ]; then
        echo "SUCCESS=no"
        echo "MESSAGE=Init script not found"
        return 0
    fi

    "$SINGBOX_INIT" "$action" >/dev/null 2>&1 || true
    sleep 2

    out="$("$SINGBOX_INIT" status --kv 2>/dev/null)" || out=""
    st="$(echo "$out" | grep "^STATUS=" | head -1 | sed 's/^STATUS=//')"

    case "$action" in
        start|restart)
            if [ "$st" = "running" ]; then
                echo "SUCCESS=yes"
                [ "$action" = "start" ] && echo "MESSAGE=sing-box started successfully" || echo "MESSAGE=sing-box restarted successfully"
            else
                echo "SUCCESS=no"
                echo "MESSAGE=Failed to start"
            fi
            ;;
        stop)
            if [ "$st" = "running" ]; then
                echo "SUCCESS=no"
                echo "MESSAGE=Failed to stop"
            else
                echo "SUCCESS=yes"
                echo "MESSAGE=sing-box stopped successfully"
            fi
            ;;
        *)
            echo "SUCCESS=no"
            echo "MESSAGE=Unknown action"
            ;;
    esac
}

case "${1:-}" in
    status)  cmd_status ;;
    start)   cmd_action start ;;
    stop)    cmd_action stop ;;
    restart) cmd_action restart ;;
    *)
        echo "Usage: $0 status|start|stop|restart" >&2
        exit 1
        ;;
esac

