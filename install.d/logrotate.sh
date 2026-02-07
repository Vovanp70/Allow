#!/bin/sh
#
# Компонент: logrotate (простая ротация логов по размеру)
# Размещение на роутере: /opt/tmp/allow/install.d/logrotate.sh
#
# Важно:
# - Мы не используем системный logrotate (его может не быть).
# - Используем собственный скрипт /opt/etc/allow/manage.d/keenetic-entware/allow-logrotate.sh, запускаемый cron'ом.
#

set -e

COMPONENT="logrotate"
PLATFORM="${2:-entware}"

LOG_DIR="/opt/var/log/allow/${COMPONENT}"
LOG_FILE="${LOG_DIR}/${COMPONENT}.log"
STATE_KEY_INSTALLED="installed.${COMPONENT}"

TARGET_DIR="/opt/etc/allow/manage.d/keenetic-entware"
TARGET_SCRIPT="${TARGET_DIR}/allow-logrotate.sh"

# По умолчанию каждые 10 минут (ротация по размеру)
CRON_EXPR="${ALLOW_LOGROTATE_CRON_EXPR:-*/10 * * * *}"

# Диспетчеризация: logrotate.sh <component> logging <start|stop|status>
COMP_ARG="${1:-}"
SUB_ARG="${2:-}"
CMD_ARG="${3:-}"
case "$COMP_ARG" in
    dnsmasq-full|dnsmasq-family|stubby|stubby-family|sing-box)
        if [ "$SUB_ARG" = "logging" ]; then
            case "$CMD_ARG" in
                start|stop|status)
                    if [ -x "${TARGET_DIR}/allow-logging.sh" ]; then
                        exec "${TARGET_DIR}/allow-logging.sh" "$COMP_ARG" "$CMD_ARG"
                    else
                        echo "Сначала выполните: $0 install" >&2
                        exit 1
                    fi
                    ;;
            esac
        fi
        ;;
esac

# Подключаем единое хранилище состояния
LIB_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${LIB_DIR}/state_lib.sh"

mkdir -p "$LOG_DIR" "$TARGET_DIR" 2>/dev/null || true

log() {
    TS="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$TS] $*" | tee -a "$LOG_FILE"
}

log_error() {
    TS="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$TS] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

ensure_cron_spool_dirs() {
    # На Keenetic/Entware часто используется BusyBox crontab с spool:
    # /opt/var/spool/cron/crontabs
    #
    # Если директории нет — crontab падает с:
    # "can't change directory to '/opt/var/spool/cron/crontabs'"
    #
    # Создаём её заранее.
    if command -v crontab >/dev/null 2>&1; then
        mkdir -p /opt/var/spool/cron/crontabs 2>/dev/null || true
        chmod 700 /opt/var/spool/cron 2>/dev/null || true
        chmod 700 /opt/var/spool/cron/crontabs 2>/dev/null || true
        # BusyBox crontab может ругаться "can't open 'root'" пока файла нет.
        # Инициализируем пустой crontab для root.
        if [ ! -f /opt/var/spool/cron/crontabs/root ]; then
            : > /opt/var/spool/cron/crontabs/root 2>/dev/null || true
            chmod 600 /opt/var/spool/cron/crontabs/root 2>/dev/null || true
        fi
    fi
}

ensure_crond_running() {
    # Best-effort: если crond есть и не запущен — пробуем запустить.
    if command -v crond >/dev/null 2>&1; then
        if ps w 2>/dev/null | grep -q "[c]rond"; then
            return 0
        fi
        # Пытаемся запустить с каталогом пользовательских crontab'ов (типично для BusyBox)
        crond -c /opt/var/spool/cron/crontabs 2>/dev/null || crond 2>/dev/null || true
    fi
}

ensure_newline_at_eof() {
    FILE="$1"
    [ -f "$FILE" ] || return 0
    # Если файл не пуст и не заканчивается на \n — добавим \n
    LAST_CHAR="$(tail -c 1 "$FILE" 2>/dev/null || true)"
    if [ -n "$LAST_CHAR" ]; then
        printf "\n" >>"$FILE" 2>/dev/null || true
    fi
}

cron_add_entry() {
    ENTRY="${CRON_EXPR} ${TARGET_SCRIPT} >/dev/null 2>&1"

    if command -v crontab >/dev/null 2>&1; then
        ensure_cron_spool_dirs
        TMP="/tmp/allow-cron.${COMPONENT}.$$"
        TMP2="/tmp/allow-cron.${COMPONENT}.$$.new"
        # Если crontab -l падает из-за отсутствия каталога — после ensure_cron_spool_dirs должно пройти.
        crontab -l 2>/dev/null >"$TMP" || : >"$TMP"

        if grep -Fq "${TARGET_SCRIPT}" "$TMP" 2>/dev/null; then
            log "cron: запись уже существует (crontab)."
            rm -f "$TMP" "$TMP2" 2>/dev/null || true
            return 0
        fi

        ensure_newline_at_eof "$TMP"
        echo "$ENTRY" >>"$TMP"
        if crontab "$TMP" 2>>"$LOG_FILE"; then
            log "cron: запись добавлена (crontab)."
            ensure_crond_running
        else
            log_error "cron: не удалось применить crontab."
            rm -f "$TMP" "$TMP2" 2>/dev/null || true
            return 1
        fi

        rm -f "$TMP" "$TMP2" 2>/dev/null || true
        return 0
    fi

    # OpenWrt-стиль: /opt/etc/crontabs/root
    if [ -d "/opt/etc/crontabs" ]; then
        CRONFILE="/opt/etc/crontabs/root"
        touch "$CRONFILE" 2>/dev/null || true

        if grep -Fq "${TARGET_SCRIPT}" "$CRONFILE" 2>/dev/null; then
            log "cron: запись уже существует (${CRONFILE})."
            return 0
        fi

        ensure_newline_at_eof "$CRONFILE"
        echo "$ENTRY" >>"$CRONFILE"
        log "cron: запись добавлена (${CRONFILE})."
        return 0
    fi

    log_error "cron: не найден (нет crontab и /opt/etc/crontabs)."
    return 1
}

cron_remove_entry() {
    if command -v crontab >/dev/null 2>&1; then
        ensure_cron_spool_dirs
        TMP="/tmp/allow-cron.${COMPONENT}.$$"
        TMP2="/tmp/allow-cron.${COMPONENT}.$$.new"

        crontab -l 2>/dev/null >"$TMP" || : >"$TMP"

        if ! grep -Fq "${TARGET_SCRIPT}" "$TMP" 2>/dev/null; then
            log "cron: запись отсутствует (crontab), удалять нечего."
            rm -f "$TMP" "$TMP2" 2>/dev/null || true
            return 0
        fi

        grep -Fv "${TARGET_SCRIPT}" "$TMP" >"$TMP2" 2>/dev/null || : >"$TMP2"
        ensure_newline_at_eof "$TMP2"

        if crontab "$TMP2" 2>>"$LOG_FILE"; then
            log "cron: запись удалена (crontab)."
            ensure_crond_running
        else
            log_error "cron: не удалось применить crontab при удалении."
            rm -f "$TMP" "$TMP2" 2>/dev/null || true
            return 1
        fi

        rm -f "$TMP" "$TMP2" 2>/dev/null || true
        return 0
    fi

    if [ -f "/opt/etc/crontabs/root" ]; then
        CRONFILE="/opt/etc/crontabs/root"
        if ! grep -Fq "${TARGET_SCRIPT}" "$CRONFILE" 2>/dev/null; then
            log "cron: запись отсутствует (${CRONFILE}), удалять нечего."
            return 0
        fi
        TMP="/tmp/allow-cron.${COMPONENT}.$$"
        grep -Fv "${TARGET_SCRIPT}" "$CRONFILE" >"$TMP" 2>/dev/null || : >"$TMP"
        ensure_newline_at_eof "$TMP"
        cat "$TMP" >"$CRONFILE" 2>/dev/null || true
        rm -f "$TMP" 2>/dev/null || true
        log "cron: запись удалена (${CRONFILE})."
        return 0
    fi

    log "cron: не найден, удалять нечего."
    return 0
}

install_logrotate() {
    log "=== УСТАНОВКА ${COMPONENT} ==="
    log "Платформа: ${PLATFORM}"

    # Скрипт лежит в resources/allow/manage.d/keenetic-entware
    NEED_DIR="${NEED_DIR:-/opt/tmp/allow/resources/allow}"
    SRC_SCRIPT="${NEED_DIR}/manage.d/keenetic-entware/allow-logrotate.sh"
    SRC_LOGGING="${NEED_DIR}/manage.d/keenetic-entware/allow-logging.sh"
    TARGET_LOGGING="${TARGET_DIR}/allow-logging.sh"

    if [ ! -f "$SRC_SCRIPT" ]; then
        log_error "Источник скрипта не найден: $SRC_SCRIPT"
        log_error "Проверьте, что папка allow скопирована на роутер и содержит resources/allow/manage.d/keenetic-entware/allow-logrotate.sh"
        exit 1
    fi

    log "Копирую скрипт ротации в ${TARGET_SCRIPT}..."
    cp -f "$SRC_SCRIPT" "$TARGET_SCRIPT" 2>>"$LOG_FILE" || {
        log_error "Не удалось скопировать: $SRC_SCRIPT -> $TARGET_SCRIPT"
        exit 1
    }
    chmod +x "$TARGET_SCRIPT" 2>/dev/null || true
    sed -i 's/\r$//' "$TARGET_SCRIPT" 2>/dev/null || true

    if [ -f "$SRC_LOGGING" ]; then
        log "Копирую скрипт управления логированием в ${TARGET_LOGGING}..."
        cp -f "$SRC_LOGGING" "$TARGET_LOGGING" 2>>"$LOG_FILE" || {
            log_error "Не удалось скопировать: $SRC_LOGGING -> $TARGET_LOGGING"
            exit 1
        }
        chmod +x "$TARGET_LOGGING" 2>/dev/null || true
        sed -i 's/\r$//' "$TARGET_LOGGING" 2>/dev/null || true
    fi

    log "Добавляю cron-задачу: ${CRON_EXPR} ..."
    cron_add_entry || {
        log_error "Установка завершилась частично: скрипт установлен, но cron не настроен."
        exit 1
    }

    state_set "$STATE_KEY_INSTALLED" "$(date '+%Y-%m-%d %H:%M:%S')"
    log "=== УСТАНОВКА ${COMPONENT}: OK ==="
}

uninstall_logrotate() {
    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT} ==="

    if [ "${FORCE:-0}" != "1" ] && ! state_has "$STATE_KEY_INSTALLED"; then
        log "Компонент ${COMPONENT} не установлен (файл состояния не найден), пропускаю."
        return 0
    fi

    cron_remove_entry || true

    if [ -f "$TARGET_SCRIPT" ]; then
        log "Удаляю скрипт: $TARGET_SCRIPT"
        rm -f "$TARGET_SCRIPT" 2>/dev/null || true
    fi

    if [ -f "${TARGET_DIR}/allow-logging.sh" ]; then
        log "Удаляю скрипт управления логированием: ${TARGET_DIR}/allow-logging.sh"
        rm -f "${TARGET_DIR}/allow-logging.sh" 2>/dev/null || true
    fi

    # Если директория /opt/etc/allow/bin пуста — удаляем её
    if [ -d "$TARGET_DIR" ]; then
        if [ -z "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]; then
            rmdir "$TARGET_DIR" 2>/dev/null || true
        fi
    fi

    state_unset "$STATE_KEY_INSTALLED"

    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT}: OK ==="

    # Удаляем логи в самом конце
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR" 2>/dev/null || true
    fi
}

check_logrotate() {
    log "=== ПРОВЕРКА ${COMPONENT} ==="

    OK=1
    if [ -x "$TARGET_SCRIPT" ]; then
        log "Скрипт установлен: $TARGET_SCRIPT"
    else
        log_error "Скрипт не найден или не исполняемый: $TARGET_SCRIPT"
        OK=0
    fi

    # Проверяем наличие cron записи (best-effort)
    if command -v crontab >/dev/null 2>&1; then
        ensure_cron_spool_dirs
        if crontab -l 2>/dev/null | grep -Fq "$TARGET_SCRIPT"; then
            log "cron: запись присутствует (crontab)."
        else
            log_error "cron: запись не найдена (crontab)."
            OK=0
        fi
    elif [ -f "/opt/etc/crontabs/root" ]; then
        if grep -Fq "$TARGET_SCRIPT" "/opt/etc/crontabs/root" 2>/dev/null; then
            log "cron: запись присутствует (/opt/etc/crontabs/root)."
        else
            log_error "cron: запись не найдена (/opt/etc/crontabs/root)."
            OK=0
        fi
    else
        log "cron: не удалось проверить (crontab не найден)."
    fi

    if [ "$OK" -eq 1 ]; then
        log "=== ПРОВЕРКА ${COMPONENT}: OK ==="
        exit 0
    fi

    log_error "=== ПРОВЕРКА ${COMPONENT}: НЕИСПРАВНО ==="
    exit 1
}

ACTION="$1"
case "$ACTION" in
    install) install_logrotate ;;
    uninstall) uninstall_logrotate ;;
    check) check_logrotate ;;
    *)
        echo "Usage: $0 {install|uninstall|check} [entware]" >&2
        exit 1
        ;;
esac

