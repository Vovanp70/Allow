#!/bin/sh

# Подскрипт для управления обязательными зависимостями
# Должен располагаться на роутере как /opt/tmp/allow/install.d/dependencies.sh

set -e

COMPONENT="dependencies"
PLATFORM="${2:-entware}"

LOG_DIR="/opt/var/log/allow/${COMPONENT}"
mkdir -p "$LOG_DIR"

LOG_FILE="${LOG_DIR}/${COMPONENT}.log"
STATE_KEY_INSTALLED="installed.${COMPONENT}"
STATE_KEY_PKGS="managed_pkgs.${COMPONENT}"

# Подключаем единое хранилище состояния
LIB_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${LIB_DIR}/state_lib.sh"

# Определяем, поддерживает ли терминал цвета
is_color_terminal() {
    [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]
}

if is_color_terminal; then
    COLOR_GREEN="\033[0;32m"
    COLOR_RED="\033[0;31m"
    COLOR_RESET="\033[0m"
else
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_RESET=""
fi

log() {
    TS="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$TS] $*" | tee -a "$LOG_FILE"
}

log_success() {
    TS="$(date '+%Y-%m-%d %H:%M:%S')"
    MSG="[$TS] $*"
    echo -e "${COLOR_GREEN}${MSG}${COLOR_RESET}" | tee -a "$LOG_FILE"
}

log_error() {
    TS="$(date '+%Y-%m-%d %H:%M:%S')"
    MSG="[$TS] $*"
    echo -e "${COLOR_RED}${MSG}${COLOR_RESET}" | tee -a "$LOG_FILE" >&2
}

detect_opkg_local() {
    if [ -n "$OPKG_BIN" ] && [ -x "$OPKG_BIN" ]; then
        return 0
    fi

    if [ -x /opt/bin/opkg ]; then
        OPKG_BIN="/opt/bin/opkg"
    elif [ -x /bin/opkg ]; then
        OPKG_BIN="/bin/opkg"
    elif [ -x /usr/bin/opkg ]; then
        OPKG_BIN="/usr/bin/opkg"
    else
        log_error "Ошибка: opkg не найден (ожидалось /opt/bin/opkg или /bin/opkg или /usr/bin/opkg)."
        exit 1
    fi
}

install_dependencies() {
    log "=== УСТАНОВКА ${COMPONENT} ==="
    log "Платформа: ${PLATFORM}"

    detect_opkg_local
    log "Использую opkg: ${OPKG_BIN}"

    # Обновляем список пакетов перед установкой
    log "Обновляю список пакетов opkg..."
    if "$OPKG_BIN" update >>"$LOG_FILE" 2>&1; then
        log "Список пакетов обновлен."
    else
        log "Предупреждение: не удалось обновить список пакетов (продолжаем установку)."
    fi

    # Обязательные зависимости: tcpdump, bind-dig (dig), ipset, iptables, mc, coreutils-sort, grep, gzip, kmod_ndms, xtables-addons_legacy
    # Временно отключены: ca-certificates ca-bundle (CA для TLS)
    DEPENDENCIES="tcpdump bind-dig ipset iptables mc coreutils-sort grep gzip kmod_ndms xtables-addons_legacy"

    # Список пакетов, которые поставили мы (для корректного uninstall)
    MANAGED_PKGS=""

    for pkg in $DEPENDENCIES; do
        if "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^${pkg} "; then
            log "Пакет ${pkg} уже установлен, пропускаю."
        else
            log "Устанавливаю пакет ${pkg}..."
            if "$OPKG_BIN" install "${pkg}" >>"$LOG_FILE" 2>&1; then
                log_success "Пакет ${pkg} успешно установлен."
                MANAGED_PKGS="${MANAGED_PKGS} ${pkg}"
            else
                log_error "Ошибка: не удалось установить обязательный пакет ${pkg}."
                exit 1
            fi
        fi
    done

    # Нормализуем пробелы и сохраняем состояние
    MANAGED_PKGS="$(echo "$MANAGED_PKGS" | awk '{$1=$1; print}')"
    state_set "$STATE_KEY_PKGS" "$MANAGED_PKGS"
    state_set "$STATE_KEY_INSTALLED" "$(date '+%Y-%m-%d %H:%M:%S')"

    log_success "=== УСТАНОВКА ${COMPONENT} ЗАВЕРШЕНА УСПЕШНО ==="
}

check_dependencies() {
    log "=== ПРОВЕРКА ${COMPONENT} ==="

    detect_opkg_local

    DEPENDENCIES="tcpdump bind-dig"
    ALL_OK=1

    for pkg in $DEPENDENCIES; do
        if "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^${pkg} "; then
            log_success "Пакет ${pkg} установлен."
        else
            log_error "Пакет ${pkg} не установлен."
            ALL_OK=0
        fi
    done

    if [ "$ALL_OK" -eq 1 ]; then
        log_success "=== ПРОВЕРКА ${COMPONENT}: OK ==="
        exit 0
    else
        log_error "=== ПРОВЕРКА ${COMPONENT}: НЕИСПРАВНО ==="
        exit 1
    fi
}

uninstall_dependencies() {
    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT} ==="

    # Проверка состояния установки (если не FORCE)
    if [ "${FORCE:-0}" != "1" ]; then
        if ! state_has "$STATE_KEY_INSTALLED"; then
            log "Компонент ${COMPONENT} не установлен (файл состояния не найден), пропускаю деинсталляцию."
            return 0
        fi
    fi

    detect_opkg_local

    # Удаляем только те пакеты, которые поставили мы
    PKGS="$(state_get "$STATE_KEY_PKGS")"
    if [ -n "$PKGS" ]; then
        for pkg in $PKGS; do
            [ -z "$pkg" ] && continue
            if "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^${pkg} "; then
                log "Удаляю пакет ${pkg} (установленный инсталятором Allow)..."
                if "$OPKG_BIN" remove "${pkg}" >>"$LOG_FILE" 2>&1; then
                    log_success "Пакет ${pkg} удалён."
                else
                    log_error "Ошибка: не удалось удалить пакет ${pkg}."
                fi
            else
                log "Пакет ${pkg} уже отсутствует, пропускаю."
            fi
        done
    else
        log "Список установленных инсталятором пакетов пуст."
    fi

    # Удаляем отметки состояния
    state_unset "$STATE_KEY_PKGS"
    state_unset "$STATE_KEY_INSTALLED"

    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT} ЗАВЕРШЕНА ==="

    # Удаляем логи в самом конце (после всех log вызовов)
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR" 2>/dev/null || true
    fi
}

ACTION="$1"

case "$ACTION" in
    install)
        install_dependencies
        ;;
    uninstall)
        uninstall_dependencies
        ;;
    check)
        check_dependencies
        ;;
    *)
        echo "Использование: $0 {install|uninstall|check}" >&2
        exit 1
        ;;
esac


