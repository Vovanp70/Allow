#!/bin/sh
#
# state_lib.sh
# Простое key=value хранилище состояния для allow.
# Файл состояния: /opt/etc/allow/state.db
#

STATE_DB="${STATE_DB:-/opt/etc/allow/state.db}"
STATE_DB_DIR="${STATE_DB_DIR:-/opt/etc/allow}"

state__ensure_dir() {
    mkdir -p "$STATE_DB_DIR" 2>/dev/null || true
}

state_get() {
    # $1: key
    key="$1"
    [ -n "$key" ] || return 0
    [ -f "$STATE_DB" ] || return 0
    awk -v k="$key" '
        BEGIN { found=0 }
        {
            pos = index($0, "=")
            if (pos <= 0) next
            kk = substr($0, 1, pos-1)
            if (kk == k) {
                print substr($0, pos+1)
                found=1
                exit
            }
        }
        END { }
    ' "$STATE_DB" 2>/dev/null
}

state_has() {
    # true если ключ существует и значение непустое
    val="$(state_get "$1")"
    [ -n "${val:-}" ]
}

state_set() {
    # $1: key, $2..: value (может содержать пробелы)
    key="$1"
    shift || true
    value="$*"
    [ -n "$key" ] || return 1

    state__ensure_dir

    tmp="${STATE_DB}.tmp.$$"
    if [ -f "$STATE_DB" ]; then
        awk -v k="$key" '
            {
                pos = index($0, "=")
                if (pos <= 0) { print; next }
                kk = substr($0, 1, pos-1)
                if (kk == k) next
                print
            }
        ' "$STATE_DB" >"$tmp" 2>/dev/null || : >"$tmp"
    else
        : >"$tmp"
    fi

    printf '%s=%s\n' "$key" "$value" >>"$tmp" 2>/dev/null || true
    mv "$tmp" "$STATE_DB" 2>/dev/null || {
        # best-effort fallback
        cat "$tmp" >"$STATE_DB" 2>/dev/null || true
        rm -f "$tmp" 2>/dev/null || true
    }
}

state_unset() {
    # $1: key
    key="$1"
    [ -n "$key" ] || return 0
    [ -f "$STATE_DB" ] || return 0

    state__ensure_dir

    tmp="${STATE_DB}.tmp.$$"
    awk -v k="$key" '
        {
            pos = index($0, "=")
            if (pos <= 0) { print; next }
            kk = substr($0, 1, pos-1)
            if (kk == k) next
            print
        }
    ' "$STATE_DB" >"$tmp" 2>/dev/null || : >"$tmp"
    mv "$tmp" "$STATE_DB" 2>/dev/null || {
        cat "$tmp" >"$STATE_DB" 2>/dev/null || true
        rm -f "$tmp" 2>/dev/null || true
    }
}

state_list_contains_word() {
    # $1: list (space separated), $2: word
    list="$1"
    word="$2"
    [ -n "$word" ] || return 1
    for w in $list; do
        [ "$w" = "$word" ] && return 0
    done
    return 1
}

