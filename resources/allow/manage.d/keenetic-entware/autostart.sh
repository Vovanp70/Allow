#!/bin/sh

# Управление активностью init-скриптов компонентов ALLOW (S/X).
# Активный скрипт: S??* (запускается S01allow). Неактивный: X??* (не запускается).
# Использование: autostart.sh <component> activate|deactivate|status
# При источении (AUTOSTART_SOURCED=1) определяются только функции, main не выполняется.

PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin

ALLOW_INITD_DIR="${ALLOW_INITD_DIR:-/opt/etc/allow/init.d}"
INITD_DIR="${INITD_DIR:-/opt/etc/init.d}"

# Маппинг: имя компонента -> базовое имя скрипта (S??name)
component_to_basename() {
    local comp="$1"
    case "$comp" in
        stubby)             echo "S97stubby" ;;
        stubby-family)      echo "S97stubby-family" ;;
        dnsmasq-full)       echo "S98dnsmasq-full" ;;
        dnsmasq-full-family) echo "S98dnsmasq-family" ;;
        sing-box)           echo "S98sing-box" ;;
        monitor)            echo "S99monitor" ;;
        *)                  echo "" ; return 1 ;;
    esac
}

# Преобразовать S-name в X-name
sname_to_xname() {
    local sname="$1"
    case "$sname" in
        S*) echo "X${sname#S}" ;;
        *)  echo "$sname" ;;
    esac
}

# Возвращает путь к скрипту компонента (S или X). Сначала allow/init.d, затем init.d.
# Печать в stdout, код возврата 0 если найден.
get_init_script_path() {
    local comp="$1"
    local base xname
    base="$(component_to_basename "$comp")" || return 1
    xname="$(sname_to_xname "$base")"

    if [ -f "${ALLOW_INITD_DIR}/${base}" ]; then
        echo "${ALLOW_INITD_DIR}/${base}"
        return 0
    fi
    if [ -f "${ALLOW_INITD_DIR}/${xname}" ]; then
        echo "${ALLOW_INITD_DIR}/${xname}"
        return 0
    fi
    if [ -f "${INITD_DIR}/${base}" ]; then
        echo "${INITD_DIR}/${base}"
        return 0
    fi
    if [ -f "${INITD_DIR}/${xname}" ]; then
        echo "${INITD_DIR}/${xname}"
        return 0
    fi
    return 1
}

# Активен ли компонент (есть ли файл S??* в allow/init.d)
is_active() {
    local comp="$1"
    local base
    base="$(component_to_basename "$comp")" || return 1
    [ -f "${ALLOW_INITD_DIR}/${base}" ]
}

cmd_activate() {
    local comp="$1"
    local base xname script_path
    base="$(component_to_basename "$comp")" || { echo "Неизвестный компонент: $comp" >&2; return 1; }
    xname="$(sname_to_xname "$base")"

    if [ -f "${ALLOW_INITD_DIR}/${base}" ]; then
        echo "Компонент $comp уже активен (${ALLOW_INITD_DIR}/${base})."
        return 0
    fi
    if [ ! -f "${ALLOW_INITD_DIR}/${xname}" ]; then
        echo "Скрипт не найден: ${ALLOW_INITD_DIR}/${xname}" >&2
        return 1
    fi
    mv "${ALLOW_INITD_DIR}/${xname}" "${ALLOW_INITD_DIR}/${base}" || return 1
    echo "Компонент $comp активирован: ${xname} -> ${base}."
    script_path="${ALLOW_INITD_DIR}/${base}"
    if [ -x "$script_path" ]; then
        sh "$script_path" start >/dev/null 2>&1 || true
    fi
    return 0
}

cmd_deactivate() {
    local comp="$1"
    local base xname script_path
    base="$(component_to_basename "$comp")" || { echo "Неизвестный компонент: $comp" >&2; return 1; }
    xname="$(sname_to_xname "$base")"

    if [ ! -f "${ALLOW_INITD_DIR}/${base}" ]; then
        if [ -f "${ALLOW_INITD_DIR}/${xname}" ]; then
            echo "Компонент $comp уже неактивен (${ALLOW_INITD_DIR}/${xname})."
        else
            echo "Скрипт не найден в ${ALLOW_INITD_DIR}." >&2
            return 1
        fi
        return 0
    fi
    script_path="${ALLOW_INITD_DIR}/${base}"
    if [ -x "$script_path" ]; then
        sh "$script_path" stop >/dev/null 2>&1 || true
    fi
    mv "${ALLOW_INITD_DIR}/${base}" "${ALLOW_INITD_DIR}/${xname}" || return 1
    echo "Компонент $comp деактивирован: ${base} -> ${xname}."
    return 0
}

cmd_status() {
    local comp="$1"
    local base xname
    base="$(component_to_basename "$comp")" || { echo "Неизвестный компонент: $comp" >&2; return 1; }
    xname="$(sname_to_xname "$base")"

    if [ -f "${ALLOW_INITD_DIR}/${base}" ]; then
        echo "active"
        return 0
    fi
    if [ -f "${ALLOW_INITD_DIR}/${xname}" ]; then
        echo "inactive"
        return 0
    fi
    echo "missing"
    return 1
}

# Main: только при прямом запуске (не при источении)
[ -n "${AUTOSTART_SOURCED:-}" ] && return 0

usage() {
    echo "Использование: $0 <component> activate|deactivate|status"
    echo "Компоненты: stubby, stubby-family, dnsmasq-full, dnsmasq-full-family, sing-box, monitor"
}

case "${2:-}" in
    activate)
        if [ -z "${1:-}" ]; then
            usage >&2
            exit 1
        fi
        cmd_activate "$1" || exit 1
        ;;
    deactivate)
        if [ -z "${1:-}" ]; then
            usage >&2
            exit 1
        fi
        cmd_deactivate "$1" || exit 1
        ;;
    status)
        if [ -z "${1:-}" ]; then
            usage >&2
            exit 1
        fi
        cmd_status "$1"
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
