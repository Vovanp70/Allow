#!/bin/sh
#
# Управление режимом DNS (Stubby): adblock | stable | manual.
# Использование:
#   dns-mode.sh status          — вывести текущий режим (adblock | stable | manual)
#   dns-mode.sh set adblock     — установить режим DoT + блокировка рекламы
#   dns-mode.sh set stable      — установить режим DoT + только защита
#

set -e

ETC_ALLOW="${ETC_ALLOW:-/opt/etc/allow}"
DNS_MODE_FILE="${ETC_ALLOW}/dns_mode"
STUBBY_ETC="${ETC_ALLOW}/stubby"
STUBBY_CONFIG="${STUBBY_ETC}/stubby.yml"
STUBBY_FAMILY_CONFIG="${STUBBY_ETC}/stubby-family.yml"
INIT_ALLOW="${ETC_ALLOW}/init.d"
INIT_SYSTEM="/opt/etc/init.d"
STUBBY_INIT=""
STUBBY_FAMILY_INIT=""
for n in S97stubby X97stubby; do
    if [ -x "${INIT_ALLOW}/${n}" ]; then STUBBY_INIT="${INIT_ALLOW}/${n}"; break; fi
    if [ -x "${INIT_SYSTEM}/${n}" ]; then STUBBY_INIT="${INIT_SYSTEM}/${n}"; break; fi
done
for n in S97stubby-family X97stubby-family; do
    if [ -x "${INIT_ALLOW}/${n}" ]; then STUBBY_FAMILY_INIT="${INIT_ALLOW}/${n}"; break; fi
    if [ -x "${INIT_SYSTEM}/${n}" ]; then STUBBY_FAMILY_INIT="${INIT_SYSTEM}/${n}"; break; fi
done

VALID_MODES="adblock stable"
DEFAULT_MODE="adblock"

# --- status: вывести текущий режим (adblock | stable | manual) ---
# Если в dns_mode записан adblock/stable, но фактические конфиги stubby отличаются —
# считаем режим manual (конфиг меняли вручную).
cmd_status() {
    if [ ! -f "$DNS_MODE_FILE" ]; then
        echo "manual"
        return 0
    fi
    mode="$(cat "$DNS_MODE_FILE" | tr -d '\r\n' | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$mode" in
        adblock|stable) ;;
        *) echo "manual"; return 0 ;;
    esac

    # Конфиги не существуют — фактический режим manual
    [ -f "$STUBBY_CONFIG" ] && [ -f "$STUBBY_FAMILY_CONFIG" ] || { echo "manual"; return 0; }

    # Сравниваем фактические конфиги с тем, что должно быть для этого режима
    if ! write_stubby_yml "$mode" | diff -q - "$STUBBY_CONFIG" >/dev/null 2>&1; then
        echo "manual"
        return 0
    fi
    if ! write_stubby_family_yml "$mode" | diff -q - "$STUBBY_FAMILY_CONFIG" >/dev/null 2>&1; then
        echo "manual"
        return 0
    fi
    echo "$mode"
}

# --- Генерация YAML для stubby (порт 41500) ---
write_stubby_yml() {
    local mode="$1"
    if [ "$mode" = "adblock" ]; then
        cat << 'STUBBY_HEAD'
resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
edns_client_subnet_private: 1
idle_timeout: 30000
tls_connection_retries: 5
tls_backoff_time: 180
timeout: 5000
tls_cipher_list: "EECDH+AESGCM:EECDH+CHACHA20"
tls_min_version: GETDNS_TLS1_2
tls_ca_path: "/etc/ssl/certshashed/"

listen_addresses:
  - 127.0.0.1@41500
STUBBY_HEAD
        cat << 'STUBBY_UP'
round_robin_upstreams: 1

upstream_recursive_servers:
  - address_data: 94.140.14.14
    tls_port: 853
    tls_auth_name: "dns.adguard-dns.com"
    tls_ignore_time: 0
  - address_data: 76.76.2.11
    tls_port: 853
    tls_auth_name: "p2.freedns.controld.com"
    tls_ignore_time: 0
STUBBY_UP
    else
        cat << 'STUBBY_HEAD'
resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
edns_client_subnet_private: 1
idle_timeout: 30000
tls_connection_retries: 5
tls_backoff_time: 180
timeout: 5000
tls_cipher_list: "EECDH+AESGCM:EECDH+CHACHA20"
tls_min_version: GETDNS_TLS1_2
tls_ca_path: "/etc/ssl/certshashed/"

listen_addresses:
  - 127.0.0.1@41500
STUBBY_HEAD
        cat << 'STUBBY_UP'
round_robin_upstreams: 1

upstream_recursive_servers:
  - address_data: 1.1.1.2
    tls_port: 853
    tls_auth_name: "security.cloudflare-dns.com"
    tls_ignore_time: 0
  - address_data: 1.0.0.2
    tls_port: 853
    tls_auth_name: "security.cloudflare-dns.com"
    tls_ignore_time: 0
  - address_data: 77.88.8.88
    tls_port: 853
    tls_auth_name: "safe.dot.dns.yandex.net"
    tls_ignore_time: 0
STUBBY_UP
    fi
}

# --- Генерация YAML для stubby-family (порт 41501) ---
write_stubby_family_yml() {
    local mode="$1"
    if [ "$mode" = "adblock" ]; then
        cat << 'FAM_HEAD'
resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
edns_client_subnet_private: 1
idle_timeout: 30000
tls_connection_retries: 5
tls_backoff_time: 180
timeout: 5000
tls_cipher_list: "EECDH+AESGCM:EECDH+CHACHA20"
tls_min_version: GETDNS_TLS1_2
tls_ca_path: "/etc/ssl/certshashed/"

listen_addresses:
  - 127.0.0.1@41501
FAM_HEAD
        cat << 'FAM_UP'
round_robin_upstreams: 1

upstream_recursive_servers:
  - address_data: 94.140.14.15
    tls_port: 853
    tls_auth_name: "family.adguard.com"
    tls_ignore_time: 0
  - address_data: 76.76.2.11
    tls_port: 853
    tls_auth_name: "family.freedns.controld.com"
    tls_ignore_time: 0
FAM_UP
    else
        cat << 'FAM_HEAD'
resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
edns_client_subnet_private: 1
idle_timeout: 30000
tls_connection_retries: 5
tls_backoff_time: 180
timeout: 5000
tls_cipher_list: "EECDH+AESGCM:EECDH+CHACHA20"
tls_min_version: GETDNS_TLS1_2
tls_ca_path: "/etc/ssl/certshashed/"

listen_addresses:
  - 127.0.0.1@41501
FAM_HEAD
        cat << 'FAM_UP'
round_robin_upstreams: 1

upstream_recursive_servers:
  - address_data: 1.1.1.3
    tls_port: 853
    tls_auth_name: "family.cloudflare-dns.com"
    tls_ignore_time: 0
  - address_data: 1.0.0.3
    tls_port: 853
    tls_auth_name: "family.cloudflare-dns.com"
    tls_ignore_time: 0
  - address_data: 77.88.8.7
    tls_port: 853
    tls_auth_name: "family.dot.dns.yandex.net"
    tls_ignore_time: 0
FAM_UP
    fi
}

# --- Валидация конфига: stubby -C <path> -i (вывод -i в stdout не показываем) ---
validate_stubby() {
    local path="$1"
    if command -v stubby >/dev/null 2>&1; then
        if stubby -C "$path" -i >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    return 0
}

# --- Получить порт stubby из init-скрипта (status --kv) ---
get_stubby_port() {
    local port="41500"
    if [ -x "$STUBBY_INIT" ]; then
        local kv
        kv="$("$STUBBY_INIT" status --kv 2>/dev/null)" || true
        if [ -n "$kv" ]; then
            local p
            p="$(echo "$kv" | grep -E '^EFFECTIVE_PORT=' | head -1 | sed 's/^EFFECTIVE_PORT=//' | tr -cd '0-9')"
            [ -n "$p" ] && port="$p"
            if [ -z "$p" ]; then
                p="$(echo "$kv" | grep -E '^CONFIG_PORT=' | head -1 | sed 's/^CONFIG_PORT=//' | tr -cd '0-9')"
                [ -n "$p" ] && port="$p"
            fi
        fi
    fi
    echo "$port"
}

# --- DNS-запрос на 127.0.0.1:PORT, вывести STUBBY_CHECK=ok или STUBBY_CHECK=fail: ... в stderr ---
stubby_dns_check() {
    local port="$1"
    local errmsg=""
    if command -v dig >/dev/null 2>&1; then
        local out
        out="$(dig @127.0.0.1 -p "$port" example.com +short +timeout=3 2>&1)"
        if [ $? -eq 0 ] && [ -n "$out" ]; then
            echo "STUBBY_CHECK=ok" >&2
            return 0
        fi
        errmsg="${out:-dig failed}"
    elif command -v nslookup >/dev/null 2>&1; then
        if nslookup -port="$port" example.com 127.0.0.1 >/dev/null 2>&1; then
            echo "STUBBY_CHECK=ok" >&2
            return 0
        fi
        errmsg="nslookup failed"
    else
        errmsg="dig/nslookup not found"
    fi
    echo "STUBBY_CHECK=fail: ${errmsg}" >&2
    return 1
}

# --- set: установить режим adblock | stable ---
cmd_set() {
    local mode="$1"
    case "$mode" in
        adblock|stable) ;;
        *) echo "Usage: $0 set adblock|stable" >&2; return 1 ;;
    esac

    # Если текущий режим уже совпадает с запрошенным — ничего не делаем
    current="$(cmd_status)"
    if [ "$current" = "$mode" ]; then
        echo "$mode"
        return 0
    fi

    mkdir -p "$STUBBY_ETC"
    backup_stubby="${STUBBY_CONFIG}.backup"
    backup_family="${STUBBY_FAMILY_CONFIG}.backup"

    if [ -f "$STUBBY_CONFIG" ]; then cp -f "$STUBBY_CONFIG" "$backup_stubby"; fi
    if [ -f "$STUBBY_FAMILY_CONFIG" ]; then cp -f "$STUBBY_FAMILY_CONFIG" "$backup_family"; fi

    write_stubby_yml "$mode" > "$STUBBY_CONFIG"
    write_stubby_family_yml "$mode" > "$STUBBY_FAMILY_CONFIG"

    if ! validate_stubby "$STUBBY_CONFIG"; then
        [ -f "$backup_stubby" ] && cp -f "$backup_stubby" "$STUBBY_CONFIG"
        [ -f "$backup_family" ] && cp -f "$backup_family" "$STUBBY_FAMILY_CONFIG"
        echo "stubby config validation failed, backup restored" >&2
        return 1
    fi
    if ! validate_stubby "$STUBBY_FAMILY_CONFIG"; then
        [ -f "$backup_stubby" ] && cp -f "$backup_stubby" "$STUBBY_CONFIG"
        [ -f "$backup_family" ] && cp -f "$backup_family" "$STUBBY_FAMILY_CONFIG"
        echo "stubby-family config validation failed, backup restored" >&2
        return 1
    fi

    mkdir -p "$(dirname "$DNS_MODE_FILE")"
    echo "$mode" > "$DNS_MODE_FILE"

    # Активен = в autostart S97 (запускается S01allow). X97 = неактивен.
    stubby_active=0; case "$STUBBY_INIT" in *S97stubby) stubby_active=1 ;; esac
    family_active=0; case "$STUBBY_FAMILY_INIT" in *S97stubby-family) family_active=1 ;; esac

    [ -x "$STUBBY_INIT" ] && "$STUBBY_INIT" restart 2>/dev/null || true
    [ -x "$STUBBY_FAMILY_INIT" ] && "$STUBBY_FAMILY_INIT" restart 2>/dev/null || true

    port="$(get_stubby_port)"
    sleep 2
    stubby_dns_check "$port" || true

    # Неактивные компоненты после проверки останавливаем, чтобы не оставлять запущенными.
    [ "$stubby_active" -eq 0 ] && [ -x "$STUBBY_INIT" ] && "$STUBBY_INIT" stop 2>/dev/null || true
    [ "$family_active" -eq 0 ] && [ -x "$STUBBY_FAMILY_INIT" ] && "$STUBBY_FAMILY_INIT" stop 2>/dev/null || true

    echo "$mode"
}

# --- main ---
case "${1:-}" in
    status)  cmd_status ;;
    set)     [ -n "${2:-}" ] || { echo "Usage: $0 set adblock|stable" >&2; exit 1; }; cmd_set "$2" ;;
    *)       echo "Usage: $0 status | set adblock|stable" >&2; exit 1 ;;
esac
