#!/bin/sh

# Подскрипт для установки curl с поддержкой HTTP/3
# Должен располагаться на роутере как /opt/tmp/allow/install.d/curl-http3.sh

set -e

COMPONENT="curl-http3"
PLATFORM="${2:-entware}"

CONF_DIR="/opt/etc/allow/${COMPONENT}"
LOG_DIR="/opt/var/log/allow/${COMPONENT}"
INITD_DIR="/opt/etc/init.d"
# NEED_DIR может быть передан через переменную окружения, иначе используем значение по умолчанию
NEED_DIR="${NEED_DIR:-/opt/tmp/allow/resources/${COMPONENT}}"
STATE_KEY_INSTALLED="installed.${COMPONENT}"

# Подключаем единое хранилище состояния
LIB_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${LIB_DIR}/state_lib.sh"

# Версия curl с HTTP/3 для скачивания
CURL_HTTP3_VERSION="8.17.0"

# Путь к сертификатам
CA_CERT_FILE="/opt/etc/ssl/certs/ca-certificates.crt"
CA_CERT_LINK="/etc/ssl/certs/ca-certificates.crt"
CA_CERT_DIR="/opt/etc/ssl/certs"

mkdir -p "$LOG_DIR"

LOG_FILE="${LOG_DIR}/${COMPONENT}.log"

# Определяем, поддерживает ли терминал цвета
is_color_terminal() {
    [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]
}

# Цветовые коды (если терминал поддерживает цвета)
if is_color_terminal; then
    COLOR_GREEN="\033[0;32m"
    COLOR_RED="\033[0;31m"
    COLOR_YELLOW="\033[1;33m"
    COLOR_RESET="\033[0m"
else
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_YELLOW=""
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

log_warn() {
    TS="$(date '+%Y-%m-%d %H:%M:%S')"
    MSG="[$TS] $*"
    echo -e "${COLOR_YELLOW}${MSG}${COLOR_RESET}" | tee -a "$LOG_FILE"
}

# Обеспечить наличие CA bundle для TLS (curl/wget)
ensure_ca_bundle() {
    log "Проверка CA bundle для TLS..."

    # Уже есть корректный файл
    if [ -s "$CA_CERT_FILE" ]; then
        log_success "CA bundle найден: $CA_CERT_FILE"
        return 0
    fi

    # Пытаемся поставить штатный пакетный bundle (Entware)
    if command -v opkg >/dev/null 2>&1; then
        # Пакеты могут быть не установлены/частично установлены
        if ! opkg list-installed 2>/dev/null | grep -q "^ca-bundle "; then
            log "Устанавливаю ca-bundle (и ca-certificates) через opkg..."
            # update может не сработать (сеть/репо) — не делаем это фатальным
            opkg update >>"$LOG_FILE" 2>&1 || log_warn "opkg update не удалось (продолжаю установку)"
            opkg install ca-bundle ca-certificates >>"$LOG_FILE" 2>&1 || {
                log_warn "Не удалось установить ca-bundle/ca-certificates через opkg"
            }
        else
            log "ca-bundle уже установлен"
        fi
    else
        log_warn "opkg не найден, пакетный ca-bundle поставить нельзя"
    fi

    # Если файла всё ещё нет, пробуем собрать bundle из *.crt (fallback)
    if [ ! -s "$CA_CERT_FILE" ]; then
        if [ -d "$CA_CERT_DIR" ] && ls "$CA_CERT_DIR"/*.crt >/dev/null 2>&1; then
            log_warn "CA bundle отсутствует, собираю ${CA_CERT_FILE} из ${CA_CERT_DIR}/*.crt (fallback)"
            cat "$CA_CERT_DIR"/*.crt >"$CA_CERT_FILE" 2>>"$LOG_FILE" || {
                log_warn "Не удалось собрать CA bundle (cat *.crt > ca-certificates.crt)"
            }
        fi
    fi

    if [ -s "$CA_CERT_FILE" ]; then
        log_success "CA bundle готов: $CA_CERT_FILE"
        return 0
    fi

    log_warn "CA bundle не найден/не создан. HTTPS загрузки могут не работать."
    return 0
}

# Определение архитектуры
detect_architecture() {
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64)
            CURL_ARCH="aarch64"
            ;;
        armv7l|armv7)
            CURL_ARCH="armv7"
            ;;
        x86_64|amd64)
            CURL_ARCH="x86_64"
            ;;
        *)
            log_error "Неподдерживаемая архитектура: $ARCH"
            return 1
            ;;
    esac
    log "Обнаружена архитектура: $ARCH (используем: $CURL_ARCH)"
}

# Проверка наличия инструментов
check_tools() {
    local missing_tools=""
    
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        missing_tools="wget или curl"
    fi
    
    if ! command -v tar >/dev/null 2>&1; then
        missing_tools="${missing_tools} tar"
    fi
    
    if [ -n "$missing_tools" ]; then
        log_error "Отсутствуют необходимые инструменты: $missing_tools"
        log "Попробуйте установить: opkg install wget-ssl tar"
        return 1
    fi
    
    # Проверка поддержки xz в tar или наличие xz
    if ! tar --help 2>&1 | grep -q "xz\|-J" && ! command -v xz >/dev/null 2>&1; then
        log_warn "xz не найден, попробуем установить..."
        if command -v opkg >/dev/null 2>&1; then
            opkg install xz-utils || log_warn "Не удалось установить xz-utils, попробуем продолжить..."
        fi
    fi
}

# Определение libc (glibc или musl)
detect_libc() {
    # Проверяем через ldd или наличие библиотек
    if command -v ldd >/dev/null 2>&1; then
        if ldd /bin/sh 2>/dev/null | grep -q "libc.so"; then
            if ldd /bin/sh 2>/dev/null | grep -q "musl"; then
                CURL_LIBC="musl"
            else
                CURL_LIBC="glibc"
            fi
        else
            # Fallback: проверяем наличие файлов
            if [ -f "/lib/libc.musl" ] || ls /lib/libc.musl* >/dev/null 2>&1; then
                CURL_LIBC="musl"
            else
                CURL_LIBC="glibc"
            fi
        fi
    else
        # Если ldd недоступен, по умолчанию glibc
        CURL_LIBC="glibc"
    fi
    log "Обнаружена libc: $CURL_LIBC"
}

# Скачивание curl с HTTP/3
download_curl_http3() {
    log "Скачивание curl с HTTP/3 версии ${CURL_HTTP3_VERSION}..."

    # Временная директория на каждый запуск.
    # Если TEMP_DIR уже задан (например, install_component создал его), используем его.
    if [ -z "${TEMP_DIR:-}" ]; then
        TEMP_DIR="$(mktemp -d /tmp/curl-http3.XXXXXX)" || {
            log_error "Не удалось создать временную директорию (mktemp)"
            return 1
        }
    fi
    mkdir -p "$TEMP_DIR" || true
    cd "$TEMP_DIR" || {
        log_error "Не удалось перейти в временную директорию: $TEMP_DIR"
        return 1
    }
    
    # Чтобы системный curl/wget при проверке и скачивании использовали CA bundle из /opt
    if [ -s "$CA_CERT_FILE" ]; then
        export SSL_CERT_FILE="$CA_CERT_FILE"
        [ -d "$CA_CERT_DIR" ] && export SSL_CERT_DIR="$CA_CERT_DIR"
    fi
    
    # Определяем libc
    detect_libc
    
    # Формируем список вариантов имён файлов с приоритетом для обнаруженной libc
    if [ "$CURL_LIBC" = "musl" ]; then
        ARCHIVE_VARIANTS="
curl-linux-${CURL_ARCH}-musl-${CURL_HTTP3_VERSION}.tar.xz
curl-linux-${CURL_ARCH}-glibc-${CURL_HTTP3_VERSION}.tar.xz
curl-linux-${CURL_ARCH}-dev-${CURL_HTTP3_VERSION}.tar.xz
curl-linux-${CURL_ARCH}-musl.tar.xz
curl-linux-${CURL_ARCH}-glibc.tar.xz
curl-linux-${CURL_ARCH}-dev.tar.xz
"
    else
        ARCHIVE_VARIANTS="
curl-linux-${CURL_ARCH}-glibc-${CURL_HTTP3_VERSION}.tar.xz
curl-linux-${CURL_ARCH}-musl-${CURL_HTTP3_VERSION}.tar.xz
curl-linux-${CURL_ARCH}-dev-${CURL_HTTP3_VERSION}.tar.xz
curl-linux-${CURL_ARCH}-glibc.tar.xz
curl-linux-${CURL_ARCH}-musl.tar.xz
curl-linux-${CURL_ARCH}-dev.tar.xz
"
    fi
    
    ARCHIVE_FILE=""
    ARCHIVE_URL=""
    
    DOWNLOAD_CMD=""
    if command -v curl >/dev/null 2>&1; then
        DOWNLOAD_CMD="curl"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOAD_CMD="wget"
    else
        log_error "Не найден wget или curl для скачивания"
        return 1
    fi
    
    # 1) Пробуем получить URL через GitHub API (реальный тег релиза не угадываем)
    if [ "$DOWNLOAD_CMD" = "curl" ]; then
        API_JSON=$(curl -sL --max-time 15 -H "User-Agent: Allow-installer" \
            "https://api.github.com/repos/stunnel/static-curl/releases" 2>>"$LOG_FILE")
        if [ -n "$API_JSON" ]; then
            # Ищем browser_download_url для ассета с нашей архитектурой и .tar.xz (приоритет: glibc, musl, dev)
            # GitHub API возвращает JSON без пробела после двоеточия: "browser_download_url":"URL"
            for suffix in glibc musl dev; do
                api_url=$(echo "$API_JSON" | grep -o "\"browser_download_url\": *\"[^\"]*curl-linux-${CURL_ARCH}-${suffix}[^\"]*\.tar\.xz\"" 2>/dev/null | head -1 | sed 's/^"browser_download_url": *"\([^"]*\)"$/\1/')
                if [ -n "$api_url" ]; then
                    log "Пробуем скачать (API): $api_url"
                    http_code=$(curl -sL -o /dev/null -w "%{http_code}" --max-time 10 "$api_url" 2>>"$LOG_FILE")
                    if [ "$http_code" = "200" ]; then
                        ARCHIVE_FILE=$(echo "$api_url" | sed 's|.*/||')
                        ARCHIVE_URL="$api_url"
                        log_success "Файл найден: $ARCHIVE_FILE"
                        break
                    fi
                fi
            done
        fi
    fi
    
    # 2) Если API не дал результат — перебираем теги и имена файлов вручную
    if [ -z "$ARCHIVE_URL" ]; then
        # Версии для перебора: запрошенная + запасные (релиз может отставать от upstream)
        for tag in "${CURL_HTTP3_VERSION}" "v${CURL_HTTP3_VERSION}" "8.16.0" "v8.16.0" "8.15.0" "v8.15.0"; do
            BASE_URL="https://github.com/stunnel/static-curl/releases/download/${tag}"
            for variant in $ARCHIVE_VARIANTS; do
                variant=$(echo "$variant" | tr -d '[:space:]')
                [ -z "$variant" ] && continue
                test_url="${BASE_URL}/${variant}"
                log "Пробуем скачать: $test_url"
                if [ "$DOWNLOAD_CMD" = "wget" ]; then
                    if wget --spider -q "$test_url" >>"$LOG_FILE" 2>&1; then
                        ARCHIVE_FILE="$variant"
                        ARCHIVE_URL="$test_url"
                        log_success "Файл найден: $ARCHIVE_FILE (тег: $tag)"
                        break 2
                    fi
                elif [ "$DOWNLOAD_CMD" = "curl" ]; then
                    http_code=$(curl -sL -o /dev/null -w "%{http_code}" --max-time 10 "$test_url" 2>>"$LOG_FILE")
                    if [ "$http_code" = "200" ]; then
                        ARCHIVE_FILE="$variant"
                        ARCHIVE_URL="$test_url"
                        log_success "Файл найден: $ARCHIVE_FILE (тег: $tag)"
                        break 2
                    fi
                fi
            done
        done
    fi
    
    if [ -z "$ARCHIVE_FILE" ]; then
        log_error "Не удалось найти архив curl с HTTP/3 для архитектуры ${CURL_ARCH}"
        log "Проверьте: https://github.com/stunnel/static-curl/releases"
        return 1
    fi
    
    log "Скачивание: $ARCHIVE_URL"
    
    if [ "$DOWNLOAD_CMD" = "wget" ]; then
        if ! wget -O "$ARCHIVE_FILE" "$ARCHIVE_URL" >>"$LOG_FILE" 2>&1; then
            log_error "Не удалось скачать архив curl с HTTP/3"
            return 1
        fi
    elif [ "$DOWNLOAD_CMD" = "curl" ]; then
        if ! curl -L -o "$ARCHIVE_FILE" "$ARCHIVE_URL" >>"$LOG_FILE" 2>&1; then
            log_error "Не удалось скачать архив curl с HTTP/3"
            return 1
        fi
    fi
    
    log_success "Архив скачан: $ARCHIVE_FILE"
    
    # Распаковка
    log "Распаковка архива..."
    if command -v xz >/dev/null 2>&1; then
        # Защита от повторного запуска: если .tar остался от прошлой попытки, xz иначе упадёт с "File exists"
        rm -f "${ARCHIVE_FILE%.xz}" 2>/dev/null || true
        xz -df "$ARCHIVE_FILE" || {
            log_error "Не удалось распаковать xz архив"
            return 1
        }
        tar xf "${ARCHIVE_FILE%.xz}" || {
            log_error "Не удалось распаковать tar архив"
            return 1
        }
    elif tar --help 2>&1 | grep -q "xz\|-J"; then
        tar xJf "$ARCHIVE_FILE" || {
            log_error "Не удалось распаковать архив"
            return 1
        }
    else
        log_error "Не удалось распаковать архив: требуется xz или tar с поддержкой xz"
        return 1
    fi
    
    if [ ! -f "curl" ]; then
        log_error "После распаковки не найден файл curl"
        return 1
    fi
    
    log_success "Архив распакован"
}

# Установка curl
install_curl() {
    log "Установка curl с HTTP/3..."

    if [ -z "${TEMP_DIR:-}" ]; then
        log_error "Временная директория не задана (TEMP_DIR пуст)."
        return 1
    fi

    # Копируем бинарник отдельно
    cp "$TEMP_DIR/curl" /opt/bin/curl-http3.bin || {
        log_error "Не удалось скопировать curl в /opt/bin/"
        return 1
    }
    chmod +x /opt/bin/curl-http3.bin || {
        log_error "Не удалось установить права на выполнение"
        return 1
    }

    # Обёртка, проставляющая SSL_CERT_FILE/SSL_CERT_DIR, если не заданы
    cat > /opt/bin/curl-http3 <<'EOF'
#!/bin/sh
[ -z "$SSL_CERT_FILE" ] && [ -f "/opt/etc/ssl/certs/ca-certificates.crt" ] && SSL_CERT_FILE="/opt/etc/ssl/certs/ca-certificates.crt"
[ -z "$SSL_CERT_DIR" ] && [ -d "/opt/etc/ssl/certs" ] && SSL_CERT_DIR="/opt/etc/ssl/certs"
export SSL_CERT_FILE SSL_CERT_DIR
exec /opt/bin/curl-http3.bin "$@"
EOF
    chmod +x /opt/bin/curl-http3

    log_success "curl с HTTP/3 установлен: /opt/bin/curl-http3 (wrapper) -> curl-http3.bin"

    # Делаем curl-http3 основным: создаём бэкап и симлинк /opt/bin/curl -> обёртка
    if [ -e "/opt/bin/curl" ] && [ ! -L "/opt/bin/curl" ]; then
        log "Создание бэкапа старого curl..."
        cp /opt/bin/curl /opt/bin/curl.old || true
    fi
    ln -sf /opt/bin/curl-http3 /opt/bin/curl || {
        log_warn "Не удалось создать симлинк /opt/bin/curl, используйте /opt/bin/curl-http3 вручную"
    }
}

# Настройка сертификатов
setup_certificates() {
    log "Настройка сертификатов SSL..."

    # Гарантируем наличие CA bundle (или хотя бы попытаемся создать)
    ensure_ca_bundle

    # Проверка наличия файла сертификатов
    if [ ! -s "$CA_CERT_FILE" ]; then
        log_warn "CA bundle не найден: $CA_CERT_FILE"
        log "Рекомендуется: opkg install ca-bundle (и ca-certificates)"
        return 0  # Не критичная ошибка
    fi

    # В Keenetic /etc часто read-only, а curl-http3 у нас и так работает через:
    # - /opt/etc/ssl/certs/ca-certificates.crt
    # - wrapper (/opt/bin/curl-http3) и/или /opt/etc/profile.d/allow-curl-http3.sh
    # Поэтому не пытаемся писать в /etc и не создаём симлинки.
    log "Пропускаю создание симлинков в /etc (read-only). Использую CA bundle из /opt."
    log_success "Сертификаты настроены (без симлинков)"
}

# Прописываем SSL_CERT_FILE глобально (для случаев read-only /etc/ssl/certs)
setup_cert_env() {
    PROFILE_DIR="/opt/etc/profile.d"
    PROFILE_SNIPPET="${PROFILE_DIR}/allow-curl-http3.sh"
    mkdir -p "$PROFILE_DIR" || {
        log_warn "Не удалось создать ${PROFILE_DIR} для экспорта SSL_CERT_FILE"
        return 0
    }
    cat >"$PROFILE_SNIPPET" <<'EOF'
# Auto-generated by allow curl-http3 install
if [ -f /opt/etc/ssl/certs/ca-certificates.crt ]; then
  export SSL_CERT_FILE=/opt/etc/ssl/certs/ca-certificates.crt
elif [ -d /opt/etc/ssl/certs ]; then
  export SSL_CERT_DIR=/opt/etc/ssl/certs
fi
EOF
    log_success "Переменная SSL_CERT_FILE добавлена в ${PROFILE_SNIPPET}"
}

# Опциональное удаление пакетного curl (не критично)
remove_system_curl() {
    if command -v opkg >/dev/null 2>&1; then
        if opkg list-installed 2>/dev/null | grep -q "^curl "; then
            log "Найден пакетный curl, пытаюсь удалить..."
            if opkg remove curl >>"$LOG_FILE" 2>&1; then
                log_success "Пакетный curl удалён (opkg remove curl)"
            else
                log_warn "Не удалось удалить пакетный curl (opkg remove curl), продолжим с curl-http3"
            fi
        else
            log "Пакетный curl не установлен, пропускаю удаление"
        fi
    else
        log "opkg не найден, пропускаю удаление пакетного curl"
    fi
}

# Проверка установки
verify_installation() {
    log "Проверка установки curl с HTTP/3..."
    
    if [ ! -f "/opt/bin/curl-http3" ]; then
        log_error "curl-http3 не найден в /opt/bin/"
        return 1
    fi
    
    if ! /opt/bin/curl-http3 --version >/dev/null 2>&1; then
        log_error "curl-http3 не запускается"
        return 1
    fi
    
    # Проверка поддержки HTTP/3
    if /opt/bin/curl-http3 --version 2>&1 | grep -qi "http3\|nghttp3"; then
        log_success "HTTP/3 поддержка обнаружена"
    else
        log_warn "HTTP/3 поддержка не обнаружена в выводе версии"
    fi
    
    log_success "curl с HTTP/3 установлен и работает"
    log "Использование: curl --http3 https://example.com (симлинк на curl-http3)"
}

# Очистка временных файлов
cleanup() {
    log "Очистка временных файлов..."
    if [ -n "${TEMP_DIR:-}" ]; then
        rm -rf "$TEMP_DIR"
    fi
    log_success "Очистка завершена"
}

# Установка компонента
install_component() {
    log "=== УСТАНОВКА ${COMPONENT} ==="

    # Защита от параллельных запусков
    LOCK_DIR="/tmp/allow.${COMPONENT}.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log_error "Установка уже выполняется (lock: $LOCK_DIR). Дождитесь завершения или удалите lock вручную."
        return 1
    fi

    # Уникальная временная директория на каждый запуск
    TEMP_DIR="$(mktemp -d /tmp/curl-http3.XXXXXX)" || {
        rmdir "$LOCK_DIR" 2>/dev/null || true
        log_error "Не удалось создать временную директорию (mktemp)"
        return 1
    }

    # Всегда убираем временные файлы (включая lock) при любом выходе (успех/ошибка/kill)
    trap 'rm -rf "$TEMP_DIR" 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM
    
    detect_architecture || return 1
    check_tools || return 1
    # До любых HTTPS-загрузок обеспечиваем CA bundle
    ensure_ca_bundle
    download_curl_http3 || return 1
    install_curl || return 1
    setup_certificates
    setup_cert_env
    # Не удаляем пакетный curl, чтобы после деинсталляции восстановился рабочий системный curl
    # remove_system_curl
    verify_installation || return 1
    cleanup
    
    # Отмечаем успешную установку в state.db
    state_set "$STATE_KEY_INSTALLED" "$(date '+%Y-%m-%d %H:%M:%S')"
    
    log_success "=== УСТАНОВКА ${COMPONENT} ЗАВЕРШЕНА УСПЕШНО ==="
}

# Деинсталляция компонента
uninstall_component() {
    log "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT} ==="
    
    # Проверка состояния установки (если не FORCE)
    if [ "${FORCE:-0}" != "1" ]; then
        if ! state_has "$STATE_KEY_INSTALLED"; then
            log "Компонент ${COMPONENT} не установлен (файл состояния не найден), пропускаю деинсталляцию."
            return 0
        fi
    fi
    
    # Удаляем wrapper и бинарник
    rm -f /opt/bin/curl /opt/bin/curl-http3 /opt/bin/curl-http3.bin
    log_success "curl-http3 удалён"

    # Удаляем конфиги/директорию компонента
    if [ -d "$CONF_DIR" ]; then
        log "Удаляю директорию компонента: $CONF_DIR"
        rm -rf "$CONF_DIR" 2>/dev/null || true
    fi

    # Удаляем env snippet (чтобы не оставался экспорт SSL_CERT_FILE/SSL_CERT_DIR)
    if [ -f "/opt/etc/profile.d/allow-curl-http3.sh" ]; then
        log "Удаляю env snippet: /opt/etc/profile.d/allow-curl-http3.sh"
        rm -f "/opt/etc/profile.d/allow-curl-http3.sh" 2>/dev/null || true
    fi
    
    # Восстановление старого curl если был бэкап
    if [ -f "/opt/bin/curl.old" ]; then
        log "Восстановление старого curl..."
        mv /opt/bin/curl.old /opt/bin/curl || true
    fi
    
    # Удаление симлинка сертификатов если создавали
    if [ -L "$CA_CERT_LINK" ]; then
        log "Удаление симлинка сертификатов..."
        rm -f "$CA_CERT_LINK" 2>>"$LOG_FILE" || true
    fi
    
    # Удаляем отметку состояния
    state_unset "$STATE_KEY_INSTALLED"
    
    log_success "=== ДЕИНСТАЛЛЯЦИЯ ${COMPONENT} ЗАВЕРШЕНА ==="
    
    # Удаляем логи в самом конце (после всех log вызовов)
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR" 2>/dev/null || true
    fi
}

# Проверка компонента
check_component() {
    log "=== ПРОВЕРКА ${COMPONENT} ==="
    
    if ! state_has "$STATE_KEY_INSTALLED"; then
        log_error "Компонент не установлен (файл состояния не найден)"
        return 1
    fi
    
    if [ ! -f "/opt/bin/curl-http3" ]; then
        log_error "curl-http3 не найден"
        return 1
    fi
    
    if ! /opt/bin/curl-http3 --version >/dev/null 2>&1; then
        log_error "curl-http3 не запускается"
        return 1
    fi
    
    log_success "=== ПРОВЕРКА ${COMPONENT}: OK ==="
    return 0
}

# Главная функция
main() {
    ACTION="${1:-}"
    
    case "$ACTION" in
        install)
            install_component
            ;;
        uninstall)
            uninstall_component
            ;;
        check)
            check_component
            ;;
        *)
            echo "Использование: $0 {install|uninstall|check}"
            exit 1
            ;;
    esac
}

main "$@"

