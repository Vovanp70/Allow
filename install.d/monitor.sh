#!/bin/sh

# Управление компонентом monitor (Flask UI)
# Размещение: /opt/tmp/allow/install.d/monitor.sh

set -e

COMPONENT="monitor"
PLATFORM="${2:-entware}"

CONF_DIR="/opt/etc/allow/${COMPONENT}"
LOG_DIR="/opt/var/log/allow/${COMPONENT}"
APP_DIR="/opt/etc/allow/${COMPONENT}"
INITD_DIR="/opt/etc/init.d"
ALLOW_INITD_DIR="/opt/etc/allow/init.d"
# NEED_DIR может быть передан через переменную окружения, иначе используем значение по умолчанию
NEED_DIR="${NEED_DIR:-/opt/tmp/allow/resources/${COMPONENT}}"
PID_FILE="/opt/var/run/${COMPONENT}.pid"
LOG_FILE="${LOG_DIR}/${COMPONENT}.install.log"
STATE_KEY_INSTALLED="installed.${COMPONENT}"

# Подключаем единое хранилище состояния
LIB_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${LIB_DIR}/state_lib.sh"

mkdir -p "$CONF_DIR" "$LOG_DIR" "$APP_DIR" "/opt/var/run"

log() {
    TS="$(date '+%Y-%m-%d %H:%M:%S')"
    # Создаем директорию логов, если её нет (для случаев деинсталляции)
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    echo "[$TS] $*" | tee -a "$LOG_FILE" 2>/dev/null || echo "[$TS] $*"
}

log_success() {
    log "$@"
}

log_error() {
    log "$@" >&2
}

detect_opkg() {
    if [ -n "$OPKG_BIN" ] && [ -x "$OPKG_BIN" ]; then
        return 0
    fi
    for c in /opt/bin/opkg /bin/opkg /usr/bin/opkg; do
        if [ -x "$c" ]; then
            OPKG_BIN="$c"
            return 0
        fi
    done
    log "Ошибка: opkg не найден."
    exit 1
}

ensure_python() {
    detect_opkg
    NEED_PKGS="python3 python3-pip"
    for p in $NEED_PKGS; do
        if ! "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^${p} "; then
            log "Устанавливаю пакет ${p}..."
            "$OPKG_BIN" update >>"$LOG_FILE" 2>&1 || true
            "$OPKG_BIN" install "$p" >>"$LOG_FILE" 2>&1
        fi
    done

    # Устанавливаем Flask через pip (пакета python3-flask может не быть)
    if command -v /opt/bin/pip3 >/dev/null 2>&1; then
        PIP_BIN="/opt/bin/pip3"
    elif command -v pip3 >/dev/null 2>&1; then
        PIP_BIN="pip3"
    else
        log "Ошибка: pip3 не найден после установки python3-pip."
        exit 1
    fi

    # Устанавливаем переменные окружения для работы pip из временной директории
    # Используем постоянную директорию для временных файлов pip
    mkdir -p /opt/tmp /opt/var/tmp
    export TMPDIR="/opt/tmp"
    export TEMP="/opt/tmp"
    export TMP="/opt/tmp"
    
    # Переходим в постоянную директорию перед запуском pip
    ORIG_PWD="$PWD"
    cd /opt/tmp || cd /tmp || true

    log "Устанавливаю Flask через pip..."
    if ! env TMPDIR=/opt/tmp TEMP=/opt/tmp TMP=/opt/tmp "$PIP_BIN" install --no-cache-dir --no-warn-script-location --upgrade pip >>"$LOG_FILE" 2>&1; then
        log "Предупреждение: не удалось обновить pip (продолжаем)."
    fi
    if ! env TMPDIR=/opt/tmp TEMP=/opt/tmp TMP=/opt/tmp "$PIP_BIN" install --no-cache-dir --no-warn-script-location Flask >>"$LOG_FILE" 2>&1; then
        log "Ошибка: не удалось установить Flask через pip."
        cd "$ORIG_PWD" 2>/dev/null || true
        exit 1
    fi
    
    # Возвращаемся в исходную директорию
    cd "$ORIG_PWD" 2>/dev/null || true
}

install_monitor() {
    log "=== УСТАНОВКА ${COMPONENT} ==="
    ensure_python

    log "Копирую приложение в ${APP_DIR}..."
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR"
    cp -R "${NEED_DIR}/etc/monitor/." "$APP_DIR"/

    # Создаем директорию для скриптов компонентов
    mkdir -p "$ALLOW_INITD_DIR" 2>/dev/null || {
        log_error "Ошибка: не удалось создать директорию ${ALLOW_INITD_DIR}"
        exit 1
    }
    
    log "Копирую init-скрипт в ${ALLOW_INITD_DIR}..."
    cp -f "${NEED_DIR}/init.d/S99monitor" "${ALLOW_INITD_DIR}/S99monitor" 2>>"$LOG_FILE" || {
        log_error "Ошибка: не удалось скопировать init-скрипт"
        exit 1
    }
    chmod +x "${ALLOW_INITD_DIR}/S99monitor" 2>/dev/null || true
    sed -i 's/\r$//' "${ALLOW_INITD_DIR}/S99monitor" 2>/dev/null || true

    # Если S01allow установлен, используем его для запуска и проверки
    if [ -x "${INITD_DIR}/S01allow" ]; then
        log "S01allow обнаружен, запускаю компонент через S01allow..."
        if sh "${INITD_DIR}/S01allow" start >>"$LOG_FILE" 2>&1; then
            log_success "Компонент запущен через S01allow."
        else
            log_error "Ошибка: не удалось запустить компонент через S01allow."
            exit 1
        fi
        
        # Проверяем статус через S01allow
        log "Проверяю статус компонента через S01allow..."
        if sh "${INITD_DIR}/S01allow" status >>"$LOG_FILE" 2>&1; then
            log_success "Проверка статуса через S01allow успешна."
            # Отмечаем успешную установку в state.db
            state_set "$STATE_KEY_INSTALLED" "$(date '+%Y-%m-%d %H:%M:%S')"
        else
            log_error "Ошибка: проверка статуса через S01allow не прошла."
            exit 1
        fi
    else
        # Запускаем напрямую (если S01allow не установлен)
        log "Запускаю сервис..."
        if sh "${ALLOW_INITD_DIR}/S99monitor" restart >>"$LOG_FILE" 2>&1; then
            log "monitor запущен."
            # Отмечаем успешную установку в state.db
            state_set "$STATE_KEY_INSTALLED" "$(date '+%Y-%m-%d %H:%M:%S')"
        else
            log "Не удалось запустить monitor. См. лог ${LOG_FILE}"
            exit 1
        fi
    fi
    log "=== УСТАНОВКА ${COMPONENT} ЗАВЕРШЕНА ==="
}

uninstall_monitor() {
    # Создаем директорию логов перед началом деинсталляции
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT} ==="
    
    # Проверка состояния установки (если не FORCE)
    if [ "${FORCE:-0}" != "1" ]; then
        if ! state_has "$STATE_KEY_INSTALLED"; then
            log "Компонент ${COMPONENT} не установлен (файл состояния не найден), пропускаю деинсталляцию."
            return 0
        fi
    fi
    # Останавливаем и удаляем скрипт из ALLOW_INITD_DIR
    if [ -x "${ALLOW_INITD_DIR}/S99monitor" ]; then
        sh "${ALLOW_INITD_DIR}/S99monitor" stop >>"$LOG_FILE" 2>&1 || true
        rm -f "${ALLOW_INITD_DIR}/S99monitor"
    fi
    # Также проверяем старую директорию на случай миграции
    if [ -x "${INITD_DIR}/S99monitor" ]; then
        sh "${INITD_DIR}/S99monitor" stop >>"$LOG_FILE" 2>&1 || true
        rm -f "${INITD_DIR}/S99monitor"
    fi
    # Останавливаем процесс monitor через kill (без pkill)
    MONITOR_PIDS=$(ps w | grep "${APP_DIR}/app.py" | grep -v grep | awk '{print $1}')
    if [ -n "$MONITOR_PIDS" ]; then
        log "Останавливаю процессы monitor (PIDs: $MONITOR_PIDS)..."
        for PID in $MONITOR_PIDS; do
            kill "$PID" 2>/dev/null || true
        done
        sleep 1
        # Проверяем, остановились ли процессы
        REMAINING_PIDS=$(ps w | grep "${APP_DIR}/app.py" | grep -v grep | awk '{print $1}')
        if [ -n "$REMAINING_PIDS" ]; then
            log "Принудительное завершение процессов monitor (PIDs: $REMAINING_PIDS)..."
            for PID in $REMAINING_PIDS; do
                kill -9 "$PID" 2>/dev/null || true
            done
        fi
    fi
    rm -f "$PID_FILE" 2>/dev/null || true
    
    # Удаляем директории (кроме LOG_DIR, чтобы можно было записать финальное сообщение)
    if [ -d "$APP_DIR" ]; then
        log "Удаляю директорию приложения: $APP_DIR"
        rm -rf "$APP_DIR" 2>/dev/null || true
    fi
    if [ -d "$CONF_DIR" ]; then
        log "Удаляю директорию конфигурации: $CONF_DIR"
        rm -rf "$CONF_DIR" 2>/dev/null || true
    fi
    
    # Удаляем отметку состояния
    state_unset "$STATE_KEY_INSTALLED"
    
    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT} ЗАВЕРШЕНА ==="
    
    # Удаляем LOG_DIR в самом конце (после всех log вызовов)
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR" 2>/dev/null || true
    fi
}

check_monitor() {
    RUNNING=0
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        RUNNING=1
    elif ps w | grep -v grep | grep -q "${APP_DIR}/app.py"; then
        RUNNING=1
    fi
    if [ "$RUNNING" -eq 1 ]; then
        log "monitor работает."
        exit 0
    else
        log "monitor не запущен."
        exit 1
    fi
}

ACTION="$1"
case "$ACTION" in
    install) install_monitor ;;
    uninstall) uninstall_monitor ;;
    check) check_monitor ;;
    *)
        echo "Usage: $0 {install|uninstall|check}" >&2
        exit 1
        ;;
esac

