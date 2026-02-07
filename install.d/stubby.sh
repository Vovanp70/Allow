#!/bin/sh

# Подскрипт для управления компонентом stubby
# Должен располагаться на роутере как /opt/tmp/allow/install.d/stubby.sh

set -e

COMPONENT="stubby"
PLATFORM="${2:-entware}"
INSTANCE="${INSTANCE:-main}"

apply_instance_settings() {
    # Важно: ACTION может менять INSTANCE (install-family/uninstall-family).
    # Поэтому все переменные экземпляра должны пересчитываться каждый раз после смены INSTANCE.
    if [ "$INSTANCE" = "family" ]; then
        COMPONENT_SUFFIX="-family"
        DEFAULT_PORT="41501"
        CONFIG_FILE="stubby-family.yml"
        INIT_SCRIPT_PATTERN="[SX]*stubby-family"
    else
        COMPONENT_SUFFIX=""
        DEFAULT_PORT="41500"
        CONFIG_FILE="stubby.yml"
        INIT_SCRIPT_PATTERN="[SX]*stubby"
    fi
    # Для удаления: убираем S* и X* (без семейного суффикса в имени основного скрипта)
    if [ "$INSTANCE" = "family" ]; then
        INIT_SCRIPT_NAMES="S97stubby-family X97stubby-family"
    else
        INIT_SCRIPT_NAMES="S97stubby X97stubby"
    fi
}

# Первичная инициализация переменных экземпляра (будут пересчитаны внизу перед выполнением ACTION)
apply_instance_settings

CONF_DIR="/opt/etc/allow/${COMPONENT}"
LOG_DIR="/opt/var/log/allow/${COMPONENT}"
INITD_DIR="/opt/etc/init.d"
ALLOW_INITD_DIR="/opt/etc/allow/init.d"
# NEED_DIR может быть передан через переменную окружения, иначе используем значение по умолчанию
NEED_DIR="${NEED_DIR:-/opt/tmp/allow/resources/${COMPONENT}}"

# Подключаем единое хранилище состояния
LIB_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${LIB_DIR}/state_lib.sh"

# Порт по умолчанию (будет проверен и изменен при необходимости)
STUBBY_PORT="${STUBBY_PORT:-$DEFAULT_PORT}"

mkdir -p "$CONF_DIR" "$LOG_DIR"

LOG_FILE="${LOG_DIR}/${COMPONENT}.log"

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

# Проверка, является ли терминал интерактивным
is_interactive() {
    [ -t 0 ] && [ -t 1 ]
}

# Запрос пользователя при ошибке установки
ask_user_on_error() {
    local ERROR_MSG="$1"
    local COMPONENT_NAME="$2"
    
    log_error "$ERROR_MSG"
    
    if is_interactive; then
        echo ""
        echo "Ошибка установки компонента: $COMPONENT_NAME"
        echo "Что вы хотите сделать?"
        echo "  1) Откатить установку этого компонента (uninstall)"
        echo "  2) Продолжить установку (оставить частично установленный компонент)"
        echo ""
        while true; do
            printf "Ваш выбор [1/2]: "
            read -r choice
            case "$choice" in
                1|uninstall|откат|rollback)
                    return 1  # Вызывающий код должен выполнить uninstall
                    ;;
                2|continue|продолжить)
                    return 0  # Продолжить без деинсталляции
                    ;;
                *)
                    echo "Неверный выбор. Введите 1 или 2."
                    ;;
            esac
        done
    else
        # Неинтерактивный режим: продолжаем установку
        log "Неинтерактивный режим: продолжаю установку, пропуская проблемный компонент."
        return 0
    fi
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

check_port_in_use() {
    CHECK_PORT="$1"
    if [ -z "$CHECK_PORT" ]; then
        return 1
    fi
    if command -v netstat >/dev/null 2>&1; then
        # Проверяем порт более надежно: ищем ":PORT" в колонке Local Address
        # Формат netstat: "tcp  0  0  0.0.0.0:5300  0.0.0.0:*  LISTEN  12345/dnsmasq"
        # Используем простой grep с точным паттерном
        if netstat -tulnp 2>/dev/null | grep -E ":[[:space:]]*${CHECK_PORT}[[:space:]]" >/dev/null 2>&1; then
            return 0
        fi
        # Альтернативная проверка: ищем ":PORT" в любой части строки (на случай другого формата)
        if netstat -tulnp 2>/dev/null | grep -E ":${CHECK_PORT}[[:space:]]" >/dev/null 2>&1; then
            return 0
        fi
        # Еще одна проверка: через awk извлекаем порт из 4-й колонки
        if netstat -tulnp 2>/dev/null | awk '{print $4}' | grep -qE ":${CHECK_PORT}$"; then
            return 0
        fi
        return 1
    else
        log "Предупреждение: netstat не найден, пропускаю проверку порта ${CHECK_PORT}."
        return 1
    fi
}

find_free_port() {
    START_PORT="$1"
    CHECK_PORT="$START_PORT"
    
    # Отладочный вывод для проверки
    if check_port_in_use "$CHECK_PORT"; then
        log "Порт ${CHECK_PORT} занят (проверено через netstat), пробуем следующий..."
        CHECK_PORT=$((CHECK_PORT + 1))
    fi
    
    while check_port_in_use "$CHECK_PORT"; do
        log "Порт ${CHECK_PORT} занят, пробуем следующий..."
        CHECK_PORT=$((CHECK_PORT + 1))
        # Защита от бесконечного цикла
        if [ "$CHECK_PORT" -gt $((START_PORT + 100)) ]; then
            log_error "Ошибка: не удалось найти свободный порт в диапазоне ${START_PORT}-$((START_PORT + 100))"
            exit 1
        fi
    done
    
    echo "$CHECK_PORT"
}

find_init_script_path() {
    # Returns first matching init script path (prefer /opt/etc/allow/init.d, fallback /opt/etc/init.d)
    SCRIPT_PATH=""
    for s in "$ALLOW_INITD_DIR"/$INIT_SCRIPT_PATTERN; do
        if [ -f "$s" ]; then
            SCRIPT_PATH="$s"
            break
        fi
    done
    if [ -z "$SCRIPT_PATH" ]; then
        for s in "$INITD_DIR"/$INIT_SCRIPT_PATTERN; do
            if [ -f "$s" ]; then
                SCRIPT_PATH="$s"
                break
            fi
        done
    fi
    if [ -n "$SCRIPT_PATH" ]; then
        echo "$SCRIPT_PATH"
        return 0
    fi
    return 1
}

read_init_status_kv() {
    # Reads: STATUS/CONFIG_PORT/ACTIVE_PORT/EFFECTIVE_PORT/MISMATCH from init script `status --kv`
    # Sets globals:
    #   KV_STATUS KV_CONFIG_PORT KV_ACTIVE_PORT KV_EFFECTIVE_PORT KV_MISMATCH KV_RAW
    script="$1"
    KV_RAW="$(sh "$script" status --kv 2>/dev/null || true)"

    kv_get() {
        echo "$KV_RAW" | awk -F= -v k="$1" '$1==k {print $2; exit}' 2>/dev/null | tr -d '\r\n'
    }

    KV_STATUS="$(kv_get STATUS)"
    KV_MISMATCH="$(kv_get MISMATCH | tr 'A-Z' 'a-z')"
    KV_CONFIG_PORT="$(kv_get CONFIG_PORT | tr -cd '0-9')"
    KV_ACTIVE_PORT="$(kv_get ACTIVE_PORT | tr -cd '0-9')"
    KV_EFFECTIVE_PORT="$(kv_get EFFECTIVE_PORT | tr -cd '0-9')"

    # Fallbacks
    [ -n "${KV_STATUS:-}" ] || KV_STATUS="notrunning"
    [ -n "${KV_MISMATCH:-}" ] || KV_MISMATCH="no"
    [ -n "${KV_CONFIG_PORT:-}" ] || KV_CONFIG_PORT="$DEFAULT_PORT"
    if [ -z "${KV_EFFECTIVE_PORT:-}" ]; then
        if [ "$KV_STATUS" = "running" ] && [ -n "${KV_ACTIVE_PORT:-}" ]; then
            KV_EFFECTIVE_PORT="$KV_ACTIVE_PORT"
        else
            KV_EFFECTIVE_PORT="$KV_CONFIG_PORT"
        fi
    fi
}

stop_stubby() {
    SCRIPT_PATH=""
    # Сначала ищем в новой директории
    for s in "$ALLOW_INITD_DIR"/$INIT_SCRIPT_PATTERN; do
        if [ -f "$s" ]; then
            SCRIPT_PATH="$s"
            break
        fi
    done
    # Если не найден, проверяем старую директорию (для миграции)
    if [ -z "$SCRIPT_PATH" ]; then
        for s in "$INITD_DIR"/$INIT_SCRIPT_PATTERN; do
            if [ -f "$s" ]; then
                SCRIPT_PATH="$s"
                break
            fi
        done
    fi

    if [ -n "$SCRIPT_PATH" ]; then
        log "Останавливаю stubby${COMPONENT_SUFFIX} через ${SCRIPT_PATH}."
        if sh "$SCRIPT_PATH" stop >>"$LOG_FILE" 2>&1; then
            log "stubby${COMPONENT_SUFFIX} остановлен."
        else
            log "Предупреждение: не удалось корректно остановить stubby${COMPONENT_SUFFIX}."
        fi
    else
        log "Init-скрипт для остановки stubby${COMPONENT_SUFFIX} не найден, пропускаю остановку."
    fi
}

start_stubby() {
    SCRIPT_PATH=""
    # Сначала ищем в новой директории
    for s in "$ALLOW_INITD_DIR"/$INIT_SCRIPT_PATTERN; do
        if [ -f "$s" ]; then
            SCRIPT_PATH="$s"
            break
        fi
    done
    # Если не найден, проверяем старую директорию (для миграции)
    if [ -z "$SCRIPT_PATH" ]; then
        for s in "$INITD_DIR"/$INIT_SCRIPT_PATTERN; do
            if [ -f "$s" ]; then
                SCRIPT_PATH="$s"
                break
            fi
        done
    fi

    if [ -z "$SCRIPT_PATH" ]; then
        log_error "Ошибка: init-скрипт stubby${COMPONENT_SUFFIX} не найден в ${ALLOW_INITD_DIR} или ${INITD_DIR}."
        return 1
    fi

    log "Запускаю stubby${COMPONENT_SUFFIX} через ${SCRIPT_PATH}."
    STUBBY_PORT="$STUBBY_PORT" sh "$SCRIPT_PATH" start >>"$LOG_FILE" 2>&1 || {
        log_error "Ошибка: не удалось запустить stubby${COMPONENT_SUFFIX} через init-скрипт."
        return 1
    }
    log "stubby${COMPONENT_SUFFIX} запущен (инициализация init-скрипта успешна)."
    return 0
}

apply_stubby_service() {
    # Apply config changes to running service:
    # - if running+MISMATCH=yes -> restart
    # - if not running -> start
    # - else -> no-op
    SCRIPT_PATH="$(find_init_script_path 2>/dev/null || true)"
    if [ -z "${SCRIPT_PATH:-}" ]; then
        log_error "Ошибка: init-скрипт stubby${COMPONENT_SUFFIX} не найден в ${ALLOW_INITD_DIR} или ${INITD_DIR}."
        return 1
    fi

    read_init_status_kv "$SCRIPT_PATH"
    log "Статус init (до): STATUS=${KV_STATUS}, CONFIG_PORT=${KV_CONFIG_PORT}, ACTIVE_PORT=${KV_ACTIVE_PORT}, EFFECTIVE_PORT=${KV_EFFECTIVE_PORT}, MISMATCH=${KV_MISMATCH}"

    if [ "$KV_STATUS" = "running" ] && [ "$KV_MISMATCH" = "yes" ]; then
        log "Обнаружен MISMATCH — выполняю restart stubby${COMPONENT_SUFFIX}."
        if sh "$SCRIPT_PATH" restart >>"$LOG_FILE" 2>&1; then
            log "restart выполнен."
        else
            log_error "Ошибка: restart stubby${COMPONENT_SUFFIX} завершился с ошибкой."
            return 1
        fi
    elif [ "$KV_STATUS" != "running" ]; then
        log "stubby${COMPONENT_SUFFIX} не запущен — выполняю start."
        STUBBY_PORT="$STUBBY_PORT" sh "$SCRIPT_PATH" start >>"$LOG_FILE" 2>&1 || {
            log_error "Ошибка: не удалось запустить stubby${COMPONENT_SUFFIX} через init-скрипт."
            return 1
        }
        log "start выполнен."
    else
        log "stubby${COMPONENT_SUFFIX} уже запущен и соответствует конфигу — restart не требуется."
    fi

    # Refresh KV after start/restart
    read_init_status_kv "$SCRIPT_PATH"
    log "Статус init (после): STATUS=${KV_STATUS}, CONFIG_PORT=${KV_CONFIG_PORT}, ACTIVE_PORT=${KV_ACTIVE_PORT}, EFFECTIVE_PORT=${KV_EFFECTIVE_PORT}, MISMATCH=${KV_MISMATCH}"

    # Normalize: downstream components should use effective port
    if [ -n "${KV_EFFECTIVE_PORT:-}" ]; then
        STUBBY_PORT="$KV_EFFECTIVE_PORT"
        export STUBBY_PORT
    fi
    return 0
}

install_stubby() {
    log "=== УСТАНОВКА ${COMPONENT}${COMPONENT_SUFFIX} ==="
    log "Платформа: ${PLATFORM}"
    log "Экземпляр: ${INSTANCE}"

    detect_opkg_local
    log "Использую opkg: ${OPKG_BIN}"

    # Всегда используем stubby из opkg (актуальная версия, напр. 0.4.3-2).
    # Системный /usr/sbin/stubby (часто 0.4.0) не используем — обрезан и старая версия.
    PKG_NAME="stubby"
    if "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^${PKG_NAME} "; then
        log "Пакет ${PKG_NAME} уже установлен, пропускаю установку пакета."
    else
        log "Обновляю список пакетов opkg..."
        if "$OPKG_BIN" update >>"$LOG_FILE" 2>&1; then
            log "Список пакетов обновлен."
        else
            log "Предупреждение: не удалось обновить список пакетов (продолжаем установку)."
        fi
        log "Устанавливаю пакет ${PKG_NAME} (opkg)..."
        if "$OPKG_BIN" install "${PKG_NAME}" >>"$LOG_FILE" 2>&1; then
            log_success "Пакет ${PKG_NAME} успешно установлен."
        else
            log_error "Ошибка: не удалось установить пакет ${PKG_NAME}."
            exit 1
        fi
    fi

    # Проверяем, не запущен ли уже системный stubby (может быть на другом порту)
    # НЕ останавливаем его автоматически - пользователь должен сделать это вручную
    SYSTEM_STUBBY_PID=$(pgrep -f "stubby.*dotproxy" | head -1)
    if [ -n "$SYSTEM_STUBBY_PID" ] && kill -0 "$SYSTEM_STUBBY_PID" 2>/dev/null; then
        log "Предупреждение: обнаружен запущенный системный stubby (PID: $SYSTEM_STUBBY_PID)."
        log "Системный stubby НЕ будет остановлен автоматически."
        log "После установки всех компонентов остановите его вручную через CLI роутера."
    fi

    # Проверяем и выбираем свободный порт
    log "Проверяю доступность порта ${DEFAULT_PORT}..."
    # Отладочный вывод: показываем, что видит netstat
    if command -v netstat >/dev/null 2>&1; then
        NETSTAT_OUTPUT=$(netstat -tulnp 2>/dev/null | grep -E ":${DEFAULT_PORT}[[:space:]]" | head -3)
        if [ -n "$NETSTAT_OUTPUT" ]; then
            log "Отладка: netstat показывает следующие строки для порта ${DEFAULT_PORT}:"
            echo "$NETSTAT_OUTPUT" | while read line; do
                log "  $line"
            done
        fi
    fi
    STUBBY_PORT=$(find_free_port "$DEFAULT_PORT" 2>>"$LOG_FILE" | grep -Eo '^[0-9]+$' | tail -n1)
    if [ "$STUBBY_PORT" != "$DEFAULT_PORT" ]; then
        log "Порт ${DEFAULT_PORT} занят, использую порт ${STUBBY_PORT}."
    else
        log "Порт ${STUBBY_PORT} свободен."
    fi

    # Обновляем конфиг stubby с выбранным портом
    if [ -d "${NEED_DIR}/etc" ]; then
        log "Копирую конфиги из ${NEED_DIR}/etc в ${CONF_DIR}."
        cp -f "${NEED_DIR}/etc/"* "$CONF_DIR"/ 2>>"$LOG_FILE" || {
            log_error "Ошибка: не удалось скопировать конфиги."
            exit 1
        }

        # Обновляем порт в конфиге
        if [ -f "${CONF_DIR}/${CONFIG_FILE}" ]; then
            log "Обновляю порт в конфиге stubby${COMPONENT_SUFFIX} на ${STUBBY_PORT}."
            sed -i "s/@[0-9]*/@${STUBBY_PORT}/g" "${CONF_DIR}/${CONFIG_FILE}" 2>/dev/null || {
                log "Предупреждение: не удалось обновить порт в конфиге (возможно, уже правильный)."
            }
        fi
    else
        log_error "Ошибка: директория ${NEED_DIR}/etc не найдена, конфиги не будут скопированы."
        exit 1
    fi

    if [ -d "${NEED_DIR}/init.d" ]; then
        # Создаем директорию для скриптов компонентов
        mkdir -p "$ALLOW_INITD_DIR" 2>/dev/null || {
            log_error "Ошибка: не удалось создать директорию ${ALLOW_INITD_DIR}"
            exit 1
        }
        
        log "Копирую init-скрипты из ${NEED_DIR}/init.d в ${ALLOW_INITD_DIR}."
        # Копируем как X* (неактивные); активация через autostart.sh
        if [ "$INSTANCE" = "family" ]; then
            if [ -f "${NEED_DIR}/init.d/X97stubby-family" ]; then
                cp -f "${NEED_DIR}/init.d/X97stubby-family" "$ALLOW_INITD_DIR"/ 2>>"$LOG_FILE" || {
                    log_error "Ошибка: не удалось скопировать init-скрипт X97stubby-family."
                    exit 1
                }
                chmod +x "${ALLOW_INITD_DIR}/X97stubby-family" 2>/dev/null || true
                sed -i 's/\r$//' "${ALLOW_INITD_DIR}/X97stubby-family" 2>/dev/null || true
            else
                log_error "Ошибка: init-скрипт X97stubby-family не найден в ${NEED_DIR}/init.d/"
                exit 1
            fi
        else
            cp -f "${NEED_DIR}/init.d/"* "$ALLOW_INITD_DIR"/ 2>>"$LOG_FILE" || {
                log_error "Ошибка: не удалось скопировать init-скрипты."
                exit 1
            }
            chmod +x "${ALLOW_INITD_DIR}"/X*"$COMPONENT"* 2>/dev/null || true
            # Нормализуем окончания строк (CRLF -> LF)
            for s in "${ALLOW_INITD_DIR}"/X*"$COMPONENT"*; do
                if [ -f "$s" ]; then
                    sed -i 's/\r$//' "$s" 2>/dev/null || true
                fi
            done
        fi
        # Активируем компонент (X -> S)
        if [ -x "/opt/etc/allow/manage.d/keenetic-entware/autostart.sh" ]; then
            if [ "$INSTANCE" = "family" ]; then
                /opt/etc/allow/manage.d/keenetic-entware/autostart.sh stubby-family activate >>"$LOG_FILE" 2>&1 || true
            else
                /opt/etc/allow/manage.d/keenetic-entware/autostart.sh stubby activate >>"$LOG_FILE" 2>&1 || true
            fi
        fi
    else
        log_error "Ошибка: директория ${NEED_DIR}/init.d не найдена, init-скрипты не будут скопированы."
        exit 1
    fi

    # Сохраняем порт stubby в глобальную переменную для других компонентов
    export STUBBY_PORT

    # Применяем конфиг к сервису (start/restart при необходимости) и выравниваем STUBBY_PORT до EFFECTIVE_PORT
    if ! apply_stubby_service; then
        if ! ask_user_on_error "Ошибка: запуск/применение stubby не удалось." "${COMPONENT}${COMPONENT_SUFFIX}"; then
            log "Пользователь выбрал откат установки."
            uninstall_stubby
            return 1
        else
            log "Пользователь выбрал продолжить установку."
            return 1
        fi
    fi

    # Если S01allow установлен — запустим весь стек (stubby уже приведён в корректное состояние выше)
    if [ -x "${INITD_DIR}/S01allow" ]; then
        log "S01allow обнаружен, запускаю компоненты через S01allow..."
        if sh "${INITD_DIR}/S01allow" start >>"$LOG_FILE" 2>&1; then
            log_success "Компоненты запущены через S01allow."
        else
            if ! ask_user_on_error "Ошибка: не удалось запустить компоненты через S01allow." "${COMPONENT}${COMPONENT_SUFFIX}"; then
                log "Пользователь выбрал откат установки."
                uninstall_stubby
                return 1
            else
                log "Пользователь выбрал продолжить установку."
                return 1
            fi
        fi
        log "Проверяю статус компонентов через S01allow..."
        sh "${INITD_DIR}/S01allow" status >>"$LOG_FILE" 2>&1 || true
    fi

    # Проверяем, слушает ли фактический порт (EFFECTIVE_PORT, сохранённый в STUBBY_PORT)
    PORT_CHECK_OK=0
    for i in 1 2 3 4 5; do
        if check_port_in_use "$STUBBY_PORT"; then
            PORT_CHECK_OK=1
            break
        fi
        if [ "$i" -lt 5 ]; then
            log "Попытка ${i}/5: порт ${STUBBY_PORT} еще не слушается, жду 1 секунду..."
            sleep 1
        fi
    done

    if [ "$PORT_CHECK_OK" -eq 1 ]; then
        log_success "Проверка порта: сервис слушает порт ${STUBBY_PORT}."
    else
        if ! ask_user_on_error "Ошибка: после запуска сервис НЕ слушает порт ${STUBBY_PORT}." "${COMPONENT}${COMPONENT_SUFFIX}"; then
            log "Пользователь выбрал откат установки."
            uninstall_stubby
            return 1
        else
            log "Пользователь выбрал продолжить установку."
            return 1
        fi
    fi

    # Проверяем процесс
    if ps w | grep "[s]tubby" >/dev/null 2>&1; then
        log_success "Процесс stubby найден, установка успешна."
    else
        if ! ask_user_on_error "Ошибка: процесс stubby не найден после установки." "${COMPONENT}${COMPONENT_SUFFIX}"; then
            log "Пользователь выбрал откат установки."
            uninstall_stubby
            return 1
        else
            log "Пользователь выбрал продолжить установку."
            return 1
        fi
    fi

    # Отмечаем успешную установку в state.db
    state_set "installed.${COMPONENT}${COMPONENT_SUFFIX}" "$(date '+%Y-%m-%d %H:%M:%S')"

    log_success "=== УСТАНОВКА ${COMPONENT}${COMPONENT_SUFFIX} ЗАВЕРШЕНА УСПЕШНО ==="
    log "Порт stubby${COMPONENT_SUFFIX}: ${STUBBY_PORT}"
    
    # Автоматически устанавливаем семейный экземпляр после успешной установки основного
    if [ "$INSTANCE" != "family" ]; then
        log ""
        log "================================================================"
        log "  Установка семейного экземпляра stubby-family"
        log "================================================================"
        log ""
        
        # Сохраняем текущие значения переменных
        OLD_INSTANCE="$INSTANCE"
        OLD_COMPONENT_SUFFIX="$COMPONENT_SUFFIX"
        OLD_DEFAULT_PORT="$DEFAULT_PORT"
        OLD_CONFIG_FILE="$CONFIG_FILE"
        OLD_INIT_SCRIPT_PATTERN="$INIT_SCRIPT_PATTERN"
        
        # Устанавливаем параметры для семейного экземпляра
        INSTANCE="family"
        COMPONENT_SUFFIX="-family"
        DEFAULT_PORT="41501"
        CONFIG_FILE="stubby-family.yml"
        INIT_SCRIPT_PATTERN="[SX]*stubby-family"
        
        # Вызываем установку семейного экземпляра
        if install_stubby; then
            log_success "Семейный экземпляр stubby-family установлен успешно."
        else
            log "Предупреждение: установка семейного экземпляра stubby-family завершилась с ошибкой (основной экземпляр установлен)."
        fi
        
        # Восстанавливаем значения переменных
        INSTANCE="$OLD_INSTANCE"
        COMPONENT_SUFFIX="$OLD_COMPONENT_SUFFIX"
        DEFAULT_PORT="$OLD_DEFAULT_PORT"
        CONFIG_FILE="$OLD_CONFIG_FILE"
        INIT_SCRIPT_PATTERN="$OLD_INIT_SCRIPT_PATTERN"
        
        log ""
        log "================================================================"
        log ""
    fi
}

check_stubby() {
    log "=== ПРОВЕРКА ${COMPONENT}${COMPONENT_SUFFIX} ==="

    # Определяем порт из текущего конфига (источник истины)
    if [ -f "${CONF_DIR}/${CONFIG_FILE}" ]; then
        CONF_PORT="$(grep -E "^[[:space:]]*-[[:space:]]*127\.0\.0\.1@[0-9]+" "${CONF_DIR}/${CONFIG_FILE}" 2>/dev/null | head -1 | sed 's/.*@\([0-9][0-9]*\).*/\1/' | tr -cd '0-9')"
        if [ -n "${CONF_PORT:-}" ]; then
            STUBBY_PORT="$CONF_PORT"
        fi
    fi

    if check_port_in_use "$STUBBY_PORT"; then
        log "Порт ${STUBBY_PORT} занят (ожидаемо, если сервис запущен)."
    else
        log "Порт ${STUBBY_PORT} свободен — возможно, сервис не запущен."
    fi

    if [ "$INSTANCE" = "family" ]; then
        if ps w | grep "[s]tubby.*stubby-family" >/dev/null 2>&1; then
            log_success "Процесс stubby${COMPONENT_SUFFIX} работает."
            log_success "=== ПРОВЕРКА ${COMPONENT}${COMPONENT_SUFFIX}: OK ==="
            exit 0
        else
            log_error "Процесс stubby${COMPONENT_SUFFIX} не найден."
            log_error "=== ПРОВЕРКА ${COMPONENT}${COMPONENT_SUFFIX}: НЕИСПРАВНО ==="
            exit 1
        fi
    else
        if ps w | grep "[s]tubby" >/dev/null 2>&1; then
            log_success "Процесс stubby работает."
            log_success "=== ПРОВЕРКА ${COMPONENT}: OK ==="
            exit 0
        else
            log_error "Процесс stubby не найден."
            log_error "=== ПРОВЕРКА ${COMPONENT}: НЕИСПРАВНО ==="
            exit 1
        fi
    fi
}

uninstall_stubby() {
    # Убеждаемся, что переменные установлены правильно для текущего экземпляра
    apply_instance_settings

    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT}${COMPONENT_SUFFIX} ==="

    # При откате после неудачной установки state может быть ещё не записан — всё равно выполняем очистку.
    if [ "${FORCE:-0}" != "1" ] && ! state_has "installed.${COMPONENT}${COMPONENT_SUFFIX}"; then
        log "Файл состояния не найден (откат или компонент не устанавливался через этот скрипт), выполняю очистку."
    fi

    detect_opkg_local

    # Останавливаем сервис через init-скрипт
    stop_stubby || true

    # Ждем немного, чтобы процесс успел остановиться
    sleep 2

    # Удаляем пакет stubby из opkg (мы всегда используем именно его при установке)
    PKG_NAME="stubby"
    if "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^${PKG_NAME} "; then
        log "Удаляю пакет ${PKG_NAME}..."
        if "$OPKG_BIN" remove "${PKG_NAME}" >>"$LOG_FILE" 2>&1; then
            log_success "Пакет ${PKG_NAME} удалён."
        else
            log_error "Ошибка: не удалось удалить пакет ${PKG_NAME}."
        fi
    else
        log "Пакет ${PKG_NAME} не установлен, пропускаю удаление пакета."
    fi

    # Удаляем конфиги (только для семейного экземпляра удаляем только его конфиг)
    if [ "$INSTANCE" = "family" ]; then
        if [ -f "${CONF_DIR}/${CONFIG_FILE}" ]; then
            log "Удаляю конфиг ${CONFIG_FILE}."
            rm -f "${CONF_DIR}/${CONFIG_FILE}"
        fi
    else
        if [ -d "$CONF_DIR" ]; then
            log "Удаляю конфиги в ${CONF_DIR}."
            rm -rf "$CONF_DIR"
        fi
    fi

    # Удаляем init-скрипты из ALLOW_INITD_DIR (S и X)
    FOUND_INIT=0
    for name in $INIT_SCRIPT_NAMES; do
        for dir in "$ALLOW_INITD_DIR" "$INITD_DIR"; do
            s="${dir}/${name}"
            if [ -f "$s" ]; then
                FOUND_INIT=1
                if [ -x "$s" ]; then
                    log "Останавливаю и удаляю init-скрипт ${s}."
                    sh "$s" stop >>"$LOG_FILE" 2>&1 || true
                else
                    log "Удаляю init-скрипт ${s}."
                fi
                rm -f "$s"
            fi
        done
    done
    if [ "$FOUND_INIT" -eq 0 ]; then
        log "Init-скрипты stubby${COMPONENT_SUFFIX} в ${ALLOW_INITD_DIR} не найдены или уже удалены."
    fi

    # Удаляем отметку состояния
    state_unset "installed.${COMPONENT}${COMPONENT_SUFFIX}"

    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT}${COMPONENT_SUFFIX} ЗАВЕРШЕНА ==="

    # Удаляем логи в самом конце (после всех log вызовов)
    # Для семейного экземпляра не удаляем LOG_DIR, так как он общий с основным экземпляром
    if [ "$INSTANCE" != "family" ] && [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR" 2>/dev/null || true
    fi
}

ACTION="$1"
# Парсим параметр INSTANCE из второго аргумента или переменной окружения
if [ -n "$2" ] && [ "$2" != "entware" ]; then
    INSTANCE="$2"
fi

# После парсинга INSTANCE пересчитываем переменные экземпляра.
apply_instance_settings

case "$ACTION" in
    install)
        # Убираем автоматическую деинсталляцию - теперь пользователь решает сам
        # trap обработчик не нужен, так как все ошибки обрабатываются явно через ask_user_on_error
        install_stubby
        ;;
    install-family)
        INSTANCE="family"
        apply_instance_settings
        # Убираем автоматическую деинсталляцию - теперь пользователь решает сам
        # trap обработчик не нужен, так как все ошибки обрабатываются явно через ask_user_on_error
        install_stubby
        ;;
    uninstall)
        uninstall_stubby
        ;;
    uninstall-family)
        INSTANCE="family"
        apply_instance_settings
        uninstall_stubby
        ;;
    check)
        check_stubby
        ;;
    check-family)
        INSTANCE="family"
        apply_instance_settings
        check_stubby
        ;;
    *)
        echo "Использование: $0 {install|install-family|uninstall|uninstall-family|check|check-family} [entware]" >&2
        echo "  install - установить основной экземпляр stubby (порт 41500)" >&2
        echo "  install-family - установить семейный экземпляр stubby (порт 41501)" >&2
        echo "  uninstall - удалить основной экземпляр" >&2
        echo "  uninstall-family - удалить семейный экземпляр" >&2
        echo "  check - проверить основной экземпляр" >&2
        echo "  check-family - проверить семейный экземпляр" >&2
        exit 1
        ;;
esac

