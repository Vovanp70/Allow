#!/bin/sh

# Общий установщик/оркестратор компонентов ALLOW
# Предназначен для размещения на роутере как /opt/tmp/allow/install_all.sh
# После успешной установки временная директория /opt/tmp/allow будет удалена

# Используем более гибкую обработку ошибок вместо set -e
# set -e может прервать выполнение в неподходящий момент (например, в функциях отката)
set +e

# Определение директорий скрипта
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALL_D_DIR="${SCRIPT_DIR}/install.d"

# Проверка корректности определения директорий
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR" ]; then
    echo "Ошибка: не удалось определить директорию скрипта." >&2
    exit 1
fi

# Единый файл состояния (вместо /opt/etc/allow/state/*.installed)
STATE_DB="/opt/etc/allow/state.db"
STATE_LIB="${INSTALL_D_DIR}/state_lib.sh"
if [ -f "$STATE_LIB" ]; then
    . "$STATE_LIB"
else
    echo "Ошибка: не найден модуль состояния: $STATE_LIB" >&2
    exit 1
fi

# --- Вывод в стиле [ALLOW]: информационные сообщения, предупреждения, ошибки ---
# Цвета только при TTY (многие роутеры — без полноценного терминала)
allow_use_color() {
    [ -t 1 ] 2>/dev/null && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]
}
allow_info()  { printf '[ALLOW] %s\n' "$*"; }
allow_warn()  { if allow_use_color; then printf '\033[33m[ALLOW] [WARN] %s\033[0m\n' "$*"; else printf '[ALLOW] [WARN] %s\n' "$*"; fi >&2; }
allow_err()   { if allow_use_color; then printf '\033[31m[ALLOW] [ERR] %s\033[0m\n' "$*"; else printf '[ALLOW] [ERR] %s\n' "$*"; fi >&2; }
allow_stage() { printf '\n============================================================\n[ALLOW] === %s ===\n============================================================\n' "$*"; }
allow_comp()  { printf '[ALLOW] >> %s\n' "$*"; }
allow_ok()    { if allow_use_color; then printf '\033[32m[ALLOW] %s: OK\033[0m\n' "$*"; else printf '[ALLOW] %s: OK\n' "$*"; fi; }
allow_skip()  { printf '[ALLOW] %s: SKIP\n' "$*"; }
allow_fail()  { if allow_use_color; then printf '\033[31m[ALLOW] %s: FAIL\033[0m\n' "$*"; else printf '[ALLOW] %s: FAIL\n' "$*"; fi >&2; }

# Поиск директории resources/ для компонента
# Ищет в нескольких возможных местах: относительно SCRIPT_DIR, в /opt/tmp/allow, в /opt/etc/allow/install
find_resources_directory() {
    COMPONENT="$1"
    
    # Список возможных мест для поиска
    SEARCH_PATHS=""
    
    # 1. Относительно SCRIPT_DIR (если скрипт в /opt/tmp/allow или /opt/etc/allow/install)
    if [ -d "${SCRIPT_DIR}/resources/${COMPONENT}" ]; then
        echo "${SCRIPT_DIR}/resources/${COMPONENT}"
        return 0
    fi
    
    # 2. В родительской директории SCRIPT_DIR (если SCRIPT_DIR = /opt/tmp/allow/install.d)
    PARENT_DIR="$(dirname "$SCRIPT_DIR")"
    if [ -d "${PARENT_DIR}/resources/${COMPONENT}" ]; then
        echo "${PARENT_DIR}/resources/${COMPONENT}"
        return 0
    fi
    
    # 3. В /opt/tmp/allow/resources (стандартное место для временной установки)
    if [ -d "/opt/tmp/allow/resources/${COMPONENT}" ]; then
        echo "/opt/tmp/allow/resources/${COMPONENT}"
        return 0
    fi
    
    # 4. В /opt/etc/allow/install/resources (постоянное место)
    if [ -d "/opt/etc/allow/install/resources/${COMPONENT}" ]; then
        echo "/opt/etc/allow/install/resources/${COMPONENT}"
        return 0
    fi
    
    # 5. В /opt/allow/resources (старое место)
    if [ -d "/opt/allow/resources/${COMPONENT}" ]; then
        echo "/opt/allow/resources/${COMPONENT}"
        return 0
    fi
    
    # Не найдено
    return 1
}

# Определяем opkg и тип платформы (Entware / OpenWrt)
detect_opkg() {
    if [ -x /opt/bin/opkg ]; then
        OPKG_BIN="/opt/bin/opkg"
        PLATFORM="entware"
        return 0
    elif [ -x /bin/opkg ]; then
        OPKG_BIN="/bin/opkg"
        PLATFORM="openwrt"
        return 0
    elif [ -x /usr/bin/opkg ]; then
        OPKG_BIN="/usr/bin/opkg"
        PLATFORM="openwrt"
        return 0
    else
        allow_err "opkg не найден. Ожидалось: /opt/bin/opkg или /bin/opkg. Проверьте установку."
        return 1
    fi
}

usage() {
    cat <<EOF
Использование:
  $0 <компонент> <действие>
  $0 <действие>              (для всех компонентов)

Компонент:
  dependencies                Обязательные зависимости (tcpdump, curl, dig)
  curl-http3                 Установка curl с поддержкой HTTP/3 (QUIC)
  stubby                     Управление компонентом stubby (DoT)
  dnsmasq-full               Управление компонентом dnsmasq-full
  sing-box                   Управление компонентом sing-box (proxy через TUN)
  markalltovpn               Маршрутизация по марке (route-by-mark, NDM netfilter)
  monitor                    Веб-интерфейс мониторинга компонентов
  allow                      Единый скрипт автозапуска всех компонентов (S01allow)
  logrotate                  Ротация логов компонентов ALLOW (cron + лимит по размеру)

Действие:
  install                     Установка компонента(ов)
  uninstall                   Полная деинсталляция компонента(ов)
  force-uninstall             Принудительная деинсталляция (игнорирует состояние установки)
  check                       Проверка работоспособности компонента(ов)

Примеры:
  $0 dependencies install
  $0 dnsmasq-full install
  $0 dnsmasq-full check
  $0 dnsmasq-full uninstall
  $0 install                  (установить все компоненты)
  $0 uninstall                (удалить все компоненты)
  $0 force-uninstall           (принудительно удалить все компоненты, игнорируя состояние)

Если запустить без аргументов, будут последовательно установлены все поддерживаемые компоненты.
EOF
}

# Проверка существования скрипта компонента
check_component_script() {
    COMPONENT="$1"
    SCRIPT="${INSTALL_D_DIR}/${COMPONENT}.sh"
    
    if [ ! -f "$SCRIPT" ]; then
        allow_err "Сценарий компонента не найден: $SCRIPT"
        return 1
    fi
    if [ ! -x "$SCRIPT" ]; then
        chmod +x "$SCRIPT" 2>/dev/null || allow_warn "Не удалось chmod +x для $SCRIPT"
    fi
    
    return 0
}

# Запуск скрипта компонента
run_component() {
    COMPONENT="$1"
    ACTION="$2"
    FORCE_PARAM="${3:-0}"
    SCRIPT="${INSTALL_D_DIR}/${COMPONENT}.sh"

    # Проверяем наличие скрипта
    if ! check_component_script "$COMPONENT"; then
        return 1
    fi

    # Определяем NEED_DIR для компонента (только для действий, которые могут его использовать)
    NEED_DIR_VAR=""
    
    # Список компонентов, которые не требуют resources директорию
    COMPONENTS_WITHOUT_NEED="dependencies curl-http3 logrotate"
    
    if [ "$ACTION" = "install" ] || [ "$ACTION" = "install-family" ]; then
        # Проверяем, требуется ли resources директория для этого компонента
        NEED_REQUIRED=1
        for comp_no_need in $COMPONENTS_WITHOUT_NEED; do
            if [ "$COMPONENT" = "$comp_no_need" ]; then
                NEED_REQUIRED=0
                break
            fi
        done
        
        if [ "$NEED_REQUIRED" = "1" ]; then
            if NEED_DIR_FOUND=$(find_resources_directory "$COMPONENT" 2>/dev/null); then
                NEED_DIR_VAR="$NEED_DIR_FOUND"
            else
                allow_warn "resources/${COMPONENT} не найдена, установка может завершиться с ошибкой."
            fi
        fi
    fi

    allow_comp "компонент: ${COMPONENT} | действие: ${ACTION}"
    
    # Передаем параметры через переменные окружения и аргументы
    # Компоненты ожидают: $1=ACTION, $2=PLATFORM
    # FORCE передается через переменную окружения FORCE для компонентов, которые его используют
    # OPKG_BIN передается через переменную окружения, чтобы компоненты не дублировали логику определения
    # NEED_DIR передается через переменную окружения для решения проблемы с запуском из разных директорий
    if [ -n "$NEED_DIR_VAR" ]; then
        PLATFORM="$PLATFORM_ARG" OPKG_BIN="$OPKG_BIN" FORCE="$FORCE_PARAM" NEED_DIR="$NEED_DIR_VAR" sh "$SCRIPT" "$ACTION" "$PLATFORM_ARG"
    else
        PLATFORM="$PLATFORM_ARG" OPKG_BIN="$OPKG_BIN" FORCE="$FORCE_PARAM" sh "$SCRIPT" "$ACTION" "$PLATFORM_ARG"
    fi
}

detect_platform() {
    PLATFORM_ARG="entware"

    if [ -x "${SCRIPT_DIR}/detect_system.sh" ]; then
        DETECT_OUTPUT=$(sh "${SCRIPT_DIR}/detect_system.sh" 2>/dev/null || true)

        # Извлекаем SYSTEM и признак Entware
        DETECT_SYSTEM=$(echo "$DETECT_OUTPUT" | grep '^SYSTEM=' | tail -1 | cut -d= -f2)
        if echo "$DETECT_OUTPUT" | grep -q 'ENTWARE=да'; then
            PLATFORM_ARG="entware"
        elif [ -n "$DETECT_SYSTEM" ]; then
            PLATFORM_ARG="$DETECT_SYSTEM"
            allow_warn "Платформа '$PLATFORM_ARG', поддержка вне Entware экспериментальная."
        else
            PLATFORM_ARG="generic"
            allow_warn "Платформа не определена, используем 'generic'."
        fi
    else
        PLATFORM_ARG="entware"
        [ ! -f "${SCRIPT_DIR}/detect_system.sh" ] && allow_info "detect_system.sh не найден, платформа: $PLATFORM_ARG"
    fi
}

# Копируем установочные скрипты в постоянное место,
# чтобы деинсталляция была доступна после удаления /opt/tmp/allow
ensure_persistent_install_scripts() {
    PERSIST_DIR="/opt/etc/allow/install"

    # Если мы уже запущены из постоянного места, копирование не требуется
    if [ "$SCRIPT_DIR" = "$PERSIST_DIR" ] || [ "$SCRIPT_DIR" = "${PERSIST_DIR}/" ]; then
        return 0
    fi
    
    if ! mkdir -p "$PERSIST_DIR" 2>/dev/null; then
        allow_warn "Не удалось создать $PERSIST_DIR, деинсталляция может быть недоступна."
        return 0
    fi
    [ -f "$SCRIPT_DIR/install_all.sh" ] && ! cp -f "$SCRIPT_DIR/install_all.sh" "$PERSIST_DIR/" 2>/dev/null && allow_warn "Не удалось скопировать install_all.sh в $PERSIST_DIR"
    [ -f "$SCRIPT_DIR/detect_system.sh" ] && ! cp -f "$SCRIPT_DIR/detect_system.sh" "$PERSIST_DIR/" 2>/dev/null && allow_warn "Не удалось скопировать detect_system.sh"
    if [ -f "$SCRIPT_DIR/setsettings.sh" ]; then
        if cp -f "$SCRIPT_DIR/setsettings.sh" "$PERSIST_DIR/" 2>/dev/null; then chmod +x "$PERSIST_DIR/setsettings.sh" 2>/dev/null || true; else allow_warn "Не удалось скопировать setsettings.sh"; fi
    fi
    if [ "$SCRIPT_DIR" != "$PERSIST_DIR" ] && [ -d "$SCRIPT_DIR/install.d" ]; then
        if ! mkdir -p "$PERSIST_DIR/install.d" 2>/dev/null; then allow_warn "Не удалось создать $PERSIST_DIR/install.d"; return 0; fi
        if ! cp -R "$SCRIPT_DIR/install.d"/*.sh "$PERSIST_DIR/install.d/" 2>/dev/null; then
            COPY_COUNT=0
            for script in "$SCRIPT_DIR/install.d"/*.sh; do [ -f "$script" ] && cp -f "$script" "$PERSIST_DIR/install.d/" 2>/dev/null && COPY_COUNT=$((COPY_COUNT + 1)); done
            [ "$COPY_COUNT" -eq 0 ] && allow_warn "Не удалось скопировать скрипты в install.d"
        fi
        chmod +x "$PERSIST_DIR/install.d"/*.sh 2>/dev/null || true
    fi
}

run_all_default_install() {
    # Сохраняем текущий dns-proxy filter engine до любых DNS-изменений (до Этапа 0).
    # После установки вернём engine в исходное значение.
    if [ -f "${SCRIPT_DIR}/setsettings.sh" ]; then
        PREINSTALL_ENGINE="$(sh "${SCRIPT_DIR}/setsettings.sh" print-engine 2>/dev/null | awk 'NF{print $1; exit}' 2>/dev/null)"
        if [ -n "${PREINSTALL_ENGINE:-}" ]; then
            state_set "dns.engine.preinstall" "$PREINSTALL_ENGINE" || true
            allow_info "Сохранён dns-proxy filter engine до установки: $PREINSTALL_ENGINE"
        fi
    fi

    # Список компонентов для установки в порядке установки
    # Временно отключены: curl-http3
    COMPONENTS="dependencies stubby dnsmasq-full sing-box markalltovpn monitor allow logrotate"
    INSTALLED_COMPONENTS=""
    HAS_FAMILY_STUBBY=0
    HAS_FAMILY_DNSMASQ=0
    INSTALL_OK_COUNT=0
    INSTALL_FAIL_COUNT=0
    INSTALL_RESULTS=""
    
    # Флаг для предотвращения повторного вызова отката
    ROLLBACK_DONE=0
    
    # Функция для отката всех установленных компонентов
    rollback_installation() {
        # Предотвращаем повторный вызов
        if [ "$ROLLBACK_DONE" = "1" ]; then
            return 0
        fi
        ROLLBACK_DONE=1

        if [ -f "${SCRIPT_DIR}/setsettings.sh" ]; then
            PREINSTALL_ENGINE="$(state_get "dns.engine.preinstall")"
            if [ -n "${PREINSTALL_ENGINE:-}" ]; then
                allow_info "Восстанавливаю dns-proxy filter engine: $PREINSTALL_ENGINE"
                SOFT=1 sh "${SCRIPT_DIR}/setsettings.sh" set-engine "$PREINSTALL_ENGINE" >/dev/null 2>&1 || true
            fi
        fi
        
        if [ -n "$INSTALLED_COMPONENTS" ] || [ "$HAS_FAMILY_STUBBY" = "1" ] || [ "$HAS_FAMILY_DNSMASQ" = "1" ]; then
            allow_err "ОШИБКА УСТАНОВКИ!"
            
            DO_ROLLBACK=0
            if [ -t 0 ] && [ -t 1 ]; then
                allow_warn "Были установлены: dnsmasq-family stubby-family $INSTALLED_COMPONENTS"
                printf '[ALLOW] Выбор: 1) Откатить всё  2) Оставить установленное [1/2]: ' >&2
                read -r choice
                case "$choice" in
                    1|rollback|откат)   DO_ROLLBACK=1 ;;
                    2|continue|продолжить) DO_ROLLBACK=0 ;;
                    *) allow_warn "Неверный выбор, оставляю установленное."; DO_ROLLBACK=0 ;;
                esac
            else
                allow_info "Неинтерактивный режим: оставляю установленные компоненты."
                DO_ROLLBACK=0
            fi
            
            if [ "$DO_ROLLBACK" = "1" ]; then
                allow_info "Выполняю откат..."
                if [ "$HAS_FAMILY_DNSMASQ" = "1" ]; then run_component "dnsmasq-full" "uninstall-family" "0" || true; fi
                if [ "$HAS_FAMILY_STUBBY" = "1" ]; then run_component "stubby" "uninstall-family" "0" || true; fi
                REVERSE_COMPONENTS=""
                for comp in $INSTALLED_COMPONENTS; do REVERSE_COMPONENTS="$comp $REVERSE_COMPONENTS"; done
                for comp in $REVERSE_COMPONENTS; do
                    [ -z "$comp" ] && continue
                    run_component "$comp" "uninstall" "0" || true
                done
            else
                allow_info "Установленные компоненты оставлены без изменений."
            fi
        fi
    }
    
    # Устанавливаем обработчик ошибок для отката (только для интерактивного запроса)
    # trap rollback_installation EXIT
    # Теперь откат происходит только по выбору пользователя, не автоматически
    
    allow_stage "Установка компонентов"
    for comp in $COMPONENTS; do
        printf '\n============================================================\n'
        if run_component "$comp" "install" "0"; then
            if state_has "installed.${comp}"; then
                INSTALLED_COMPONENTS="$INSTALLED_COMPONENTS $comp"
                allow_ok "$comp"
                INSTALL_OK_COUNT=$((INSTALL_OK_COUNT + 1))
            else
                allow_warn "компонент $comp установлен, но состояние не записано."
                INSTALLED_COMPONENTS="$INSTALLED_COMPONENTS $comp"
                allow_ok "$comp"
                INSTALL_OK_COUNT=$((INSTALL_OK_COUNT + 1))
            fi
            if [ "$comp" = "stubby" ] && state_has "installed.stubby-family"; then HAS_FAMILY_STUBBY=1; fi
            if [ "$comp" = "dnsmasq-full" ] && state_has "installed.dnsmasq-full-family"; then HAS_FAMILY_DNSMASQ=1; fi
        else
            allow_fail "$comp"
            INSTALL_FAIL_COUNT=$((INSTALL_FAIL_COUNT + 1))
            if state_has "installed.${comp}"; then
                INSTALLED_COMPONENTS="$INSTALLED_COMPONENTS $comp"
                allow_warn "файл состояния для $comp найден, включён в откат."
            fi
        fi
    done
    
    # DNS mode: stable — после установки обоих dnsmasq и allow
    DNS_MODE_SCRIPT="/opt/etc/allow/manage.d/keenetic-entware/dns-mode.sh"
    if state_has "installed.stubby" && state_has "installed.dnsmasq-full" && [ -x "$DNS_MODE_SCRIPT" ]; then
        allow_stage "DNS mode: stable"
        if ETC_ALLOW=/opt/etc/allow "$DNS_MODE_SCRIPT" set stable; then
            allow_ok "dns-mode set stable"
        else
            allow_warn "dns-mode set stable завершился с ошибкой (продолжаем)."
        fi
    fi

    # Активация init-скриптов (X -> S) для установленных компонентов
    if [ -x "/opt/etc/allow/manage.d/keenetic-entware/autostart.sh" ]; then
        for comp in stubby stubby-family dnsmasq-full dnsmasq-full-family sing-box monitor; do
            if state_has "installed.${comp}"; then
                if /opt/etc/allow/manage.d/keenetic-entware/autostart.sh "$comp" activate >>/dev/null 2>&1; then
                    : # уже активен или активирован
                fi
            fi
        done
    fi
    
    allow_stage "Итоги установки"
    printf '[ALLOW] OK: %s  FAIL: %s\n' "$INSTALL_OK_COUNT" "$INSTALL_FAIL_COUNT"
    if [ "$INSTALL_FAIL_COUNT" -gt 0 ]; then
        allow_warn "Установка завершена с ошибками ($INSTALL_FAIL_COUNT компонентов)."
    else
        allow_info "Установка компонентов завершена успешно."
    fi
    
    # Убираем обработчик ошибок после успешной установки (если он был установлен)
    # trap - EXIT

    if [ -f "${SCRIPT_DIR}/setsettings.sh" ]; then
        allow_stage "Финальный этап: DNS apply"
        SOFT=1 sh "${SCRIPT_DIR}/setsettings.sh" apply || true
        PREINSTALL_ENGINE="$(state_get "dns.engine.preinstall")"
        if [ -n "${PREINSTALL_ENGINE:-}" ]; then
            allow_info "Восстановление dns-proxy filter engine: $PREINSTALL_ENGINE"
            SOFT=1 sh "${SCRIPT_DIR}/setsettings.sh" set-engine "$PREINSTALL_ENGINE" || true
            state_unset "dns.engine.preinstall" || true
        fi
    fi

    # Выводим финальное предупреждение с инструкциями
    show_final_warning
    
    # Удаляем временную директорию /opt/allow после успешной установки
    cleanup_temp_directory
}

# Определение временной директории установки
is_temp_directory() {
    DIR="$1"
    # Проверяем, является ли директория временной (содержит install.d и находится в /opt/tmp или /opt/allow)
    if [ -d "$DIR" ] && [ -d "$DIR/install.d" ]; then
        case "$DIR" in
            /opt/tmp/allow|/opt/tmp/allow/*|/opt/allow|/opt/allow/*)
                return 0
                ;;
            *)
                return 1
                ;;
        esac
    fi
    return 1
}

# Определение постоянной директории установки
is_persistent_directory() {
    DIR="$1"
    # Постоянная директория - это /opt/etc/allow/install
    [ "$DIR" = "/opt/etc/allow/install" ] || [ "$DIR" = "/opt/etc/allow/install/" ]
}

cleanup_temp_directory() {
    allow_stage "Удаление временной директории установки"
    if is_persistent_directory "$SCRIPT_DIR"; then
        allow_info "Установка из постоянного места, пропускаю удаление."
        return 0
    fi
    TEMP_DIR=""
    if is_temp_directory "$SCRIPT_DIR"; then TEMP_DIR="$SCRIPT_DIR"
    elif echo "$SCRIPT_DIR" | grep -q "^/opt/tmp/allow"; then TEMP_DIR="/opt/tmp/allow"
    elif echo "$SCRIPT_DIR" | grep -q "^/opt/allow"; then TEMP_DIR="/opt/allow"
    fi
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        if is_temp_directory "$TEMP_DIR"; then
            if rm -rf "$TEMP_DIR" 2>/dev/null; then
                allow_info "Временная директория удалена: $TEMP_DIR"
            else
                allow_warn "Не удалось удалить $TEMP_DIR. Вручную: rm -rf $TEMP_DIR"
            fi
        else
            allow_warn "$TEMP_DIR не временная, пропускаю удаление."
        fi
    else
        allow_info "Временная директория не найдена."
    fi
}

# Проверка установки компонента
is_component_installed() {
    COMPONENT="$1"
    state_has "installed.${COMPONENT}"
}

# Проверка установки семейного экземпляра
is_family_instance_installed() {
    COMPONENT="$1"
    case "$COMPONENT" in
        stubby)
            state_has "installed.stubby-family"
            ;;
        dnsmasq-full)
            state_has "installed.dnsmasq-full-family"
            ;;
        *)
            return 1
            ;;
    esac
}

# Проверка наличия установленных компонентов (кроме dependencies)
has_installed_components() {
    COMPONENTS="stubby dnsmasq-full sing-box markalltovpn monitor allow logrotate curl-http3"
    for comp in $COMPONENTS; do
        if state_has "installed.${comp}"; then
            return 0
        fi
    done
    return 1
}

# Путь к init-скрипту компонента (S или X). Печатает путь в stdout, код возврата 0 если найден.
get_init_script_path() {
    KEY="$1"
    ALLOW_INITD="/opt/etc/allow/init.d"
    INITD="/opt/etc/init.d"
    case "$KEY" in
        stubby) for n in S97stubby X97stubby; do for d in "$ALLOW_INITD" "$INITD"; do [ -x "${d}/${n}" ] && echo "${d}/${n}" && return 0; done; done ;;
        stubby-family) for n in S97stubby-family X97stubby-family; do for d in "$ALLOW_INITD" "$INITD"; do [ -x "${d}/${n}" ] && echo "${d}/${n}" && return 0; done; done ;;
        dnsmasq-full) for n in S98dnsmasq-full X98dnsmasq-full; do for d in "$ALLOW_INITD" "$INITD"; do [ -x "${d}/${n}" ] && echo "${d}/${n}" && return 0; done; done ;;
        dnsmasq-full-family) for n in S98dnsmasq-family X98dnsmasq-family; do for d in "$ALLOW_INITD" "$INITD"; do [ -x "${d}/${n}" ] && echo "${d}/${n}" && return 0; done; done ;;
        *) return 1 ;;
    esac
    return 1
}

# Чтение порта компонента из init-скрипта (status --kv)
read_component_port() {
    KEY="$1"
    DEFAULT="${2:-}"
    SCRIPT="$(get_init_script_path "$KEY")" || true

    if [ -n "${SCRIPT:-}" ] && [ -x "$SCRIPT" ]; then
        PORT="$(sh "$SCRIPT" status --kv 2>/dev/null | awk -F= '$1=="EFFECTIVE_PORT"{print $2; exit}' 2>/dev/null | tr -cd '0-9')"
        if [ -n "${PORT:-}" ]; then
            echo "$PORT"
            return 0
        fi
    fi

    echo "$DEFAULT"
}

show_final_warning() {
    [ ! -f "$STATE_DB" ] && allow_warn "Файл состояния не найден: $STATE_DB"

    STUBBY_PORT=""; DNSMASQ_PORT=""; STUBBY_FAMILY_PORT=""; DNSMASQ_FAMILY_PORT=""
    is_component_installed "stubby" && STUBBY_PORT=$(read_component_port "stubby" "")
    is_component_installed "dnsmasq-full" && DNSMASQ_PORT=$(read_component_port "dnsmasq-full" "")
    STUBBY_FAMILY_PORT=$(read_component_port "stubby-family" "")
    DNSMASQ_FAMILY_PORT=$(read_component_port "dnsmasq-full-family" "")

    allow_stage "Следующие шаги"
    allow_info "1. Остановите системный stubby/DoT в настройках роутера."
    if [ -n "$DNSMASQ_PORT" ]; then
        allow_info "2. У клиентов укажите DNS: 192.168.1.1:$DNSMASQ_PORT"
        allow_info "3. Проверка: dig @127.0.0.1 -p $DNSMASQ_PORT ya.ru +short"
    else
        allow_info "2. DNS: установите dnsmasq-full и укажите порт для клиентов."
    fi
    allow_info "Порты:"
    [ -n "$STUBBY_PORT" ] && allow_info "  stubby 127.0.0.1:$STUBBY_PORT" || allow_info "  stubby —"
    [ -n "$STUBBY_FAMILY_PORT" ] && allow_info "  stubby-family 127.0.0.1:$STUBBY_FAMILY_PORT" || allow_info "  stubby-family —"
    [ -n "$DNSMASQ_PORT" ] && allow_info "  dnsmasq 192.168.1.1:$DNSMASQ_PORT" || allow_info "  dnsmasq —"
    [ -n "$DNSMASQ_FAMILY_PORT" ] && allow_info "  dnsmasq-family 192.168.1.1:$DNSMASQ_FAMILY_PORT" || allow_info "  dnsmasq-family —"
    is_component_installed "sing-box" && allow_info "  sing-box TUN sbtun0 (10.10.0.2/24)"
    printf '\n'
}

run_all_default_uninstall() {
    FORCE="${1:-0}"
    ERROR_COUNT=0
    WARNING_COUNT=0
    UNINSTALL_OK_COUNT=0
    PERSIST_DIR="/opt/etc/allow/install"
    
    if [ "$FORCE" = "1" ]; then
        allow_stage "ПРИНУДИТЕЛЬНАЯ ДЕИНСТАЛЛЯЦИЯ"
        allow_warn "Игнорируется состояние установки, удаляются все компоненты."
    fi

    if [ -x "/opt/etc/init.d/S01allow" ]; then
        allow_stage "Предварительная остановка (S01allow stop)"
        sh "/opt/etc/init.d/S01allow" stop 2>/dev/null || true
    fi
    
    if [ "$FORCE" != "1" ] && has_installed_components; then
        allow_warn "dependencies не удаляется — есть установленные компоненты. Используйте: $0 force-uninstall"
    fi
    
    allow_stage "Этап 1: Удаление семейных экземпляров"
    if is_family_instance_installed "dnsmasq-full" || [ "$FORCE" = "1" ]; then
        run_component "dnsmasq-full" "uninstall-family" "$FORCE" && allow_ok "dnsmasq-family" && UNINSTALL_OK_COUNT=$((UNINSTALL_OK_COUNT + 1)) || { WARNING_COUNT=$((WARNING_COUNT + 1)); allow_fail "dnsmasq-family"; }
    else
        allow_skip "dnsmasq-family"
    fi
    if is_family_instance_installed "stubby" || [ "$FORCE" = "1" ]; then
        run_component "stubby" "uninstall-family" "$FORCE" && allow_ok "stubby-family" && UNINSTALL_OK_COUNT=$((UNINSTALL_OK_COUNT + 1)) || { WARNING_COUNT=$((WARNING_COUNT + 1)); allow_fail "stubby-family"; }
    else
        allow_skip "stubby-family"
    fi
    
    allow_stage "Этап 2: Удаление основных компонентов"
    UNINSTALL_COMPONENTS="logrotate monitor markalltovpn sing-box dnsmasq-full stubby curl-http3 allow"
    for comp in $UNINSTALL_COMPONENTS; do
        if [ "$FORCE" != "1" ] && ! is_component_installed "$comp"; then
            allow_skip "$comp"
            continue
        fi
        if run_component "$comp" "uninstall" "$FORCE"; then
            allow_ok "$comp"
            UNINSTALL_OK_COUNT=$((UNINSTALL_OK_COUNT + 1))
        else
            ERROR_COUNT=$((ERROR_COUNT + 1))
            allow_fail "$comp"
            [ "$FORCE" != "1" ] && exit 1
        fi
    done
    
    allow_stage "Этап 3: Удаление зависимостей"
    if [ "$FORCE" = "1" ] || ! has_installed_components; then
        if [ "$FORCE" != "1" ] && ! is_component_installed "dependencies"; then
            allow_skip "dependencies"
        else
            if run_component "dependencies" "uninstall" "$FORCE"; then
                allow_ok "dependencies"
                UNINSTALL_OK_COUNT=$((UNINSTALL_OK_COUNT + 1))
            else
                ERROR_COUNT=$((ERROR_COUNT + 1))
                allow_fail "dependencies"
                [ "$FORCE" != "1" ] && exit 1
            fi
        fi
    else
        allow_skip "dependencies (оставлен — есть зависимые компоненты)"
    fi

    if [ -f "${SCRIPT_DIR}/setsettings.sh" ]; then
        PREUNINSTALL_ENGINE="$(sh "${SCRIPT_DIR}/setsettings.sh" print-engine 2>/dev/null | awk 'NF{print $1; exit}' 2>/dev/null)"
        [ -n "${PREUNINSTALL_ENGINE:-}" ] && state_set "dns.engine.preuninstall" "$PREUNINSTALL_ENGINE" || true
        allow_stage "Сброс DNS (preset)"
        SOFT=1 sh "${SCRIPT_DIR}/setsettings.sh" preset || true
        PREUNINSTALL_ENGINE="$(state_get "dns.engine.preuninstall")"
        if [ -n "${PREUNINSTALL_ENGINE:-}" ]; then
            allow_info "Восстановление dns-proxy filter engine: $PREUNINSTALL_ENGINE"
            SOFT=1 sh "${SCRIPT_DIR}/setsettings.sh" set-engine "$PREUNINSTALL_ENGINE" || true
            state_unset "dns.engine.preuninstall" || true
        fi
    fi

    allow_stage "Очистка после деинсталляции"
    rm -rf /opt/var/log/allow 2>/dev/null || true
    if [ -d "/opt/etc/allow" ]; then
        [ -d "/opt/etc/allow/state" ] && rm -rf /opt/etc/allow/state 2>/dev/null || true
        [ -f "/opt/etc/allow/state.db" ] && rm -f /opt/etc/allow/state.db 2>/dev/null || true
        for b in /opt/etc/allow/setsettings.backup /opt/etc/allow/setsettings.backup.prev; do [ -f "$b" ] && rm -f "$b" 2>/dev/null || true; done
        [ -d "/opt/etc/allow/init.d" ] && rm -rf /opt/etc/allow/init.d 2>/dev/null || true
        [ -f "/opt/etc/allow/dns_mode" ] && rm -f /opt/etc/allow/dns_mode 2>/dev/null || true
        for comp_dir in /opt/etc/allow/stubby /opt/etc/allow/dnsmasq-full /opt/etc/allow/sing-box /opt/etc/allow/monitor /opt/etc/allow/bin /opt/etc/allow/curl-http3 /opt/etc/allow/manage.d /opt/etc/allow/lists /opt/etc/allow/markalltovpn; do
            [ -d "$comp_dir" ] && rm -rf "$comp_dir" 2>/dev/null || true
        done
        REMAINING_COUNT=0
        REMAINING_LIST=""
        for item in /opt/etc/allow/*; do
            [ -e "$item" ] && [ "$(basename "$item")" != "install" ] && REMAINING_COUNT=$((REMAINING_COUNT + 1)) && REMAINING_LIST="$REMAINING_LIST $(basename "$item")"
        done
        if [ "$FORCE" = "0" ] && [ -d "/opt/etc/allow/install" ]; then
            if [ "$SCRIPT_DIR" = "$PERSIST_DIR" ] || [ "$SCRIPT_DIR" = "${PERSIST_DIR}/" ]; then
                ( sleep 1; rm -rf /opt/etc/allow/install 2>/dev/null || true ) >/dev/null 2>&1 &
            else
                rm -rf /opt/etc/allow/install 2>/dev/null || true
            fi
        fi
        if [ "$REMAINING_COUNT" -eq 0 ]; then
            if [ "$FORCE" = "0" ] && ( [ "$SCRIPT_DIR" = "$PERSIST_DIR" ] || [ "$SCRIPT_DIR" = "${PERSIST_DIR}/" ] ); then
                ( sleep 2; rm -rf /opt/etc/allow 2>/dev/null || true ) >/dev/null 2>&1 &
            else
                rm -rf /opt/etc/allow 2>/dev/null || true
            fi
        else
            allow_warn "В /opt/etc/allow остались: $REMAINING_LIST"
        fi
    fi
    [ -d "/opt/allow/state" ] && rm -rf /opt/allow/state 2>/dev/null || true
    if [ "$FORCE" = "1" ]; then
        [ -d "/opt/etc/allow" ] && rm -rf /opt/etc/allow 2>/dev/null || true
        [ -d "/opt/var/log/allow" ] && rm -rf /opt/var/log/allow 2>/dev/null || true
        allow_info "Принудительная очистка завершена."
    fi
    
    allow_stage "Итоги деинсталляции"
    printf '[ALLOW] OK: %s  FAIL: %s  WARN: %s\n' "$UNINSTALL_OK_COUNT" "$ERROR_COUNT" "$WARNING_COUNT"
    if [ "$ERROR_COUNT" -gt 0 ] && [ "$FORCE" = "0" ]; then
        allow_err "Деинсталляция завершилась с ошибками ($ERROR_COUNT)."
        exit 1
    fi
    if [ "$ERROR_COUNT" -gt 0 ]; then
        allow_warn "Деинсталляция с предупреждениями ($ERROR_COUNT компонентов)."
    elif [ "$WARNING_COUNT" -gt 0 ]; then
        allow_warn "Деинсталляция завершена с предупреждениями ($WARNING_COUNT)."
    else
        allow_info "Деинсталляция всех компонентов завершена успешно."
    fi
}

main() {
    if [ ! -d "$INSTALL_D_DIR" ]; then
        allow_err "Директория установочных скриптов не найдена: $INSTALL_D_DIR"
        exit 1
    fi
    
    # Определяем opkg
    if ! detect_opkg; then
        exit 1
    fi
    
    # Определяем платформу
    detect_platform
    
    # Копируем скрипты в постоянное место
    ensure_persistent_install_scripts

    if [ $# -eq 0 ]; then
        run_all_default_install
        exit 0
    fi

    if [ $# -eq 1 ]; then
        ACTION="$1"
        case "$ACTION" in
            install)
                run_all_default_install
                exit 0
                ;;
            uninstall)
                run_all_default_uninstall
                exit 0
                ;;
            force-uninstall)
                run_all_default_uninstall "1"
                exit 0
                ;;
            check)
                ERROR_COUNT=0
                run_component "dependencies" "check" "0" || ERROR_COUNT=$((ERROR_COUNT + 1))
                run_component "stubby" "check" "0" || ERROR_COUNT=$((ERROR_COUNT + 1))
                run_component "stubby" "check-family" "0" || echo "Предупреждение: проверка stubby-family завершилась с ошибкой (продолжаем)." >&2
                run_component "dnsmasq-full" "check" "0" || ERROR_COUNT=$((ERROR_COUNT + 1))
                run_component "dnsmasq-full" "check-family" "0" || echo "Предупреждение: проверка dnsmasq-family завершилась с ошибкой (продолжаем)." >&2
                run_component "sing-box" "check" "0" || ERROR_COUNT=$((ERROR_COUNT + 1))
                run_component "monitor" "check" "0" || ERROR_COUNT=$((ERROR_COUNT + 1))
                run_component "allow" "check" "0" || ERROR_COUNT=$((ERROR_COUNT + 1))
                
                if [ "$ERROR_COUNT" -gt 0 ]; then
                    allow_err "Проверка завершилась с ошибками ($ERROR_COUNT компонентов)."
                    exit 1
                fi
                allow_info "Все компоненты проверены успешно."
                exit 0
                ;;
            *)
                usage
                exit 1
                ;;
        esac
    fi

    if [ $# -ne 2 ]; then
        usage
        exit 1
    fi

    COMPONENT="$1"
    ACTION="$2"

    case "$ACTION" in
        install|uninstall|force-uninstall|check)
            ;;
        *)
            allow_err "Неизвестное действие: $ACTION"
            usage
            exit 1
            ;;
    esac

    # Определяем, нужно ли принудительное удаление
    FORCE="0"
    if [ "$ACTION" = "force-uninstall" ]; then
        ACTION="uninstall"
        FORCE="1"
    fi
    
    if ! check_component_script "$COMPONENT"; then
        allow_err "Компонент '$COMPONENT' не найден."
        exit 1
    fi
    if ! run_component "$COMPONENT" "$ACTION" "$FORCE"; then
        [ "$FORCE" = "1" ] && allow_warn "Компонент '$COMPONENT' $ACTION завершился с ошибкой (продолжаем)." || { allow_err "Компонент '$COMPONENT' $ACTION завершился с ошибкой."; exit 1; }
    fi
}

main "$@"







