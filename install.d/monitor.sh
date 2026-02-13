#!/bin/sh

# Управление компонентом monitor (lighttpd + CGI, без Flask)
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

ensure_deps() {
    detect_opkg
    # Без Python: только lighttpd для CGI
    if ! command -v lighttpd >/dev/null 2>&1 && ! [ -x /usr/sbin/lighttpd ]; then
        log "Предупреждение: lighttpd не найден. Установите lighttpd для работы монитора."
        if ! "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^lighttpd "; then
            log "Пытаюсь установить lighttpd..."
            "$OPKG_BIN" update >>"$LOG_FILE" 2>&1 || true
            "$OPKG_BIN" install lighttpd >>"$LOG_FILE" 2>&1 || true
        fi
    fi
    # mod_cgi нужен для api.cgi; на Keenetic системный lighttpd без модулей — используем из Entware
    if ! "$OPKG_BIN" list-installed 2>/dev/null | grep -q "lighttpd-mod-cgi"; then
        log "Устанавливаю lighttpd-mod-cgi для CGI..."
        "$OPKG_BIN" update >>"$LOG_FILE" 2>&1 || true
        "$OPKG_BIN" install lighttpd-mod-cgi >>"$LOG_FILE" 2>&1 || true
    fi
    # mod_rewrite нужен для /api/* -> cgi-bin/api.cgi с PATH_INFO
    if ! "$OPKG_BIN" list-installed 2>/dev/null | grep -q "lighttpd-mod-rewrite"; then
        log "Устанавливаю lighttpd-mod-rewrite для /api/* rewrite..."
        "$OPKG_BIN" update >>"$LOG_FILE" 2>&1 || true
        "$OPKG_BIN" install lighttpd-mod-rewrite >>"$LOG_FILE" 2>&1 || true
    fi
    # jq нужен для редактора конфигов (config.cgi)
    if ! command -v jq >/dev/null 2>&1 && ! "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^jq "; then
        log "Устанавливаю jq для редактора конфигов..."
        "$OPKG_BIN" update >>"$LOG_FILE" 2>&1 || true
        "$OPKG_BIN" install jq >>"$LOG_FILE" 2>&1 || true
    fi
    # Python 3 нужен для авторизации (auth_helper.py)
    if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
        if ! "$OPKG_BIN" list-installed 2>/dev/null | grep -qE "^python3? "; then
            log "Устанавливаю python3 для авторизации монитора..."
            "$OPKG_BIN" update >>"$LOG_FILE" 2>&1 || true
            "$OPKG_BIN" install python3 >>"$LOG_FILE" 2>&1 || true
        fi
    fi
}

install_monitor() {
    log "=== УСТАНОВКА ${COMPONENT} ==="
    ensure_deps

    log "Копирую приложение в ${APP_DIR}..."
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR" "$APP_DIR/cgi-bin"
    # lighttpd.conf и cgi-bin (api.cgi + config.cgi для редактора конфигов)
    [ -f "${NEED_DIR}/etc/monitor/lighttpd.conf" ] && cp -f "${NEED_DIR}/etc/monitor/lighttpd.conf" "$APP_DIR/"
    [ -f "${NEED_DIR}/etc/monitor/cgi-bin/api.cgi" ] && cp -f "${NEED_DIR}/etc/monitor/cgi-bin/api.cgi" "$APP_DIR/cgi-bin/"
    [ -f "${NEED_DIR}/etc/monitor/cgi-bin/config.cgi" ] && cp -f "${NEED_DIR}/etc/monitor/cgi-bin/config.cgi" "$APP_DIR/cgi-bin/"
    [ -f "${NEED_DIR}/etc/monitor/auth_helper.py" ] && cp -f "${NEED_DIR}/etc/monitor/auth_helper.py" "$APP_DIR/"
    # Статика (HTML + static/) из static_htdocs
    if [ -d "${NEED_DIR}/static_htdocs" ]; then
        cp -R "${NEED_DIR}/static_htdocs/"* "$APP_DIR/"
    fi
    chmod +x "$APP_DIR/cgi-bin/api.cgi" 2>/dev/null || true
    chmod +x "$APP_DIR/cgi-bin/config.cgi" 2>/dev/null || true
    chmod +x "$APP_DIR/auth_helper.py" 2>/dev/null || true
    [ -f "$APP_DIR/cgi-bin/api.cgi" ] && sed -i 's/\r$//' "$APP_DIR/cgi-bin/api.cgi" 2>/dev/null || true
    [ -f "$APP_DIR/cgi-bin/config.cgi" ] && sed -i 's/\r$//' "$APP_DIR/cgi-bin/config.cgi" 2>/dev/null || true
    [ -f "$APP_DIR/auth_helper.py" ] && sed -i 's/\r$//' "$APP_DIR/auth_helper.py" 2>/dev/null || true
    # manage.d скрипты (system-info.sh, stubby.sh, dns-mode.sh) для api.cgi
    MANAGED_SRC="${NEED_DIR}/../allow/manage.d"
    if [ -d "$MANAGED_SRC" ]; then
        mkdir -p "/opt/etc/allow"
        cp -R "$MANAGED_SRC" "/opt/etc/allow/" 2>/dev/null || true
        for f in /opt/etc/allow/manage.d/keenetic-entware/*.sh; do
            [ -f "$f" ] && chmod +x "$f" 2>/dev/null || true
        done
    fi

    # Создаем директорию для скриптов компонентов
    mkdir -p "$ALLOW_INITD_DIR" 2>/dev/null || {
        log_error "Ошибка: не удалось создать директорию ${ALLOW_INITD_DIR}"
        exit 1
    }
    
    log "Копирую init-скрипт в ${ALLOW_INITD_DIR}..."
    cp -f "${NEED_DIR}/init.d/X99monitor" "${ALLOW_INITD_DIR}/X99monitor" 2>>"$LOG_FILE" || {
        log_error "Ошибка: не удалось скопировать init-скрипт X99monitor"
        exit 1
    }
    chmod +x "${ALLOW_INITD_DIR}/X99monitor" 2>/dev/null || true
    sed -i 's/\r$//' "${ALLOW_INITD_DIR}/X99monitor" 2>/dev/null || true

    # Активируем компонент (X -> S), чтобы S01allow его подхватил
    if [ -x "/opt/etc/allow/manage.d/keenetic-entware/autostart.sh" ]; then
        log "Активирую компонент через autostart.sh..."
        /opt/etc/allow/manage.d/keenetic-entware/autostart.sh monitor activate >>"$LOG_FILE" 2>&1 || true
    fi

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
        MONITOR_SCRIPT="${ALLOW_INITD_DIR}/S99monitor"
        [ -f "$MONITOR_SCRIPT" ] || MONITOR_SCRIPT="${ALLOW_INITD_DIR}/X99monitor"
        if sh "$MONITOR_SCRIPT" restart >>"$LOG_FILE" 2>&1; then
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
    # Останавливаем и удаляем скрипт из ALLOW_INITD_DIR (S и X)
    for m in "${ALLOW_INITD_DIR}/S99monitor" "${ALLOW_INITD_DIR}/X99monitor"; do
        if [ -x "$m" ]; then
            sh "$m" stop >>"$LOG_FILE" 2>&1 || true
            rm -f "$m"
        fi
    done
    # Также проверяем старую директорию на случай миграции
    for m in "${INITD_DIR}/S99monitor" "${INITD_DIR}/X99monitor"; do
        if [ -x "$m" ]; then
            sh "$m" stop >>"$LOG_FILE" 2>&1 || true
            rm -f "$m"
        fi
    done
    # Останавливаем lighttpd по PIDFILE
    if [ -f "$PID_FILE" ]; then
        MPID=$(cat "$PID_FILE")
        [ -n "$MPID" ] && kill "$MPID" 2>/dev/null || true
        sleep 1
        [ -n "$MPID" ] && kill -9 "$MPID" 2>/dev/null || true
    fi
    # На всякий случай убиваем lighttpd с нашим конфигом
    ps w | grep "lighttpd.*allow/monitor" | grep -v grep | awk '{print $1}' | xargs kill -9 2>/dev/null || true
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
    elif ps w | grep -v grep | grep -q "lighttpd.*allow/monitor"; then
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

