#!/bin/sh

# Установка единого скрипта автозапуска S01allow
# Объединяет все компоненты: stubby, dnsmasq-full, sing-box, monitor

set -e

COMPONENT="allow"
PLATFORM="${2:-entware}"

INITD_DIR="/opt/etc/init.d"
ALLOW_INITD_DIR="/opt/etc/allow/init.d"
# NEED_DIR может быть передан через переменную окружения, иначе используем значение по умолчанию
NEED_DIR="${NEED_DIR:-/opt/tmp/allow/resources/${COMPONENT}}"
STATE_KEY_INSTALLED="installed.${COMPONENT}"
LOG_DIR="/opt/var/log/allow/${COMPONENT}"
LOG_FILE="${LOG_DIR}/${COMPONENT}.log"

# Подключаем единое хранилище состояния
LIB_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${LIB_DIR}/state_lib.sh"

mkdir -p "$LOG_DIR" "$ALLOW_INITD_DIR" 2>/dev/null || true

# Определяем, поддерживает ли терминал цвета
is_color_terminal() {
    [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]
}

# Цветовые коды (если терминал поддерживает цвета)
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

install_allow() {
    log "=== УСТАНОВКА единого скрипта автозапуска S01allow ==="
    
    # Создаем директорию для скриптов компонентов
    log "Создаю директорию для скриптов компонентов: ${ALLOW_INITD_DIR}"
    mkdir -p "$ALLOW_INITD_DIR" 2>/dev/null || {
        log_error "Ошибка: не удалось создать директорию ${ALLOW_INITD_DIR}"
        exit 1
    }
    
    # Копируем S01allow
    if [ -f "${NEED_DIR}/init.d/S01allow" ]; then
        log "Копирую S01allow в ${INITD_DIR}..."
        cp -f "${NEED_DIR}/init.d/S01allow" "${INITD_DIR}/S01allow" 2>>"$LOG_FILE" || {
            log_error "Ошибка: не удалось скопировать S01allow"
            exit 1
        }
        chmod +x "${INITD_DIR}/S01allow" 2>/dev/null || true
        
        # Нормализуем окончания строк (CRLF -> LF)
        sed -i 's/\r$//' "${INITD_DIR}/S01allow" 2>/dev/null || true
        
        log_success "S01allow установлен"
        
        # Отмечаем успешную установку в state.db
        state_set "$STATE_KEY_INSTALLED" "$(date '+%Y-%m-%d %H:%M:%S')"
    else
        log_error "Ошибка: файл ${NEED_DIR}/init.d/S01allow не найден"
        exit 1
    fi
    
    log "=== УСТАНОВКА завершена ==="
}

uninstall_allow() {
    log "=== ДЕИНСТАЛЛЯЦИЯ S01allow ==="
    
    # Проверка состояния установки (если не FORCE)
    if [ "${FORCE:-0}" != "1" ]; then
        if ! state_has "$STATE_KEY_INSTALLED"; then
            log "Компонент ${COMPONENT} не установлен (файл состояния не найден), пропускаю деинсталляцию."
            return 0
        fi
    fi
    
    # Останавливаем все компоненты через S01allow
    if [ -x "${INITD_DIR}/S01allow" ]; then
        log "Останавливаю все компоненты..."
        sh "${INITD_DIR}/S01allow" stop >>"$LOG_FILE" 2>&1 || true
    fi
    
    # Удаляем S01allow
    if [ -f "${INITD_DIR}/S01allow" ]; then
        log "Удаляю S01allow..."
        rm -f "${INITD_DIR}/S01allow" 2>/dev/null || true
        log_success "S01allow удален"
    fi
    
    # Удаляем скрипты компонентов из /opt/etc/allow/init.d (динамически)
    log "Удаление init-скриптов компонентов из ${ALLOW_INITD_DIR}..."
    removed=0

    if [ -d "$ALLOW_INITD_DIR" ]; then
        for script_path in "$ALLOW_INITD_DIR"/*; do
            if [ -f "$script_path" ]; then
                script_name="$(basename "$script_path")"
                log "Удаление: ${script_name}"
                rm -f "$script_path" 2>/dev/null || true
                removed=$((removed + 1))
            fi
        done
    fi

    if [ "$removed" -gt 0 ]; then
        log_success "Удалено init-скриптов: $removed"
    else
        log "init-скрипты в ${ALLOW_INITD_DIR} не найдены (или уже удалены)."
    fi
    
    # Удаляем директорию, если она пуста
    if [ -d "$ALLOW_INITD_DIR" ]; then
        if [ -z "$(ls -A "$ALLOW_INITD_DIR" 2>/dev/null)" ]; then
            log "Удаление пустой директории ${ALLOW_INITD_DIR}..."
            rmdir "$ALLOW_INITD_DIR" 2>/dev/null || true
        fi
    fi
    
    # Удаляем отметку состояния
    state_unset "$STATE_KEY_INSTALLED"
    
    log "=== ДЕИНСТАЛЛЯЦИЯ завершена ==="
    
    # Удаляем логи в самом конце (после всех log вызовов)
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR" 2>/dev/null || true
    fi
}

check_allow() {
    log "=== ПРОВЕРКА S01allow ==="
    
    if [ ! -f "${INITD_DIR}/S01allow" ]; then
        log_error "S01allow не установлен"
        return 1
    fi
    
    if [ ! -x "${INITD_DIR}/S01allow" ]; then
        log_error "S01allow не имеет прав на выполнение"
        return 1
    fi
    
    log "Проверка статуса всех компонентов..."
    if sh "${INITD_DIR}/S01allow" status >>"$LOG_FILE" 2>&1; then
        log_success "S01allow работает корректно"
        return 0
    else
        log_error "Ошибка при проверке статуса"
        return 1
    fi
}

# Основная логика
case "$1" in
    install)
        install_allow
        ;;
    uninstall)
        uninstall_allow
        ;;
    check)
        check_allow
        ;;
    *)
        echo "Использование: $0 {install|uninstall|check}"
        exit 1
        ;;
esac

exit 0

