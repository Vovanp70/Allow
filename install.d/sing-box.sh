#!/bin/sh

# Подскрипт для управления компонентом sing-box
# Должен располагаться на роутере как /opt/tmp/allow/install.d/sing-box.sh

set -e

COMPONENT="sing-box"
PLATFORM="${2:-entware}"

# Имя пакета по умолчанию. При необходимости можно переопределить для других платформ.
PKG_NAME_SING_BOX="sing-box-go"

CONF_DIR="/opt/etc/allow/${COMPONENT}"
LOG_DIR="/opt/var/log/allow/${COMPONENT}"
INITD_DIR="/opt/etc/init.d"
ALLOW_INITD_DIR="/opt/etc/allow/init.d"
NDM_DIR="/opt/etc/ndm/netfilter.d"
# NEED_DIR может быть передан через переменную окружения, иначе используем значение по умолчанию
NEED_DIR="${NEED_DIR:-/opt/tmp/allow/resources/${COMPONENT}}"
STATE_KEY_INSTALLED="installed.${COMPONENT}"
STATE_KEY_PKGS="managed_pkgs.${COMPONENT}"

# Подключаем единое хранилище состояния
LIB_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${LIB_DIR}/state_lib.sh"

mkdir -p "$CONF_DIR" "$LOG_DIR"

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

# Возвращает PID'ы ТОЛЬКО процессов sing-box (не install_all.sh/sing-box.sh/init-скрипты).
# Важно: нельзя использовать grep "[s]ing-box" по всей строке ps — иначе можно получить ложные совпадения
# и (в случае kill) убить деинсталлятор.
get_sing_box_pids() {
    # pidof обычно самый безопасный вариант
    if command -v pidof >/dev/null 2>&1; then
        pidof sing-box 2>/dev/null || true
        return 0
    fi

    # Fallback: ищем по бинарнику и подписи "run"
    ps w 2>/dev/null | awk '
        $0 ~ /(^|[[:space:]])(\\/opt\\/bin\\/sing-box|sing-box)([[:space:]]|$)/ &&
        $0 ~ / run / {
            print $1
        }
    ' 2>/dev/null || true
}

stop_sing_box() {
    SCRIPT_PATH=""
    # Сначала ищем в новой директории
    for s in "$ALLOW_INITD_DIR"/S*"$COMPONENT"*; do
        if [ -f "$s" ]; then
            SCRIPT_PATH="$s"
            break
        fi
    done
    # Если не найден, проверяем старую директорию (для миграции)
    if [ -z "$SCRIPT_PATH" ]; then
        for s in "$INITD_DIR"/S*"$COMPONENT"*; do
            if [ -f "$s" ]; then
                SCRIPT_PATH="$s"
                break
            fi
        done
    fi

    if [ -n "$SCRIPT_PATH" ]; then
        log "Останавливаю sing-box через ${SCRIPT_PATH}."
        if sh "$SCRIPT_PATH" stop >>"$LOG_FILE" 2>&1; then
            log "sing-box остановлен."
        else
            log "Предупреждение: не удалось корректно остановить sing-box."
        fi
    else
        log "Init-скрипт для остановки sing-box не найден, пропускаю остановку."
    fi
}

start_sing_box() {
    SCRIPT_PATH=""
    # Сначала ищем в новой директории
    for s in "$ALLOW_INITD_DIR"/S*"$COMPONENT"*; do
        if [ -f "$s" ]; then
            SCRIPT_PATH="$s"
            break
        fi
    done
    # Если не найден, проверяем старую директорию (для миграции)
    if [ -z "$SCRIPT_PATH" ]; then
        for s in "$INITD_DIR"/S*"$COMPONENT"*; do
            if [ -f "$s" ]; then
                SCRIPT_PATH="$s"
                break
            fi
        done
    fi

    if [ -z "$SCRIPT_PATH" ]; then
        log_error "Ошибка: init-скрипт sing-box не найден в ${ALLOW_INITD_DIR} или ${INITD_DIR}."
        return 1
    fi

    log "Запускаю sing-box через ${SCRIPT_PATH}."
    if sh "$SCRIPT_PATH" start >>"$LOG_FILE" 2>&1; then
        log "sing-box запущен (инициализация init-скрипта успешна)."
        return 0
    else
        log_error "Ошибка: не удалось запустить sing-box через init-скрипт."
        return 1
    fi
}

install_sing_box() {
    log "=== УСТАНОВКА ${COMPONENT} ==="
    log "Платформа: ${PLATFORM}"

    detect_opkg_local
    log "Использую opkg: ${OPKG_BIN}"

    # Список пакетов, которые поставили мы (для корректного uninstall)
    MANAGED_PKGS=""

    # Проверяем, установлен ли уже пакет
    if "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^${PKG_NAME_SING_BOX} "; then
        log "Пакет ${PKG_NAME_SING_BOX} уже установлен, пропускаю установку пакета."
    else
        # Обновляем список пакетов перед установкой
        log "Обновляю список пакетов opkg..."
        if "$OPKG_BIN" update >>"$LOG_FILE" 2>&1; then
            log "Список пакетов обновлен."
        else
            log "Предупреждение: не удалось обновить список пакетов (продолжаем установку)."
        fi
        log "Устанавливаю пакет ${PKG_NAME_SING_BOX}..."
        if "$OPKG_BIN" install "${PKG_NAME_SING_BOX}" >>"$LOG_FILE" 2>&1; then
            log_success "Пакет ${PKG_NAME_SING_BOX} успешно установлен."
            MANAGED_PKGS="${PKG_NAME_SING_BOX}"
        else
            log_error "Ошибка: не удалось установить пакет ${PKG_NAME_SING_BOX}."
            exit 1
        fi
    fi

    # Копируем конфиги из NEED_DIR
    if [ -d "${NEED_DIR}/etc" ]; then
        log "Копирую конфиги из ${NEED_DIR}/etc в ${CONF_DIR}."
        cp -f "${NEED_DIR}/etc/"* "$CONF_DIR"/ 2>>"$LOG_FILE" || {
            log_error "Ошибка: не удалось скопировать конфиги."
            exit 1
        }
    else
        log_error "Ошибка: директория ${NEED_DIR}/etc не найдена, конфиги не будут скопированы."
        exit 1
    fi

    if [ -d "${NEED_DIR}/init.d" ]; then
        # Удаляем системные init-скрипты sing-box (если есть), чтобы не было конфликтов
        log "Удаляю системные init-скрипты sing-box (если есть)..."
        for sys_script in "$INITD_DIR"/S*"$COMPONENT"* "$INITD_DIR"/K*"$COMPONENT"*; do
            if [ -f "$sys_script" ] && ! grep -q "/opt/etc/allow/sing-box" "$sys_script" 2>/dev/null; then
                log "Удаляю системный init-скрипт: $sys_script"
                rm -f "$sys_script"
            fi
        done
        
        # Создаем директорию для скриптов компонентов
        mkdir -p "$ALLOW_INITD_DIR" 2>/dev/null || {
            log_error "Ошибка: не удалось создать директорию ${ALLOW_INITD_DIR}"
            exit 1
        }
        
        log "Копирую init-скрипты из ${NEED_DIR}/init.d в ${ALLOW_INITD_DIR}."
        cp -f "${NEED_DIR}/init.d/"* "$ALLOW_INITD_DIR"/ 2>>"$LOG_FILE" || {
            log_error "Ошибка: не удалось скопировать init-скрипты."
            exit 1
        }
        chmod +x "${ALLOW_INITD_DIR}"/S*"$COMPONENT"* 2>/dev/null || true

        # Нормализуем окончания строк (CRLF -> LF)
        for s in "${ALLOW_INITD_DIR}"/S*"$COMPONENT"*; do
            if [ -f "$s" ]; then
                sed -i 's/\r$//' "$s" 2>/dev/null || true
            fi
        done
    else
        log_error "Ошибка: директория ${NEED_DIR}/init.d не найдена, init-скрипты не будут скопированы."
        exit 1
    fi

    # Копируем ndm netfilter хуки (если есть)
    if [ -d "${NEED_DIR}/netfilter.d" ]; then
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
        log "Предупреждение: директория ${NEED_DIR}/netfilter.d не найдена, хуки ndm не будут скопированы."
    fi

    # Если S01allow установлен, используем его для запуска и проверки
    if [ -x "${INITD_DIR}/S01allow" ]; then
        log "S01allow обнаружен, запускаю компонент через S01allow..."
        if sh "${INITD_DIR}/S01allow" start >>"$LOG_FILE" 2>&1; then
            log_success "Компонент запущен через S01allow."
        else
            if ! ask_user_on_error "Ошибка: не удалось запустить компонент через S01allow." "${COMPONENT}"; then
                log "Пользователь выбрал откат установки."
                uninstall_sing_box
                return 1
            else
                log "Пользователь выбрал продолжить установку."
                return 1
            fi
        fi
        
        # Проверяем статус через S01allow
        log "Проверяю статус компонента через S01allow..."
        sleep 2
        if sh "${INITD_DIR}/S01allow" status >>"$LOG_FILE" 2>&1; then
            log_success "Проверка статуса через S01allow успешна."
        else
            if ! ask_user_on_error "Ошибка: проверка статуса через S01allow не прошла." "${COMPONENT}"; then
                log "Пользователь выбрал откат установки."
                uninstall_sing_box
                return 1
            else
                log "Пользователь выбрал продолжить установку."
                return 1
            fi
        fi
    else
        # Запускаем сервис напрямую (если S01allow не установлен)
        if ! start_sing_box; then
            if ! ask_user_on_error "Ошибка: запуск sing-box не удался." "${COMPONENT}"; then
                log "Пользователь выбрал откат установки."
                uninstall_sing_box
                return 1
            else
                log "Пользователь выбрал продолжить установку."
                return 1
            fi
        fi

        # Проверяем процесс
        sleep 2
        if [ -n "$(get_sing_box_pids)" ]; then
            log_success "Процесс sing-box найден, установка успешна."
        else
            if ! ask_user_on_error "Ошибка: процесс sing-box не найден после установки." "${COMPONENT}"; then
                log "Пользователь выбрал откат установки."
                uninstall_sing_box
                return 1
            else
                log "Пользователь выбрал продолжить установку."
                return 1
            fi
        fi
    fi

    # Сохраняем состояние (установлено + какие пакеты ставили мы)
    state_set "$STATE_KEY_PKGS" "$MANAGED_PKGS"
    state_set "$STATE_KEY_INSTALLED" "$(date '+%Y-%m-%d %H:%M:%S')"

    log_success "=== УСТАНОВКА ${COMPONENT} ЗАВЕРШЕНА УСПЕШНО ==="
}

check_sing_box() {
    log "=== ПРОВЕРКА ${COMPONENT} ==="

    if [ -n "$(get_sing_box_pids)" ]; then
        log_success "Процесс sing-box работает."
        log_success "=== ПРОВЕРКА ${COMPONENT}: OK ==="
        exit 0
    else
        log_error "Процесс sing-box не найден."
        log_error "=== ПРОВЕРКА ${COMPONENT}: НЕИСПРАВНО ==="
        exit 1
    fi
}

uninstall_sing_box() {
    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT} ==="

    # Проверка состояния установки (если не FORCE)
    if [ "${FORCE:-0}" != "1" ]; then
        if ! state_has "$STATE_KEY_INSTALLED"; then
            log "Компонент ${COMPONENT} не установлен (файл состояния не найден), пропускаю деинсталляцию."
            return 0
        fi
    fi

    detect_opkg_local

    # Функция для мягкой остановки процесса с проверкой
    # Функция для мягкой остановки процесса с проверкой (без pkill, используем kill по PID)
    stop_process_gracefully() {
        # PATTERN оставлен для совместимости вызова, но не используется намеренно
        # (иначе рискуем матчить на sing-box.sh/install_all.sh и убить деинсталлятор).
        PATTERN="$1"
        NAME="$2"
        MAX_WAIT="${3:-5}"
        
        # Находим PID'ы только реального sing-box
        PIDS="$(get_sing_box_pids)"
        
        if [ -z "$PIDS" ]; then
            return 0  # Процесс уже не запущен
        fi
        
        log "Останавливаю процессы $NAME (PIDs: $PIDS)..."
        
        # Останавливаем все найденные процессы
        for PID in $PIDS; do
            # Защита от самострела
            [ -z "$PID" ] && continue
            [ "$PID" = "$$" ] && continue
            [ -n "${PPID:-}" ] && [ "$PID" = "$PPID" ] && continue
            kill "$PID" 2>/dev/null || true
        done
        
        # Ждем остановки с проверками
        WAIT_COUNT=0
        while [ "$WAIT_COUNT" -lt "$MAX_WAIT" ]; do
            REMAINING_PIDS="$(get_sing_box_pids)"
            if [ -z "$REMAINING_PIDS" ]; then
                log "Процессы $NAME успешно остановлены."
                return 0
            fi
            sleep 1
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done
        
        # Если не остановились, принудительно
        REMAINING_PIDS="$(get_sing_box_pids)"
        if [ -n "$REMAINING_PIDS" ]; then
            log "Процессы $NAME (PIDs: $REMAINING_PIDS) не остановились, принудительное завершение..."
            for PID in $REMAINING_PIDS; do
                # Защита от самострела
                [ -z "$PID" ] && continue
                [ "$PID" = "$$" ] && continue
                [ -n "${PPID:-}" ] && [ "$PID" = "$PPID" ] && continue
                kill -9 "$PID" 2>/dev/null || true
            done
            sleep 1
            FINAL_PIDS="$(get_sing_box_pids)"
            if [ -n "$FINAL_PIDS" ]; then
                log_error "Предупреждение: не удалось полностью остановить процессы $NAME (PIDs: $FINAL_PIDS)"
                log "Продолжаю деинсталляцию несмотря на предупреждение."
                # Не возвращаем ошибку, чтобы не блокировать деинсталляцию
            else
                log "Процессы $NAME принудительно остановлены."
            fi
        fi
        
        return 0
    }
    
    # Останавливаем все процессы sing-box
    stop_process_gracefully "sing-box" "sing-box" 5

    # Останавливаем сервис через init-скрипт
    stop_sing_box || true

    # Снимаем firewall-правила (zapret-style), если init-скрипт доступен
    if [ -x "${ALLOW_INITD_DIR}/S98sing-box" ]; then
        log "Снимаю firewall правила через ${ALLOW_INITD_DIR}/S98sing-box stop-fw."
        sh "${ALLOW_INITD_DIR}/S98sing-box" stop-fw >>"$LOG_FILE" 2>&1 || true
    elif [ -x "${INITD_DIR}/S98sing-box" ]; then
        log "Снимаю firewall правила через ${INITD_DIR}/S98sing-box stop-fw (старая директория)."
        sh "${INITD_DIR}/S98sing-box" stop-fw >>"$LOG_FILE" 2>&1 || true
    fi

    # Удаляем TUN интерфейс, если он существует
    if ip link show sbtun0 >/dev/null 2>&1; then
        log "Удаляю TUN интерфейс sbtun0..."
        ip link set sbtun0 down 2>/dev/null || true
        ip tuntap del mode tun sbtun0 2>/dev/null || true
    fi

    # Удаляем ndm netfilter хуки
    if [ -d "$NDM_DIR" ]; then
        log "Удаляю ndm netfilter хуки..."
        # Единый хук: 000-sing-box.sh (делегирует в S98sing-box restart-fw).
        # Также чистим старые хуки (на случай обновления со старых версий).
        for hook in "$NDM_DIR"/000-sing-box.sh "$NDM_DIR"/*"sing-box"* "$NDM_DIR"/iptun.sh "$NDM_DIR"/010-sbtun0-mark.sh; do
            if [ -f "$hook" ]; then
                HOOK_NAME=$(basename "$hook")
                log "Удаляю правила iptables для ${HOOK_NAME}..."
                sh "$hook" stop >>"$LOG_FILE" 2>&1 || true
                log "Удаляю хук ${HOOK_NAME}..."
                rm -f "$hook"
            fi
        done
    fi

    # Удаляем пакет только если мы его устанавливали
    PKGS="$(state_get "$STATE_KEY_PKGS")"
    if state_list_contains_word "$PKGS" "$PKG_NAME_SING_BOX"; then
        if "$OPKG_BIN" list-installed 2>/dev/null | grep -q "^${PKG_NAME_SING_BOX} "; then
            log "Удаляю пакет ${PKG_NAME_SING_BOX}..."
            if "$OPKG_BIN" remove "${PKG_NAME_SING_BOX}" >>"$LOG_FILE" 2>&1; then
                log_success "Пакет ${PKG_NAME_SING_BOX} удалён."
            else
                log_error "Ошибка: не удалось удалить пакет ${PKG_NAME_SING_BOX}."
            fi
        else
            log "Пакет ${PKG_NAME_SING_BOX} не установлен, пропускаю удаление пакета."
        fi
    else
        log "Пакет ${PKG_NAME_SING_BOX} установлен вне инсталятора Allow, не удаляем."
    fi

    # Удаляем конфиги
    if [ -d "$CONF_DIR" ]; then
        log "Удаляю конфиги в ${CONF_DIR}."
        rm -rf "$CONF_DIR"
    fi

    # Удаляем init-скрипты из ALLOW_INITD_DIR
    FOUND_INIT=0
    for s in "$ALLOW_INITD_DIR"/S*"$COMPONENT"* "$ALLOW_INITD_DIR"/K*"$COMPONENT"*; do
        if [ -f "$s" ]; then
            FOUND_INIT=1
            log "Удаляю init-скрипт ${s}."
            rm -f "$s"
        fi
    done
    # Также проверяем старую директорию на случай миграции
    for s in "$INITD_DIR"/S*"$COMPONENT"* "$INITD_DIR"/K*"$COMPONENT"*; do
        if [ -f "$s" ]; then
            FOUND_INIT=1
            log "Удаляю init-скрипт ${s} (старая директория)."
            rm -f "$s"
        fi
    done
    if [ "$FOUND_INIT" -eq 0 ]; then
        log "Init-скрипты sing-box не найдены или уже удалены."
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
        # Убираем автоматическую деинсталляцию - теперь пользователь решает сам
        # trap обработчик не нужен, так как все ошибки обрабатываются явно через ask_user_on_error
        install_sing_box
        ;;
    uninstall)
        uninstall_sing_box
        ;;
    check)
        check_sing_box
        ;;
    *)
        echo "Использование: $0 {install|uninstall|check}" >&2
        exit 1
        ;;
esac

