#!/bin/sh

# Установка markalltovpn: route-by-mark.sh + NDM netfilter хук 000-hotspot-vpn.sh
# Цель: /opt/etc/allow (route-by-mark.sh), /opt/etc/ndm/netfilter.d (000-hotspot-vpn.sh)
# При деинсталляции удаляется route-by-mark.state из /opt/etc/allow

set -e

COMPONENT="markalltovpn"
PLATFORM="${2:-entware}"

ETC_ALLOW="/opt/etc/allow"
NDM_DIR="/opt/etc/ndm/netfilter.d"
ROUTE_SCRIPT_DEST="${ETC_ALLOW}/route-by-mark.sh"
ROUTE_BY_MARK_STATE="/opt/etc/allow/route-by-mark.state"
NEED_DIR="${NEED_DIR:-/opt/tmp/allow/resources/${COMPONENT}}"
STATE_KEY_INSTALLED="installed.${COMPONENT}"
LOG_DIR="/opt/var/log/allow"
LOG_FILE="${LOG_DIR}/${COMPONENT}.log"

# Подключаем единое хранилище состояния
LIB_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${LIB_DIR}/state_lib.sh"

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
    TS="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$TS] $*" | tee -a "$LOG_FILE"
}

log_success() {
    log "OK: $*"
}

log_error() {
    log "ERROR: $*" >&2
}

install_markalltovpn() {
    log "=== УСТАНОВКА ${COMPONENT} ==="

    if [ ! -f "${NEED_DIR}/route-by-mark.sh" ]; then
        log_error "Файл не найден: ${NEED_DIR}/route-by-mark.sh"
        exit 1
    fi

    mkdir -p "$ETC_ALLOW" 2>/dev/null || true
    log "Копирую route-by-mark.sh в ${ROUTE_SCRIPT_DEST}..."
    cp -f "${NEED_DIR}/route-by-mark.sh" "$ROUTE_SCRIPT_DEST" 2>>"$LOG_FILE" || {
        log_error "Не удалось скопировать route-by-mark.sh"
        exit 1
    }
    chmod +x "$ROUTE_SCRIPT_DEST" 2>/dev/null || true
    sed -i 's/\r$//' "$ROUTE_SCRIPT_DEST" 2>/dev/null || true
    log_success "route-by-mark.sh установлен"

    if [ -f "${NEED_DIR}/netfilter.d/000-hotspot-vpn.sh" ]; then
        mkdir -p "$NDM_DIR" 2>/dev/null || true
        log "Копирую NDM netfilter хук 000-hotspot-vpn.sh в ${NDM_DIR}..."
        cp -f "${NEED_DIR}/netfilter.d/000-hotspot-vpn.sh" "${NDM_DIR}/000-hotspot-vpn.sh" 2>>"$LOG_FILE" || {
            log_error "Не удалось скопировать 000-hotspot-vpn.sh"
            exit 1
        }
        chmod +x "${NDM_DIR}/000-hotspot-vpn.sh" 2>/dev/null || true
        sed -i 's/\r$//' "${NDM_DIR}/000-hotspot-vpn.sh" 2>/dev/null || true
        log_success "000-hotspot-vpn.sh установлен"
        log "Перезапуск NDM netfilter (применение правил)..."
        for hook in "${NDM_DIR}/"*.sh; do
            [ -x "$hook" ] && sh "$hook" stop >>"$LOG_FILE" 2>&1 || true
        done
        for hook in "${NDM_DIR}/"*.sh; do
            [ -x "$hook" ] && sh "$hook" start >>"$LOG_FILE" 2>&1 || true
        done
    else
        log "Файл netfilter.d/000-hotspot-vpn.sh не найден, хук не устанавливается."
    fi

    state_set "$STATE_KEY_INSTALLED" "$(date '+%Y-%m-%d %H:%M:%S')"
    log "=== УСТАНОВКА ${COMPONENT} ЗАВЕРШЕНА ==="
}

uninstall_markalltovpn() {
    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT} ==="

    if [ "${FORCE:-0}" != "1" ] && ! state_has "$STATE_KEY_INSTALLED"; then
        log "Компонент ${COMPONENT} не установлен (состояние не найдено), пропускаю."
        return 0
    fi

    # Остановить NDM хук (delmark), затем удалить хук
    if [ -x "${NDM_DIR}/000-hotspot-vpn.sh" ]; then
        log "Останавливаю NDM хук 000-hotspot-vpn (delmark)..."
        sh "${NDM_DIR}/000-hotspot-vpn.sh" stop >>"$LOG_FILE" 2>&1 || true
        log "Удаляю ${NDM_DIR}/000-hotspot-vpn.sh..."
        rm -f "${NDM_DIR}/000-hotspot-vpn.sh" 2>/dev/null || true
    fi

    # Удалить правило марки, если скрипт ещё на месте
    if [ -x "$ROUTE_SCRIPT_DEST" ]; then
        log "Выполняю delmark..."
        sh "$ROUTE_SCRIPT_DEST" delmark >>"$LOG_FILE" 2>&1 || true
    fi

    # Удалить установленные файлы
    [ -f "$ROUTE_SCRIPT_DEST" ] && rm -f "$ROUTE_SCRIPT_DEST" 2>/dev/null && log "Удалён ${ROUTE_SCRIPT_DEST}" || true

    # Удалить временные/состояние файлы
    if [ -f "$ROUTE_BY_MARK_STATE" ]; then
        rm -f "$ROUTE_BY_MARK_STATE" 2>/dev/null && log "Удалён $ROUTE_BY_MARK_STATE" || true
    fi
    # Удаляем state-файл из /opt/etc/allow

    state_unset "$STATE_KEY_INSTALLED"
    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT} ЗАВЕРШЕНА ==="
}

case "${1:-}" in
    install)
        install_markalltovpn
        ;;
    uninstall)
        uninstall_markalltovpn
        ;;
    *)
        echo "Использование: $0 install | uninstall" >&2
        exit 1
        ;;
esac
