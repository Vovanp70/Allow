#!/bin/sh

# Управление выборочным роутингом на sing-box по ИНТЕРФЕЙСУ.
# Логика: весь трафик, приходящий с выбранного L2-сегмента (brX), помечается маркой 0x4
# и уходит в таблицу 111 -> интерфейс sbtun0 (маршрут/правило создаёт X98sing-box).
#
# Использование:
#   route-by-mark.sh addrule <iface>   # включить: весь трафик с iface -> VPN (через mark 0x4)
#   route-by-mark.sh delrule           # выключить и очистить state
#   route-by-mark.sh sync              # восстановить правила по сохранённому iface (вызов из NDM hook)
#
# Для совместимости принимаются также:
#   addiface (как addrule), deliface/delmark (как delrule).

ROUTE_TABLE=111           # Таблица маршрутизации для sing-box (создаёт X98sing-box)
VPN_IFACE="sbtun0"
MARK_VALUE="0x4"          # fwmark, который уже используется X98sing-box (bypass -> VPN)

STATE_DIR="/opt/etc/allow"
STATE_FILE="${STATE_DIR}/route-by-mark.state"

ensure_state_dir() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
}

# Сохраняем выбранный исходный интерфейс в state
save_iface() {
    ensure_state_dir
    IFACE_SRC_VALUE="${1:-}"
    if [ -z "$IFACE_SRC_VALUE" ]; then
        IFACE_SRC_VALUE="none"
    fi
    {
        printf 'IFACE_SRC=%s\n' "$IFACE_SRC_VALUE"
    } >"$STATE_FILE" 2>/dev/null || true
}

# Загружаем iface из state
load_iface() {
    IFACE_SRC="none"
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE" 2>/dev/null || true
    fi
    echo "${IFACE_SRC:-none}"
}

# Добавляет iptables-правила для пометки трафика с указанного интерфейса.
iptables_add_rules_for_iface() {
    _src_if="${1:-}"
    [ -z "$_src_if" ] && return 1

    # Проверяем, что интерфейс существует
    if ! ip link show "$_src_if" >/dev/null 2>&1; then
        echo "[!] Исходный интерфейс $_src_if не найден."
        return 1
    fi

    # MARK 0x4 для всего трафика, приходящего с iface
    if ! iptables -t mangle -C PREROUTING -i "$_src_if" -j MARK --set-xmark "${MARK_VALUE}/${MARK_VALUE}" 2>/dev/null; then
        iptables -t mangle -A PREROUTING -i "$_src_if" -j MARK --set-xmark "${MARK_VALUE}/${MARK_VALUE}" 2>/dev/null || true
        echo "[+] Добавлено правило: mangle PREROUTING -i $_src_if MARK ${MARK_VALUE}"
    fi

    # Сохраняем марку в CONNMARK для всего соединения
    if ! iptables -t mangle -C PREROUTING -i "$_src_if" -m mark --mark "${MARK_VALUE}/${MARK_VALUE}" \
        -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff 2>/dev/null; then
        iptables -t mangle -A PREROUTING -i "$_src_if" -m mark --mark "${MARK_VALUE}/${MARK_VALUE}" \
            -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff 2>/dev/null || true
        echo "[+] Добавлено правило: mangle PREROUTING -i $_src_if CONNMARK save (${MARK_VALUE})"
    fi

    # Маршрутизация по mark 0x4/0x4 и table 111 на sbtun0 создаётся X98sing-box.
    # Здесь лишь проверяем, что интерфейс VPN существует (для информативного сообщения).
    if ! ip link show "$VPN_IFACE" >/dev/null 2>&1; then
        echo "[!] Внимание: интерфейс $VPN_IFACE не найден. Убедитесь, что sing-box запущен."
    fi

    return 0
}

# Удаляет iptables-правила для интерфейса (только те, что мы сами создаём).
iptables_del_rules_for_iface() {
    _src_if="${1:-}"
    [ -z "$_src_if" ] && return 0

    iptables -t mangle -D PREROUTING -i "$_src_if" -m mark --mark "${MARK_VALUE}/${MARK_VALUE}" \
        -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff 2>/dev/null || true
    iptables -t mangle -D PREROUTING -i "$_src_if" -j MARK --set-xmark "${MARK_VALUE}/${MARK_VALUE}" 2>/dev/null || true

    return 0
}

# Включить роутинг для указанного iface
add_rule() {
    NEW_IFACE_SRC="${1:-}"
    if [ -z "$NEW_IFACE_SRC" ]; then
        echo "[!] Не указан интерфейс. Использование: $0 addrule <iface>"
        return 1
    fi

    # Старый iface из state
    CURRENT_IFACE_SRC="$(load_iface)"

    # Если был другой интерфейс — удаляем его правила
    if [ -n "$CURRENT_IFACE_SRC" ] && [ "$CURRENT_IFACE_SRC" != "none" ] && [ "$CURRENT_IFACE_SRC" != "$NEW_IFACE_SRC" ]; then
        iptables_del_rules_for_iface "$CURRENT_IFACE_SRC"
    fi

    # Применяем правила для нового iface
    if ! iptables_add_rules_for_iface "$NEW_IFACE_SRC"; then
        echo "[!] Не удалось применить правила для интерфейса $NEW_IFACE_SRC."
        return 1
    fi

    save_iface "$NEW_IFACE_SRC"
    echo "[+] Включён роутинг через sing-box для интерфейса $NEW_IFACE_SRC (mark ${MARK_VALUE} -> table ${ROUTE_TABLE})."
    return 0
}

# Восстанавливает правила по интерфейсу из state. Вызывается NDM-хуком при start/ifup/wanup.
sync_rule() {
    CURRENT_IFACE_SRC="$(load_iface)"
    if [ -z "$CURRENT_IFACE_SRC" ] || [ "$CURRENT_IFACE_SRC" = "none" ]; then
        return 0
    fi

    iptables_add_rules_for_iface "$CURRENT_IFACE_SRC" >/dev/null 2>&1 || true
    return 0
}

# Выключить роутинг и очистить state
del_rule() {
    CURRENT_IFACE_SRC="$(load_iface)"
    if [ -z "$CURRENT_IFACE_SRC" ] || [ "$CURRENT_IFACE_SRC" = "none" ]; then
        echo "[.] Сохранённого интерфейса нет, удалять нечего."
        return 0
    fi

    iptables_del_rules_for_iface "$CURRENT_IFACE_SRC"
    save_iface "none"
    echo "[+] Роутинг через sing-box для интерфейса $CURRENT_IFACE_SRC отключён."
    return 0
}

cmd="${1:-}"
case "$cmd" in
  addrule|addiface)
    shift
    add_rule "${1:-}"
    ;;
  delrule|deliface|delmark)
    del_rule
    ;;
  sync|"")
    sync_rule
    ;;
  *)
    echo "Использование: $0 addrule <iface> | delrule | sync"
    exit 1
    ;;
esac

exit 0
