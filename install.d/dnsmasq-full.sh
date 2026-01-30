#!/bin/sh

# Подскрипт для управления компонентом dnsmasq-full
# Должен располагаться на роутере как /opt/tmp/allow/install.d/dnsmasq-full.sh

set -e

COMPONENT="dnsmasq-full"
PLATFORM="${2:-entware}"
INSTANCE="${INSTANCE:-main}"

# Определяем, какой экземпляр устанавливаем
if [ "$INSTANCE" = "family" ]; then
    COMPONENT_SUFFIX="-family"
    DEFAULT_PORT="5301"
    CONFIG_FILE="dnsmasq-family.conf"
    INIT_SCRIPT_PATTERN="S*dnsmasq-family"
    STATE_FILE_SUFFIX="-family"
else
    COMPONENT_SUFFIX=""
    DEFAULT_PORT="5300"
    CONFIG_FILE="dnsmasq.conf"
    INIT_SCRIPT_PATTERN="S*dnsmasq-full"
    STATE_FILE_SUFFIX=""
fi

# Имя пакета по умолчанию. При необходимости можно переопределить для других платформ.
PKG_NAME_DNSMASQ_FULL="dnsmasq-full"

CONF_DIR="/opt/etc/allow/${COMPONENT}"
LOG_DIR="/opt/var/log/allow/${COMPONENT}"
INITD_DIR="/opt/etc/init.d"
ALLOW_INITD_DIR="/opt/etc/allow/init.d"
NDM_DIR="/opt/etc/ndm/netfilter.d"
# NEED_DIR может быть передан через переменную окружения, иначе используем значение по умолчанию
NEED_DIR="${NEED_DIR:-/opt/tmp/allow/resources/${COMPONENT}}"
STATE_KEY_INSTALLED="installed.${COMPONENT}${STATE_FILE_SUFFIX}"
STATE_KEY_PKGS="managed_pkgs.${COMPONENT}${STATE_FILE_SUFFIX}"

# Порт по умолчанию (будет проверен и изменен при необходимости)
PORT="${DNSMASQ_PORT:-$DEFAULT_PORT}"

mkdir -p "$CONF_DIR" "$LOG_DIR"
# Подключаем единое хранилище состояния
LIB_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${LIB_DIR}/state_lib.sh"

LOG_FILE="${LOG_DIR}/${COMPONENT}.log"

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

# Проверка, что stubby-family запущен и слушает порт (для семейного экземпляра)
check_stubby_family() {
    if [ "$INSTANCE" != "family" ]; then
        # Для не-семейного экземпляра проверка не требуется
        return 0
    fi
    
    # Определяем порт stubby-family
    # Сначала пытаемся использовать переменную STUBBY_PORT, если она определена
    if [ -n "${STUBBY_PORT:-}" ]; then
        STUBBY_FAMILY_PORT="$STUBBY_PORT"
    else
        # Если переменная не определена, используем значение по умолчанию
        STUBBY_FAMILY_PORT="41501"
    fi
    
    # Альтернативно, пытаемся прочитать порт из конфигурации dnsmasq
    if [ -f "${CONF_DIR}/${CONFIG_FILE}" ]; then
        CONFIG_PORT=$(grep "^server=127\.0\.0\.1#" "${CONF_DIR}/${CONFIG_FILE}" 2>/dev/null | head -1 | sed 's/.*#\([0-9]*\).*/\1/')
        if [ -n "$CONFIG_PORT" ] && [ "$CONFIG_PORT" -gt 0 ] 2>/dev/null; then
            STUBBY_FAMILY_PORT="$CONFIG_PORT"
        fi
    fi

    # Если порт всё ещё дефолтный — пробуем взять из конфига stubby-family
    if [ "$STUBBY_FAMILY_PORT" = "41501" ] && [ -f "/opt/etc/allow/stubby/stubby-family.yml" ]; then
        CONF_PORT="$(grep -E "^[[:space:]]*-[[:space:]]*127\.0\.0\.1@[0-9]+" "/opt/etc/allow/stubby/stubby-family.yml" 2>/dev/null | head -1 | sed 's/.*@\([0-9][0-9]*\).*/\1/' | tr -cd '0-9')"
        if [ -n "${CONF_PORT:-}" ] && [ "$CONF_PORT" -gt 0 ] 2>/dev/null; then
            STUBBY_FAMILY_PORT="$CONF_PORT"
        fi
    fi
    
    STUBBY_FAMILY_PID="/opt/var/run/stubby-family.pid"
    
    # Проверяем по PID файлу
    if [ -f "$STUBBY_FAMILY_PID" ]; then
        PID=$(cat "$STUBBY_FAMILY_PID" 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            # Проверяем, что stubby-family слушает порт
            if check_port_in_use "$STUBBY_FAMILY_PORT"; then
                return 0
            fi
        fi
    fi
    
    # Альтернативная проверка по процессу
    if pgrep -f "stubby.*stubby-family.yml" >/dev/null 2>&1; then
        if check_port_in_use "$STUBBY_FAMILY_PORT"; then
            return 0
        fi
    fi
    
    # Проверяем, что порт слушается (даже если PID файл не найден)
    if check_port_in_use "$STUBBY_FAMILY_PORT"; then
        return 0
    fi
    
    return 1
}

find_free_port() {
    START_PORT="$1"
    CHECK_PORT="$START_PORT"
    
    while check_port_in_use "$CHECK_PORT"; do
        echo "Порт ${CHECK_PORT} занят, пробуем следующий..." >&2
        CHECK_PORT=$((CHECK_PORT + 1))
        # Защита от бесконечного цикла
        if [ "$CHECK_PORT" -gt $((START_PORT + 100)) ]; then
            echo "Ошибка: не удалось найти свободный порт в диапазоне ${START_PORT}-$((START_PORT + 100))" >&2
            exit 1
        fi
    done
    
    echo "$CHECK_PORT"
}

stop_dnsmasq_full() {
    # Останавливаем через кастомный init-скрипт, если он есть
    SCRIPT_PATH=""
    
    # Определяем паттерн поиска скрипта в зависимости от экземпляра
    if [ "$INSTANCE" = "family" ]; then
        SEARCH_PATTERN="S*dnsmasq-family"
    else
        SEARCH_PATTERN="S*dnsmasq-full"
    fi

    # Сначала ищем в новой директории
    for s in "$ALLOW_INITD_DIR"/$SEARCH_PATTERN; do
        if [ -f "$s" ]; then
            SCRIPT_PATH="$s"
            break
        fi
    done
    # Если не найден, проверяем старую директорию (для миграции)
    if [ -z "$SCRIPT_PATH" ]; then
        for s in "$INITD_DIR"/$SEARCH_PATTERN; do
            if [ -f "$s" ]; then
                SCRIPT_PATH="$s"
                break
            fi
        done
    fi
    
    # Если все еще не найден, пробуем найти по имени файла напрямую
    if [ -z "$SCRIPT_PATH" ]; then
        if [ "$INSTANCE" = "family" ]; then
            if [ -f "${ALLOW_INITD_DIR}/S98dnsmasq-family" ]; then
                SCRIPT_PATH="${ALLOW_INITD_DIR}/S98dnsmasq-family"
            elif [ -f "${INITD_DIR}/S98dnsmasq-family" ]; then
                SCRIPT_PATH="${INITD_DIR}/S98dnsmasq-family"
            fi
        else
            if [ -f "${ALLOW_INITD_DIR}/S98dnsmasq-full" ]; then
                SCRIPT_PATH="${ALLOW_INITD_DIR}/S98dnsmasq-full"
            elif [ -f "${INITD_DIR}/S98dnsmasq-full" ]; then
                SCRIPT_PATH="${INITD_DIR}/S98dnsmasq-full"
            fi
        fi
    fi

    if [ -n "$SCRIPT_PATH" ]; then
        log "Останавливаю dnsmasq-full${COMPONENT_SUFFIX} через ${SCRIPT_PATH}."
        if sh "$SCRIPT_PATH" stop >>"$LOG_FILE" 2>&1; then
            log "dnsmasq-full${COMPONENT_SUFFIX} остановлен."
            return 0
        else
            log "Предупреждение: не удалось корректно остановить dnsmasq-full${COMPONENT_SUFFIX} через init-скрипт."
            return 1
        fi
    else
        log "Init-скрипт для остановки dnsmasq-full${COMPONENT_SUFFIX} не найден, пропускаю остановку через init-скрипт."
        return 1
    fi
}

start_dnsmasq_full() {
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
        log_error "Ошибка: init-скрипт dnsmasq-full${COMPONENT_SUFFIX} не найден в ${ALLOW_INITD_DIR} или ${INITD_DIR}."
        return 1
    fi

    log "Запускаю dnsmasq-full${COMPONENT_SUFFIX} через ${SCRIPT_PATH}."
    if sh "$SCRIPT_PATH" start >>"$LOG_FILE" 2>&1; then
        log "dnsmasq-full${COMPONENT_SUFFIX} запущен (инициализация init-скрипта успешна)."
        return 0
    else
        log_error "Ошибка: не удалось запустить dnsmasq-full${COMPONENT_SUFFIX} через init-скрипт."
        return 1
    fi
}

install_dnsmasq_full() {
    log "=== УСТАНОВКА ${COMPONENT}${COMPONENT_SUFFIX} ==="
    log "Платформа: ${PLATFORM}"
    log "Экземпляр: ${INSTANCE}"

    # Пересчитываем ключи состояния (на случай изменения INSTANCE/суффикса выше по коду)
    STATE_KEY_INSTALLED="installed.${COMPONENT}${STATE_FILE_SUFFIX}"
    STATE_KEY_PKGS="managed_pkgs.${COMPONENT}${STATE_FILE_SUFFIX}"

    # Останавливаем старый процесс перед установкой нового экземпляра
    log "Останавливаю старый процесс перед установкой..."
    stop_dnsmasq_full || true
    sleep 1

    detect_opkg_local

    log "Использую opkg: ${OPKG_BIN}"

    # Список пакетов, которые ставили мы (для корректного uninstall)
    MANAGED_PKGS=""

    # Проверяем, установлен ли уже пакет
    if "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^${PKG_NAME_DNSMASQ_FULL} "; then
        log "Пакет ${PKG_NAME_DNSMASQ_FULL} уже установлен, пропускаю установку пакета."
    else
        # Обновляем список пакетов перед установкой
        log "Обновляю список пакетов opkg..."
        if "$OPKG_BIN" update >>"$LOG_FILE" 2>&1; then
            log "Список пакетов обновлен."
        else
            log "Предупреждение: не удалось обновить список пакетов (продолжаем установку)."
        fi
        log "Устанавливаю пакет ${PKG_NAME_DNSMASQ_FULL}..."
        if "$OPKG_BIN" install "${PKG_NAME_DNSMASQ_FULL}" >>"$LOG_FILE" 2>&1; then
            log_success "Пакет ${PKG_NAME_DNSMASQ_FULL} успешно установлен."
            MANAGED_PKGS="${PKG_NAME_DNSMASQ_FULL}"
        else
            log_error "Ошибка: не удалось установить пакет ${PKG_NAME_DNSMASQ_FULL}."
            exit 1
        fi
    fi

    # Проверяем и выбираем свободный порт для dnsmasq
    if [ -z "$DEFAULT_PORT" ]; then
        DEFAULT_PORT="5300"
    fi
    log "Проверяю доступность порта ${DEFAULT_PORT}..."
    PORT=$(find_free_port "$DEFAULT_PORT")
    if [ -z "$PORT" ]; then
        log_error "Ошибка: не удалось определить порт для dnsmasq."
        exit 1
    fi
    if [ "$PORT" != "$DEFAULT_PORT" ]; then
        log "Порт ${DEFAULT_PORT} занят, использую порт ${PORT}."
    else
        log "Порт ${PORT} свободен."
    fi

    # Сохраняем порт dnsmasq для других компонентов
    export DNSMASQ_PORT="$PORT"

    # Определяем порт stubby из конфига stubby (если установлен)
    if [ "$INSTANCE" = "family" ]; then
        STUBBY_DEFAULT_PORT="41501"
        STUBBY_CONF_FILE="/opt/etc/allow/stubby/stubby-family.yml"
    else
        STUBBY_DEFAULT_PORT="41500"
        STUBBY_CONF_FILE="/opt/etc/allow/stubby/stubby.yml"
    fi
    STUBBY_PORT=""
    if [ -f "${STUBBY_CONF_FILE}" ]; then
        STUBBY_PORT="$(grep -E "^[[:space:]]*-[[:space:]]*127\.0\.0\.1@[0-9]+" "${STUBBY_CONF_FILE}" 2>/dev/null | head -1 | sed 's/.*@\([0-9][0-9]*\).*/\1/' | tr -cd '0-9')"
        if [ -n "${STUBBY_PORT:-}" ]; then
            log "Обнаружен порт stubby${COMPONENT_SUFFIX}: ${STUBBY_PORT} (из ${STUBBY_CONF_FILE})"
        fi
    fi

    # Если порт stubby не найден, используем значение по умолчанию из конфига
    if [ -z "$STUBBY_PORT" ]; then
        log "Порт stubby${COMPONENT_SUFFIX} не найден, будет использовано значение по умолчанию ${STUBBY_DEFAULT_PORT} из конфига."
        STUBBY_PORT="$STUBBY_DEFAULT_PORT"
    fi

    # Копируем hosts-файлы в ipsets директорию (только при установке основного экземпляра:
    # ipsets общая для main и family, при install-family файлы уже на месте)
    IPSETS_DIR="${CONF_DIR}/ipsets"
    mkdir -p "$IPSETS_DIR" 2>/dev/null || true
    
    # Проверяем наличие исходной директории
    if [ ! -d "${NEED_DIR}" ]; then
        log_error "Ошибка: директория ${NEED_DIR} не найдена."
        log_error "Убедитесь, что папка allow скопирована на роутер в /opt/allow/"
        exit 1
    fi
    
    if [ "$INSTANCE" = "main" ]; then
        log "Копирую hosts-файлы из ${NEED_DIR}/ipsets в ${IPSETS_DIR}."
        
        # Список обязательных файлов для копирования
        REQUIRED_FILES="nonbypass.txt bypass.txt zapret.txt"
        
        # Проверяем наличие файлов перед копированием
        HOSTS_FILES_FOUND=0
        for filename in $REQUIRED_FILES; do
            if [ -f "${NEED_DIR}/ipsets/${filename}" ]; then
                HOSTS_FILES_FOUND=$((HOSTS_FILES_FOUND + 1))
            fi
        done
        
        if [ "$HOSTS_FILES_FOUND" -eq 0 ]; then
            log_error "Ошибка: hosts-файлы не найдены в ${NEED_DIR}/ipsets."
            log_error "Проверьте, что файлы nonbypass.txt, bypass.txt, zapret.txt находятся в ${NEED_DIR}/ipsets/"
            exit 1
        fi
        
        log "Найдено hosts-файлов: $HOSTS_FILES_FOUND"
        
        # Копируем файлы
        HOSTS_COUNT=0
        for filename in $REQUIRED_FILES; do
            hosts_file="${NEED_DIR}/ipsets/${filename}"
            if [ -f "$hosts_file" ]; then
                HOSTS_COUNT=$((HOSTS_COUNT + 1))
                log "Копирую $filename..."
                if cp -f "$hosts_file" "$IPSETS_DIR"/ 2>>"$LOG_FILE"; then
                    log_success "Файл $filename скопирован."
                else
                    log_error "Ошибка: не удалось скопировать hosts-файл: $hosts_file"
                    exit 1
                fi
            else
                log "Предупреждение: файл $filename не найден, пропускаю."
            fi
        done
        
        if [ "$HOSTS_COUNT" -eq 0 ]; then
            log_error "Ошибка: не удалось скопировать ни одного hosts-файла."
            exit 1
        else
            log_success "Скопировано hosts-файлов: $HOSTS_COUNT"
        fi
    else
        # family: ipsets уже заполнена при установке main, только проверяем наличие
        REQUIRED_FILES="nonbypass.txt bypass.txt zapret.txt"
        for filename in $REQUIRED_FILES; do
            if [ ! -f "${IPSETS_DIR}/${filename}" ]; then
                log_error "Ошибка: hosts-файл ${filename} не найден в ${IPSETS_DIR}. Сначала установите основной экземпляр (install)."
                exit 1
            fi
        done
        log "hosts-файлы в ${IPSETS_DIR} на месте, пропускаю копирование."
    fi

    # Копируем process-hosts.sh
    if [ -f "${NEED_DIR}/process-hosts.sh" ]; then
        log "Копирую process-hosts.sh в ${CONF_DIR}."
        cp -f "${NEED_DIR}/process-hosts.sh" "$CONF_DIR"/ 2>>"$LOG_FILE" || {
            log_error "Ошибка: не удалось скопировать process-hosts.sh."
            exit 1
        }
        chmod +x "${CONF_DIR}/process-hosts.sh" 2>/dev/null || true
        # Нормализуем окончания строк
        sed -i 's/\r$//' "${CONF_DIR}/process-hosts.sh" 2>/dev/null || true
    fi
    
    # Копируем pre-resolve-hosts.sh
    if [ -f "${NEED_DIR}/pre-resolve-hosts.sh" ]; then
        log "Копирую pre-resolve-hosts.sh в ${CONF_DIR}."
        cp -f "${NEED_DIR}/pre-resolve-hosts.sh" "$CONF_DIR"/ 2>>"$LOG_FILE" || {
            log_error "Ошибка: не удалось скопировать pre-resolve-hosts.sh."
            exit 1
        }
        chmod +x "${CONF_DIR}/pre-resolve-hosts.sh" 2>/dev/null || true
        # Нормализуем окончания строк
        sed -i 's/\r$//' "${CONF_DIR}/pre-resolve-hosts.sh" 2>/dev/null || true
    fi

    # Создаем ipset'ы перед запуском dnsmasq
    log "Создаю ipset'ы для hosts-файлов..."
    for ipset_name in nonbypass bypass; do
        if ! ipset list "$ipset_name" >/dev/null 2>&1; then
            log "Создание ipset '$ipset_name' (hash:net)..."
            if ipset create "$ipset_name" hash:net 2>>"$LOG_FILE"; then
                log_success "ipset '$ipset_name' создан."
            else
                log_error "Ошибка: не удалось создать ipset '$ipset_name'."
                exit 1
            fi
        else
            log "ipset '$ipset_name' уже существует, пропускаю."
        fi
    done

    # Запускаем process-hosts.sh для генерации конфигурации
    if [ -f "${CONF_DIR}/process-hosts.sh" ]; then
        log "Генерирую конфигурацию ipset для dnsmasq..."
        if sh "${CONF_DIR}/process-hosts.sh" >>"$LOG_FILE" 2>&1; then
            log_success "Конфигурация ipset сгенерирована."
        else
            log_error "Ошибка: не удалось сгенерировать конфигурацию ipset."
            exit 1
        fi
    fi

    # Копируем конфиги и init-скрипты из NEED_DIR, если они есть
    if [ -d "${NEED_DIR}/etc" ]; then
        log "Копирую конфиги из ${NEED_DIR}/etc в ${CONF_DIR}."
        # Для семейного экземпляра копируем только нужный конфиг
        if [ "$INSTANCE" = "family" ]; then
            if [ -f "${NEED_DIR}/etc/${CONFIG_FILE}" ]; then
                cp -f "${NEED_DIR}/etc/${CONFIG_FILE}" "$CONF_DIR"/ 2>>"$LOG_FILE" || {
                    log_error "Ошибка: не удалось скопировать конфиг ${CONFIG_FILE}."
                    exit 1
                }
            else
                log_error "Ошибка: конфиг ${CONFIG_FILE} не найден в ${NEED_DIR}/etc/"
                exit 1
            fi
        else
            cp -f "${NEED_DIR}/etc/"* "$CONF_DIR"/ 2>>"$LOG_FILE" || {
                log_error "Ошибка: не удалось скопировать конфиги."
                exit 1
            }
        fi

        # Обновляем порт dnsmasq в конфиге
        if [ -f "${CONF_DIR}/${CONFIG_FILE}" ]; then
            log "Обновляю порт dnsmasq${COMPONENT_SUFFIX} в конфиге на ${PORT}."
            sed -i "s|^port=[0-9]*|port=${PORT}|g" "${CONF_DIR}/${CONFIG_FILE}" 2>/dev/null || {
                log "Предупреждение: не удалось обновить порт dnsmasq в конфиге."
            }
        fi

        # Обновляем порт stubby в конфиге dnsmasq, если он найден
        if [ -n "$STUBBY_PORT" ] && [ -f "${CONF_DIR}/${CONFIG_FILE}" ]; then
            log "Обновляю порт stubby${COMPONENT_SUFFIX} в конфиге dnsmasq на ${STUBBY_PORT}."
            # Заменяем строку server=127.0.0.1#... на server=127.0.0.1#${STUBBY_PORT}
            sed -i "s|server=127\.0\.0\.1#[0-9]*|server=127.0.0.1#${STUBBY_PORT}|g" "${CONF_DIR}/${CONFIG_FILE}" 2>/dev/null || {
                log "Предупреждение: не удалось обновить порт stubby в конфиге (возможно, уже правильный)."
            }
        fi
    else
        log "Предупреждение: директория ${NEED_DIR}/etc не найдена, конфиги не будут скопированы."
    fi

    if [ -d "${NEED_DIR}/init.d" ]; then
        # Создаем директорию для скриптов компонентов
        mkdir -p "$ALLOW_INITD_DIR" 2>/dev/null || {
            log_error "Ошибка: не удалось создать директорию ${ALLOW_INITD_DIR}"
            exit 1
        }
        
        log "Копирую init-скрипты из ${NEED_DIR}/init.d в ${ALLOW_INITD_DIR}."
        # Для семейного экземпляра копируем только нужный скрипт
        if [ "$INSTANCE" = "family" ]; then
            if [ -f "${NEED_DIR}/init.d/S98dnsmasq-family" ]; then
                cp -f "${NEED_DIR}/init.d/S98dnsmasq-family" "$ALLOW_INITD_DIR"/ 2>>"$LOG_FILE" || {
                    log_error "Ошибка: не удалось скопировать init-скрипт S98dnsmasq-family."
                    exit 1
                }
                chmod +x "${ALLOW_INITD_DIR}/S98dnsmasq-family" 2>/dev/null || true
                sed -i 's/\r$//' "${ALLOW_INITD_DIR}/S98dnsmasq-family" 2>/dev/null || true
            else
                log_error "Ошибка: init-скрипт S98dnsmasq-family не найден в ${NEED_DIR}/init.d/"
                exit 1
            fi
        else
            cp -f "${NEED_DIR}/init.d/"* "$ALLOW_INITD_DIR"/ 2>>"$LOG_FILE" || {
                log_error "Ошибка: не удалось скопировать init-скрипты."
                exit 1
            }
            chmod +x "${ALLOW_INITD_DIR}"/S*"$COMPONENT"* 2>/dev/null || true

            # На всякий случай нормализуем окончания строк (CRLF -> LF), если скрипт редактировался в Windows
            for s in "${ALLOW_INITD_DIR}"/S*"$COMPONENT"*; do
                if [ -f "$s" ]; then
                    sed -i 's/\r$//' "$s" 2>/dev/null || true
                fi
            done
        fi
    else
        log "Предупреждение: директория ${NEED_DIR}/init.d не найдена, init-скрипты не будут скопированы."
    fi

    # Копируем ndm netfilter хуки (если есть)
    if [ -d "${NEED_DIR}/netfilter.d" ]; then
        # Проверяем, есть ли файлы для копирования
        if ls "${NEED_DIR}/netfilter.d/"* >/dev/null 2>&1; then
            log "Копирую ndm netfilter хуки из ${NEED_DIR}/netfilter.d в ${NDM_DIR}."
            mkdir -p "$NDM_DIR" 2>/dev/null || true
            cp -f "${NEED_DIR}/netfilter.d/"* "$NDM_DIR"/ 2>>"$LOG_FILE" || {
                log_error "Ошибка: не удалось скопировать ndm netfilter хуки."
                exit 1
            }
            chmod +x "${NDM_DIR}/"* 2>/dev/null || true
            for s in "${NDM_DIR}/"*; do
                if [ -f "$s" ]; then
                    sed -i 's/\r$//' "$s" 2>/dev/null || true
                fi
            done
            
            # Запускаем хуки после копирования (чтобы правила iptables применились)
            log "Запускаю ndm netfilter хуки..."
            for hook in "${NDM_DIR}/"*.sh; do
                if [ -f "$hook" ] && [ -x "$hook" ]; then
                    HOOK_NAME=$(basename "$hook")
                    log "Запускаю хук ${HOOK_NAME}..."
                    sh "$hook" restart >>"$LOG_FILE" 2>&1 || {
                        log "Предупреждение: хук ${HOOK_NAME} завершился с ошибкой (продолжаем)."
                    }
                fi
            done
        else
            log "Директория ${NEED_DIR}/netfilter.d пуста, хуки ndm не будут скопированы."
        fi
    else
        log "Предупреждение: директория ${NEED_DIR}/netfilter.d не найдена, хуки ndm не будут скопированы."
    fi

    # Если S01allow установлен, используем его для запуска и проверки
    if [ -x "${INITD_DIR}/S01allow" ]; then
        log "S01allow обнаружен, запускаю компонент через S01allow..."
        if sh "${INITD_DIR}/S01allow" start >>"$LOG_FILE" 2>&1; then
            log_success "Компонент запущен через S01allow."
        else
            if ! ask_user_on_error "Ошибка: не удалось запустить компонент через S01allow." "${COMPONENT}${COMPONENT_SUFFIX}"; then
                log "Пользователь выбрал откат установки."
                uninstall_dnsmasq_full
                return 1
            else
                log "Пользователь выбрал продолжить установку."
                return 1
            fi
        fi
        
        # Проверяем статус через S01allow
        log "Проверяю статус компонента через S01allow..."
        if sh "${INITD_DIR}/S01allow" status >>"$LOG_FILE" 2>&1; then
            log_success "Проверка статуса через S01allow успешна."
        else
            if ! ask_user_on_error "Ошибка: проверка статуса через S01allow не прошла." "${COMPONENT}${COMPONENT_SUFFIX}"; then
                log "Пользователь выбрал откат установки."
                uninstall_dnsmasq_full
                return 1
            else
                log "Пользователь выбрал продолжить установку."
                return 1
            fi
        fi
    else
        # Запускаем сервис напрямую (если S01allow не установлен)
        if ! start_dnsmasq_full; then
            if ! ask_user_on_error "Ошибка: запуск dnsmasq-full не удался." "${COMPONENT}${COMPONENT_SUFFIX}"; then
                log "Пользователь выбрал откат установки."
                uninstall_dnsmasq_full
                return 1
            else
                log "Пользователь выбрал продолжить установку."
                return 1
            fi
        fi

        # Проверяем, слушает ли нужный порт (с повторными попытками)
        PORT_CHECK_OK=0
        for i in 1 2 3; do
            if check_port_in_use "$PORT"; then
                PORT_CHECK_OK=1
                break
            fi
            if [ "$i" -lt 3 ]; then
                log "Попытка ${i}/3: порт ${PORT} еще не слушается, жду 1 секунду..."
                sleep 1
            fi
        done

        if [ "$PORT_CHECK_OK" -eq 1 ]; then
            log_success "Проверка порта: сервис слушает порт ${PORT}."
        else
            if ! ask_user_on_error "Ошибка: после запуска сервис НЕ слушает порт ${PORT}." "${COMPONENT}${COMPONENT_SUFFIX}"; then
                log "Пользователь выбрал откат установки."
                uninstall_dnsmasq_full
                return 1
            else
                log "Пользователь выбрал продолжить установку."
                return 1
            fi
        fi

        # Проверяем процесс
        if ps w | grep "[d]nsmasq" >/dev/null 2>&1; then
            log "Процесс dnsmasq найден."
        else
            if ! ask_user_on_error "Ошибка: процесс dnsmasq не найден после установки." "${COMPONENT}${COMPONENT_SUFFIX}"; then
                log "Пользователь выбрал откат установки."
                uninstall_dnsmasq_full
                return 1
            else
                log "Пользователь выбрал продолжить установку."
                return 1
            fi
        fi
    fi

    # Проверяем работоспособность через dig (если доступен)
    if command -v dig >/dev/null 2>&1; then
        # Для семейного экземпляра проверяем, что stubby-family работает
        if [ "$INSTANCE" = "family" ]; then
            log "Проверяю зависимость от stubby-family..."
            STUBBY_CHECK_OK=0
            for i in 1 2 3 4 5; do
                if check_stubby_family; then
                    STUBBY_CHECK_OK=1
                    log "stubby-family работает и слушает порт."
                    break
                fi
                if [ "$i" -lt 5 ]; then
                    log "Попытка ${i}/5: stubby-family еще не готов, жду 2 секунды..."
                    sleep 2
                fi
            done
            
            if [ "$STUBBY_CHECK_OK" -eq 0 ]; then
                if ! ask_user_on_error "Ошибка: stubby-family не запущен или не слушает порт. dnsmasq-family требует, чтобы stubby-family был запущен и работал." "${COMPONENT}${COMPONENT_SUFFIX}"; then
                    log "Пользователь выбрал откат установки."
                    uninstall_dnsmasq_full
                    return 1
                else
                    log "Пользователь выбрал продолжить установку."
                    return 1
                fi
            fi
        fi
        
        log "Проверяю работоспособность dnsmasq через dig..."
        # Даём время сервису полностью запуститься и инициализироваться
        sleep 3
        
        # Пробуем несколько раз с задержками
        DIG_CHECK_OK=0
        DIG_RESULT=""
        for i in 1 2 3 4 5; do
            log "Попытка ${i}/5: проверка DNS через dig..."
            DIG_OUTPUT=$(dig @127.0.0.1 -p "${PORT}" ya.ru +short +timeout=5 2>>"$LOG_FILE")
            DIG_RESULT=$(echo "$DIG_OUTPUT" | head -1)
            
            if [ -n "$DIG_RESULT" ] && echo "$DIG_RESULT" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
                DIG_CHECK_OK=1
                log_success "Проверка dig успешна: dnsmasq отвечает и возвращает IP-адреса (${DIG_RESULT})."
                break
            else
                if [ "$i" -lt 5 ]; then
                    log "Попытка ${i}/5 не удалась (результат: '${DIG_RESULT}'), жду 2 секунды перед следующей попыткой..."
                    sleep 2
                else
                    log_error "Попытка ${i}/5 не удалась. Результат dig: '${DIG_RESULT}'"
                    log_error "Полный вывод dig:"
                    echo "$DIG_OUTPUT" | while IFS= read -r line; do
                        log_error "  $line"
                    done
                fi
            fi
        done
        
        if [ "$DIG_CHECK_OK" -eq 0 ]; then
            ERROR_MSG="Ошибка: dnsmasq не отвечает на DNS-запросы или возвращает некорректный ответ после 5 попыток. Проверьте логи dnsmasq: /opt/var/log/allow/dnsmasq${COMPONENT_SUFFIX}.log"
            if [ "$INSTANCE" = "family" ]; then
                ERROR_MSG="$ERROR_MSG Проверьте логи stubby-family: /opt/var/log/allow/stubby-family.log"
            fi
            if ! ask_user_on_error "$ERROR_MSG" "${COMPONENT}${COMPONENT_SUFFIX}"; then
                log "Пользователь выбрал откат установки."
                uninstall_dnsmasq_full
                return 1
            else
                log "Пользователь выбрал продолжить установку."
                return 1
            fi
        fi
    else
        log "Предупреждение: dig не найден, пропускаю проверку DNS-запросов."
    fi

    # Сохраняем состояние (установлено + какие пакеты ставили мы)
    state_set "$STATE_KEY_PKGS" "$MANAGED_PKGS"
    state_set "$STATE_KEY_INSTALLED" "$(date '+%Y-%m-%d %H:%M:%S')"

    log_success "=== УСТАНОВКА ${COMPONENT}${COMPONENT_SUFFIX} ЗАВЕРШЕНА УСПЕШНО ==="
    
    # Автоматически устанавливаем семейный экземпляр после успешной установки основного
    if [ "$INSTANCE" != "family" ]; then
        log ""
        log "================================================================"
        log "  Установка семейного экземпляра dnsmasq-family"
        log "================================================================"
        log ""
        
        # Сохраняем текущие значения переменных
        OLD_INSTANCE="$INSTANCE"
        OLD_COMPONENT_SUFFIX="$COMPONENT_SUFFIX"
        OLD_DEFAULT_PORT="$DEFAULT_PORT"
        OLD_CONFIG_FILE="$CONFIG_FILE"
        OLD_INIT_SCRIPT_PATTERN="$INIT_SCRIPT_PATTERN"
        OLD_STATE_FILE_SUFFIX="$STATE_FILE_SUFFIX"
        
        # Устанавливаем параметры для семейного экземпляра
        INSTANCE="family"
        COMPONENT_SUFFIX="-family"
        DEFAULT_PORT="5301"
        CONFIG_FILE="dnsmasq-family.conf"
        INIT_SCRIPT_PATTERN="S*dnsmasq-family"
        STATE_FILE_SUFFIX="-family"
        STATE_KEY_INSTALLED="installed.${COMPONENT}${STATE_FILE_SUFFIX}"
        STATE_KEY_PKGS="managed_pkgs.${COMPONENT}${STATE_FILE_SUFFIX}"
        
        # Вызываем установку семейного экземпляра
        if install_dnsmasq_full; then
            log_success "Семейный экземпляр dnsmasq-family установлен успешно."
        else
            log "Предупреждение: установка семейного экземпляра dnsmasq-family завершилась с ошибкой (основной экземпляр установлен)."
        fi
        
        # Восстанавливаем значения переменных
        INSTANCE="$OLD_INSTANCE"
        COMPONENT_SUFFIX="$OLD_COMPONENT_SUFFIX"
        DEFAULT_PORT="$OLD_DEFAULT_PORT"
        CONFIG_FILE="$OLD_CONFIG_FILE"
        INIT_SCRIPT_PATTERN="$OLD_INIT_SCRIPT_PATTERN"
        STATE_FILE_SUFFIX="$OLD_STATE_FILE_SUFFIX"
        STATE_KEY_INSTALLED="installed.${COMPONENT}${STATE_FILE_SUFFIX}"
        STATE_KEY_PKGS="managed_pkgs.${COMPONENT}${STATE_FILE_SUFFIX}"
        
        log ""
        log "================================================================"
        log ""
    fi
}

check_dnsmasq_full() {
    log "=== ПРОВЕРКА ${COMPONENT}${COMPONENT_SUFFIX} ==="

    # Определяем порт из текущего конфига dnsmasq (источник истины)
    if [ -f "${CONF_DIR}/${CONFIG_FILE}" ]; then
        CONF_PORT="$(grep -E "^[[:space:]]*port=" "${CONF_DIR}/${CONFIG_FILE}" 2>/dev/null | grep -v "^[[:space:]]*#" | head -1 | sed 's/.*=\([0-9][0-9]*\).*/\1/' | tr -cd '0-9')"
        if [ -n "${CONF_PORT:-}" ]; then
            PORT="$CONF_PORT"
        fi
    fi

    if check_port_in_use "$PORT"; then
        log "Порт ${PORT} занят (ожидаемо, если сервис запущен)."
    else
        log "Порт ${PORT} свободен — возможно, сервис не запущен."
    fi

    if [ "$INSTANCE" = "family" ]; then
        if ps w | grep "[d]nsmasq.*dnsmasq-family" | grep -v grep >/dev/null 2>&1; then
            log_success "Процесс dnsmasq${COMPONENT_SUFFIX} работает."
            log_success "=== ПРОВЕРКА ${COMPONENT}${COMPONENT_SUFFIX}: OK ==="
            exit 0
        else
            log_error "Процесс dnsmasq${COMPONENT_SUFFIX} не найден."
            log_error "=== ПРОВЕРКА ${COMPONENT}${COMPONENT_SUFFIX}: НЕИСПРАВНО ==="
            exit 1
        fi
    else
        if ps w | grep "[d]nsmasq" | grep -v grep >/dev/null 2>&1; then
            log_success "Процесс dnsmasq работает."
            log_success "=== ПРОВЕРКА ${COMPONENT}: OK ==="
            exit 0
        else
            log_error "Процесс dnsmasq не найден."
            log_error "=== ПРОВЕРКА ${COMPONENT}: НЕИСПРАВНО ==="
            exit 1
        fi
    fi
}

uninstall_dnsmasq_full() {
    # Убеждаемся, что переменные установлены правильно для текущего экземпляра
    if [ "$INSTANCE" = "family" ]; then
        COMPONENT_SUFFIX="-family"
        CONFIG_FILE="dnsmasq-family.conf"
        INIT_SCRIPT_PATTERN="S*dnsmasq-family"
        STATE_FILE_SUFFIX="-family"
    else
        COMPONENT_SUFFIX=""
        CONFIG_FILE="dnsmasq.conf"
        INIT_SCRIPT_PATTERN="S*dnsmasq-full"
        STATE_FILE_SUFFIX=""
    fi

    STATE_KEY_INSTALLED="installed.${COMPONENT}${STATE_FILE_SUFFIX}"
    STATE_KEY_PKGS="managed_pkgs.${COMPONENT}${STATE_FILE_SUFFIX}"
    
    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT}${COMPONENT_SUFFIX} ==="

    # Проверка состояния установки (если не FORCE)
    if [ "${FORCE:-0}" != "1" ]; then
        if ! state_has "$STATE_KEY_INSTALLED"; then
            log "Компонент ${COMPONENT}${COMPONENT_SUFFIX} не установлен (файл состояния не найден), пропускаю деинсталляцию."
            return 0
        fi
    fi

    detect_opkg_local

    # Сначала останавливаем сервис через init-скрипт (правильный способ)
    stop_dnsmasq_full || true
    
    # Ждем немного, чтобы процесс успел остановиться
    sleep 2

    # Политика: деинсталлятор НЕ добивает процессы принудительно.
    # Если stop не сработал — это вопрос к init-скрипту (S98dnsmasq-*).
    if [ "$INSTANCE" = "family" ]; then
        if ps w | grep "[d]nsmasq.*dnsmasq-family" >/dev/null 2>&1; then
            log_error "Предупреждение: процесс dnsmasq-family все еще запущен после stop. Проверьте init-скрипт dnsmasq-family."
        else
            log "Процесс dnsmasq-family успешно остановлен."
        fi
    else
        if ps w | grep -E "[d]nsmasq.*(dnsmasq-full\.runtime\.conf|dnsmasq\.conf)" >/dev/null 2>&1; then
            log_error "Предупреждение: процесс dnsmasq-full все еще запущен после stop. Проверьте init-скрипт dnsmasq-full."
        else
            log "Процесс dnsmasq-full успешно остановлен."
        fi
    fi

    # Удаляем пакет только если ставили его мы
    PKGS="$(state_get "$STATE_KEY_PKGS")"
    if state_list_contains_word "$PKGS" "$PKG_NAME_DNSMASQ_FULL"; then
        if "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^${PKG_NAME_DNSMASQ_FULL} "; then
            log "Удаляю пакет ${PKG_NAME_DNSMASQ_FULL} (установленный инсталятором Allow)..."
            if "$OPKG_BIN" remove "${PKG_NAME_DNSMASQ_FULL}" >>"$LOG_FILE" 2>&1; then
                log_success "Пакет ${PKG_NAME_DNSMASQ_FULL} удалён."
            else
                log_error "Ошибка: не удалось удалить пакет ${PKG_NAME_DNSMASQ_FULL}."
            fi
        else
            log "Пакет ${PKG_NAME_DNSMASQ_FULL} уже отсутствует, пропускаю."
        fi
    else
        log "Пакет ${PKG_NAME_DNSMASQ_FULL} не установлен инсталятором Allow, удаление пропускаю."
    fi

    # opkg часто оставляет conffiles даже после remove.
    # По требованию: чистим /opt/etc/dnsmasq.conf* только если пакет ставили мы или FORCE=1.
    if [ "${FORCE:-0}" = "1" ] || state_list_contains_word "$PKGS" "$PKG_NAME_DNSMASQ_FULL"; then
        rm -f /opt/etc/dnsmasq.conf* 2>/dev/null || true
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

    # Удаляем init-скрипты из ALLOW_INITD_DIR
    FOUND_INIT=0
    for s in "$ALLOW_INITD_DIR"/$INIT_SCRIPT_PATTERN; do
        if [ -f "$s" ]; then
            FOUND_INIT=1
            log "Удаляю init-скрипт ${s}."
            rm -f "$s"
        fi
    done
    # Также проверяем старую директорию на случай миграции
    for s in "$INITD_DIR"/$INIT_SCRIPT_PATTERN; do
        if [ -f "$s" ]; then
            FOUND_INIT=1
            log "Удаляю init-скрипт ${s} (старая директория)."
            rm -f "$s"
        fi
    done
    if [ "$FOUND_INIT" -eq 0 ]; then
        log "Init-скрипты dnsmasq-full${COMPONENT_SUFFIX} в ${INITD_DIR} не найдены или уже удалены."
    fi

    # Удаляем ipset'ы (если они были созданы нами)
    log "Удаляю ipset'ы..."
    for ipset_name in nonbypass bypass; do
        if ipset list "$ipset_name" >/dev/null 2>&1; then
            log "Удаляю ipset '$ipset_name'..."
            ipset destroy "$ipset_name" 2>/dev/null || true
        fi
    done

    # Удаляем ndm hook bypass1
    if [ -f "${NDM_DIR}/010-bypass1.sh" ]; then
        log "Удаляю ndm hook 010-bypass1.sh."
        rm -f "${NDM_DIR}/010-bypass1.sh" 2>/dev/null || true
    fi

    # Удаляем отметки состояния
    state_unset "$STATE_KEY_PKGS"
    state_unset "$STATE_KEY_INSTALLED"

    # Сообщаем о завершении до удаления логов, чтобы log() не пытался писать в удалённую директорию
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

case "$ACTION" in
    install)
        # Убираем автоматическую деинсталляцию - теперь пользователь решает сам
        # trap обработчик не нужен, так как все ошибки обрабатываются явно через ask_user_on_error
        install_dnsmasq_full
        ;;
    install-family)
        INSTANCE="family"
        # Убираем автоматическую деинсталляцию - теперь пользователь решает сам
        # trap обработчик не нужен, так как все ошибки обрабатываются явно через ask_user_on_error
        install_dnsmasq_full
        ;;
    uninstall)
        uninstall_dnsmasq_full
        ;;
    uninstall-family)
        INSTANCE="family"
        uninstall_dnsmasq_full
        ;;
    check)
        check_dnsmasq_full
        ;;
    check-family)
        INSTANCE="family"
        check_dnsmasq_full
        ;;
    *)
        echo "Использование: $0 {install|install-family|uninstall|uninstall-family|check|check-family} [entware]" >&2
        echo "  install - установить основной экземпляр dnsmasq-full (порт 5300)" >&2
        echo "  install-family - установить семейный экземпляр dnsmasq-family (порт 5301)" >&2
        echo "  uninstall - удалить основной экземпляр" >&2
        echo "  uninstall-family - удалить семейный экземпляр" >&2
        echo "  check - проверить основной экземпляр" >&2
        echo "  check-family - проверить семейный экземпляр" >&2
        exit 1
        ;;
esac


