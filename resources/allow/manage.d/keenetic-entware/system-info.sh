#!/bin/sh
#
# Системная информация для монитора: интернет, внешний IP.
# Вывод в формате KEY=value (по одной строке) для разбора CGI.
# Использование: system-info.sh
#

ETC_ALLOW="${ETC_ALLOW:-/opt/etc/allow}"

# --- Проверка интернета: ping или wget/curl generate_204 ---
check_internet() {
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "INTERNET=ok"
        return 0
    fi
    if [ -n "$(command -v wget)" ]; then
        if wget -q -O /dev/null --timeout=3 --user-agent="allow-monitor/1.0" "http://connectivitycheck.gstatic.com/generate_204" 2>/dev/null; then
            echo "INTERNET=ok"
            return 0
        fi
    fi
    if [ -n "$(command -v curl)" ]; then
        code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 -A 'allow-monitor/1.0' 'http://connectivitycheck.gstatic.com/generate_204' 2>/dev/null)"
        if [ "$code" = "204" ] || [ "$code" = "200" ]; then
            echo "INTERNET=ok"
            return 0
        fi
    fi
    echo "INTERNET=fail"
    return 1
}

# --- Внешний IP: wget/curl к сервисам (HTTP без TLS первыми) ---
get_external_ip() {
    for url in "http://ifconfig.me/ip" "http://icanhazip.com" "https://ifconfig.me/ip" "https://icanhazip.com" "http://api.ipify.org" "https://api.ipify.org"; do
        ip=""
        if [ -n "$(command -v wget)" ]; then
            ip="$(wget -q -O - --timeout=3 --user-agent="allow-monitor/1.0" "$url" 2>/dev/null | tr -d '\r\n' | awk '{print $1}')"
        fi
        if [ -z "$ip" ] && [ -n "$(command -v curl)" ]; then
            ip="$(curl -s --connect-timeout 3 -A 'allow-monitor/1.0' "$url" 2>/dev/null | tr -d '\r\n' | awk '{print $1}')"
        fi
        if [ -n "$ip" ]; then
            # Простая проверка: цифры и точки (IPv4) или двоеточия (IPv6)
            case "$ip" in
                *[!0-9.]*) ;;
                *.*) echo "EXTERNAL_IP=$ip"; return 0 ;;
            esac
            case "$ip" in
                *[!0-9a-fA-F:.]*) ;;
                *) echo "EXTERNAL_IP=$ip"; return 0 ;;
            esac
        fi
    done
    echo "EXTERNAL_IP="
    return 0
}

# --- main ---
check_internet
internet_ok=$?
if [ $internet_ok -eq 0 ]; then
    get_external_ip
fi
exit 0
