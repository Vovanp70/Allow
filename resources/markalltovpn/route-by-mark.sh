#!/bin/sh

# Ручное управление правилом маршрутизации: трафик с указанной маркой -> table 111 -> sbtun0 (VPN).
# Использование: route-by-mark.sh addmark <hex_mark> | delmark | sync
# addmark — задаёт марку и применяет правило (вызов пользователем или UI).
# delmark — удаляет правило и очищает state.
# sync — восстанавливает правило по сохранённой в state марке (вызов NDM-хуком при start/ifup/wanup).

ROUTE_TABLE=111
IFACE="sbtun0"
STATE_DIR="/opt/etc/allow"
STATE_FILE="${STATE_DIR}/route-by-mark.state"

ensure_state_dir() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
}

save_mark() {
    ensure_state_dir
    MARK_VALUE="${1:-}"
    if [ -z "$MARK_VALUE" ]; then
        echo "MARK=nomark" >"$STATE_FILE" 2>/dev/null || true
    else
        printf 'MARK=%s\n' "$MARK_VALUE" >"$STATE_FILE" 2>/dev/null || true
    fi
}

load_mark() {
    MARK=""
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE" 2>/dev/null || true
    fi
    echo "${MARK:-}"
}

# Применяет ip rule + маршрут для марки. Не трогает state.
apply_rule() {
    _mark="${1:-}"
    if [ -z "$_mark" ]; then
        return 1
    fi
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        echo "[!] Интерфейс $IFACE не найден (sing-box должен быть запущен)."
        return 1
    fi
    if ip rule show | grep -q "fwmark ${_mark}.*lookup ${ROUTE_TABLE}"; then
        echo "[.] Правило уже есть: fwmark ${_mark} -> table ${ROUTE_TABLE}"
    else
        ip rule add fwmark ${_mark} table ${ROUTE_TABLE} priority 98 && \
            echo "[+] Добавлено: ip rule fwmark ${_mark} table ${ROUTE_TABLE} prio 98"
    fi
    ip route replace table ${ROUTE_TABLE} default dev ${IFACE} 2>/dev/null && \
        echo "[+] Маршрут: table ${ROUTE_TABLE} default dev ${IFACE}"
    return 0
}

add_rule() {
    ROUTE_MARK_HOTSPOT="${1:-}"
    if [ -z "$ROUTE_MARK_HOTSPOT" ]; then
        echo "[!] Не указана марка. Использование: $0 addmark <hex_mark>"
        return 1
    fi
    apply_rule "$ROUTE_MARK_HOTSPOT" || return 1
    save_mark "$ROUTE_MARK_HOTSPOT"
}

# Восстанавливает правило по марке из state. Вызывается NDM-хуком при start/ifup/wanup.
sync_rule() {
    CURRENT_MARK="$(load_mark)"
    if [ -z "$CURRENT_MARK" ] || [ "$CURRENT_MARK" = "nomark" ]; then
        return 0
    fi
    apply_rule "$CURRENT_MARK" >/dev/null 2>&1 || true
    return 0
}

del_rule() {
    CURRENT_MARK="$(load_mark)"
    if [ -z "$CURRENT_MARK" ] || [ "$CURRENT_MARK" = "nomark" ]; then
        echo "[.] Сохранённой метки нет, удалять нечего."
        return 0
    fi

    if ip rule show | grep -q "fwmark ${CURRENT_MARK}.*lookup ${ROUTE_TABLE}"; then
        ip rule del fwmark "${CURRENT_MARK}" table "${ROUTE_TABLE}" priority 98 2>/dev/null && \
            echo "[+] Удалено правило fwmark ${CURRENT_MARK} -> table ${ROUTE_TABLE}" || \
            echo "[.] Не удалось удалить правило fwmark ${CURRENT_MARK} -> table ${ROUTE_TABLE} (возможно, уже удалено)."
    else
        echo "[.] Правило fwmark ${CURRENT_MARK} -> table ${ROUTE_TABLE} не найдено."
    fi

    # Очищаем состояние
    save_mark "nomark"
}

case "${1:-}" in
  addmark)
    shift
    add_rule "${1:-}"
    ;;
  delmark)
    del_rule
    ;;
  sync)
    sync_rule
    ;;
  *)
    echo "Использование: $0 addmark <hex_mark> | delmark | sync"
    exit 1
    ;;
esac

exit 0
