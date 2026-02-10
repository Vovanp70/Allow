#!/bin/sh
# Синхронизация списков allow: скачивает списки из itdoginfo/allow-domains,
# extra — из Vovanp70/Allow (lists/itdoginfo-extra). Создаёт /opt/etc/allow/lists/{bypass,zapret,nonbypass,del-usr},
# пересобирает auto‑листы из upstream+extra с учётом del-usr и user‑файлов (*_user.txt, только чтение).

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

SYNC_SCRIPT_PATH="${SYNC_SCRIPT_PATH:-/opt/etc/allow/dnsmasq-full/sync-allow-lists.sh}"
CRON_EXPR="0 4 * * *"

# Обработка autoupdate status|enable|disable
case "${1:-}" in
    autoupdate)
        case "${2:-}" in
            status)
                autoupdate_status=1
                ;;
            enable)
                autoupdate_enable=1
                ;;
            disable)
                autoupdate_disable=1
                ;;
            *)
                echo "Usage: $0 autoupdate status|enable|disable" >&2
                exit 1
                ;;
        esac
        ;;
esac

if [ -n "${autoupdate_status:-}" ] || [ -n "${autoupdate_enable:-}" ] || [ -n "${autoupdate_disable:-}" ]; then
    ensure_cron_spool_dirs() {
        if command -v crontab >/dev/null 2>&1; then
            mkdir -p /opt/var/spool/cron/crontabs 2>/dev/null || true
            chmod 700 /opt/var/spool/cron 2>/dev/null || true
            chmod 700 /opt/var/spool/cron/crontabs 2>/dev/null || true
            if [ ! -f /opt/var/spool/cron/crontabs/root ]; then
                : > /opt/var/spool/cron/crontabs/root 2>/dev/null || true
                chmod 600 /opt/var/spool/cron/crontabs/root 2>/dev/null || true
            fi
        fi
    }
    ensure_crond_running() {
        if command -v crond >/dev/null 2>&1; then
            ps w 2>/dev/null | grep -q "[c]rond" && return 0
            crond -c /opt/var/spool/cron/crontabs 2>/dev/null || crond 2>/dev/null || true
        fi
    }
    ensure_newline_at_eof() {
        [ -f "$1" ] || return 0
        LAST_CHAR="$(tail -c 1 "$1" 2>/dev/null || true)"
        [ -z "$LAST_CHAR" ] || printf '\n' >>"$1" 2>/dev/null || true
    }
    cron_status() {
        if command -v crontab >/dev/null 2>&1; then
            if crontab -l 2>/dev/null | grep -Fq "${SYNC_SCRIPT_PATH}"; then
                echo "autoupdate: включено (cron 04:00)"
                return 0
            fi
        fi
        if [ -f "/opt/etc/crontabs/root" ] && grep -Fq "${SYNC_SCRIPT_PATH}" /opt/etc/crontabs/root 2>/dev/null; then
            echo "autoupdate: включено (cron 04:00)"
            return 0
        fi
        echo "autoupdate: выключено"
        return 1
    }
    cron_add_entry() {
        cron_status >/dev/null 2>&1 && {
            echo "autoupdate: уже включено (cron 04:00)"
            return 0
        }
        ENTRY="${CRON_EXPR} ${SYNC_SCRIPT_PATH} >/dev/null 2>&1"
        if command -v crontab >/dev/null 2>&1; then
            ensure_cron_spool_dirs
            TMP="/tmp/allow-sync-cron.$$"
            crontab -l 2>/dev/null >"$TMP" || : >"$TMP"
            if grep -Fq "${SYNC_SCRIPT_PATH}" "$TMP" 2>/dev/null; then
                echo "autoupdate: уже включено (cron 04:00)"
                rm -f "$TMP" 2>/dev/null || true
                return 0
            fi
            ensure_newline_at_eof "$TMP"
            echo "$ENTRY" >>"$TMP"
            if crontab "$TMP" 2>/dev/null; then
                ensure_crond_running
                echo "autoupdate: включено (cron 04:00)"
                rm -f "$TMP" 2>/dev/null || true
                return 0
            fi
            echo "autoupdate: не удалось применить crontab" >&2
            rm -f "$TMP" 2>/dev/null || true
            return 1
        fi
        if [ -d "/opt/etc/crontabs" ]; then
            CRONFILE="/opt/etc/crontabs/root"
            touch "$CRONFILE" 2>/dev/null || true
            if grep -Fq "${SYNC_SCRIPT_PATH}" "$CRONFILE" 2>/dev/null; then
                echo "autoupdate: уже включено (cron 04:00)"
                return 0
            fi
            ensure_newline_at_eof "$CRONFILE"
            echo "$ENTRY" >>"$CRONFILE"
            echo "autoupdate: включено (cron 04:00)"
            return 0
        fi
        echo "autoupdate: cron не найден" >&2
        return 1
    }
    cron_remove_entry() {
        if command -v crontab >/dev/null 2>&1; then
            ensure_cron_spool_dirs
            TMP="/tmp/allow-sync-cron.$$"
            TMP2="/tmp/allow-sync-cron.$$.new"
            crontab -l 2>/dev/null >"$TMP" || : >"$TMP"
            if ! grep -Fq "${SYNC_SCRIPT_PATH}" "$TMP" 2>/dev/null; then
                echo "autoupdate: выключено (запись отсутствовала)"
                rm -f "$TMP" "$TMP2" 2>/dev/null || true
                return 0
            fi
            grep -Fv "${SYNC_SCRIPT_PATH}" "$TMP" >"$TMP2" 2>/dev/null || : >"$TMP2"
            ensure_newline_at_eof "$TMP2"
            if crontab "$TMP2" 2>/dev/null; then
                ensure_crond_running
                echo "autoupdate: выключено"
                rm -f "$TMP" "$TMP2" 2>/dev/null || true
                return 0
            fi
            echo "autoupdate: не удалось применить crontab при удалении" >&2
            rm -f "$TMP" "$TMP2" 2>/dev/null || true
            return 1
        fi
        if [ -f "/opt/etc/crontabs/root" ]; then
            CRONFILE="/opt/etc/crontabs/root"
            if ! grep -Fq "${SYNC_SCRIPT_PATH}" "$CRONFILE" 2>/dev/null; then
                echo "autoupdate: выключено (запись отсутствовала)"
                return 0
            fi
            TMP="/tmp/allow-sync-cron.$$"
            grep -Fv "${SYNC_SCRIPT_PATH}" "$CRONFILE" >"$TMP" 2>/dev/null || : >"$TMP"
            ensure_newline_at_eof "$TMP"
            cat "$TMP" >"$CRONFILE" 2>/dev/null || true
            rm -f "$TMP" 2>/dev/null || true
            echo "autoupdate: выключено"
            return 0
        fi
        echo "autoupdate: выключено (cron не найден)"
        return 0
    }
    if [ -n "${autoupdate_status:-}" ]; then
        cron_status
        exit $?
    elif [ -n "${autoupdate_enable:-}" ]; then
        cron_add_entry
        exit $?
    else
        cron_remove_entry
        exit $?
    fi
fi

SYNC_LOG="${SYNC_LOG:-/opt/var/log/allow/sync-allow-lists.log}"
log() { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$SYNC_LOG" 2>/dev/null || true; }

LISTS_BASE="${LISTS_BASE:-/opt/etc/allow/lists}"
TMP_DIR="${TMP_DIR:-/tmp}"
BASE_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main"
EXTRA_REPO_URL="${EXTRA_REPO_URL:-https://raw.githubusercontent.com/Vovanp70/Allow/main/lists/itdoginfo-extra}"
RUS_SERVICES_OUT_NAME="Russian-services_hosts_auto.txt"

# Формат: "URL|имя_файла" (без пробелов вокруг |)
LISTS="
${BASE_URL}/Categories/anime.lst|Anime_hosts_auto.txt
${BASE_URL}/Services/youtube.lst|YouTube_hosts_auto.txt
${BASE_URL}/Categories/block.lst|Block_hosts_auto.txt
${BASE_URL}/Categories/geoblock.lst|GeoBlock_hosts_auto.txt
${BASE_URL}/Categories/news.lst|News_hosts_auto.txt
${BASE_URL}/Categories/porn.lst|Porn_hosts_auto.txt
${BASE_URL}/Categories/hodca.lst|HODCA_hosts_auto.txt
${BASE_URL}/Subnets/IPv4/cloudflare.lst|Cloudflare_subnets_auto.txt
${BASE_URL}/Services/discord.lst|Discord_hosts_auto.txt
${BASE_URL}/Subnets/IPv4/discord.lst|Discord_subnets_auto.txt
${BASE_URL}/Services/hdrezka.lst|HDRezka_hosts_auto.txt
${BASE_URL}/Services/meta.lst|Meta_hosts_auto.txt
${BASE_URL}/Subnets/IPv4/meta.lst|Meta_subnets_auto.txt
${BASE_URL}/Services/telegram.lst|Telegram_hosts_auto.txt
${BASE_URL}/Subnets/IPv4/telegram.lst|Telegram_subnets_auto.txt
${BASE_URL}/Services/tiktok.lst|TikTok_hosts_auto.txt
${BASE_URL}/Services/twitter.lst|Twitter_hosts_auto.txt
${BASE_URL}/Subnets/IPv4/twitter.lst|Twitter_subnets_auto.txt
"

# Временные файлы (один набор на все списки, очистка в trap)
TMP_REMOTE="${TMP_DIR}/allow-remote.$$"
TMP_SRC="${TMP_DIR}/allow-src.$$"
TMP_SRC_FILTERED="${TMP_DIR}/allow-src-filtered.$$"
TMP_DELUSR="${TMP_DIR}/allow-delusr.$$"
TMP_USER="${TMP_DIR}/allow-user.$$"
TMP_AUTO="${TMP_DIR}/allow-auto.$$"
TMP_OLD="${TMP_DIR}/allow-old.$$"
TMP_ADDED_LIST="${TMP_DIR}/allow-added-list.$$"
TMP_REMOVED_LIST="${TMP_DIR}/allow-removed-list.$$"
TMP_EXTRA="${TMP_DIR}/allow-extra.$$"

cleanup() {
    rm -f "$TMP_REMOTE" "$TMP_SRC" "$TMP_SRC_FILTERED" \
          "$TMP_DELUSR" "$TMP_USER" "$TMP_AUTO" "$TMP_OLD" \
          "$TMP_ADDED_LIST" "$TMP_REMOVED_LIST" "$TMP_EXTRA" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Создание директорий (POSIX: без brace expansion)
mkdir -p "$LISTS_BASE" 2>/dev/null || true
mkdir -p "$LISTS_BASE/bypass" "$LISTS_BASE/zapret" "$LISTS_BASE/nonbypass" "$LISTS_BASE/del-usr" 2>/dev/null || true
mkdir -p "$(dirname "$SYNC_LOG")" 2>/dev/null || true
mkdir -p "$TMP_DIR" 2>/dev/null || true
# Гарантируем наличие solitary.txt для del-usr (источник токенов для глобального удаления)
[ -f "${LISTS_BASE}/del-usr/solitary.txt" ] || : > "${LISTS_BASE}/del-usr/solitary.txt" 2>/dev/null || true

FAIL_COUNT=0

log "=== sync-allow-lists started $(date '+%Y-%m-%d %H:%M:%S') ==="
log ""

# Russian-services: extra из репо Vovanp70/Allow, обрабатывается первым, по умолчанию в nonbypass
EXTRA_RUS_URL="${EXTRA_REPO_URL}/Russian-services.txt"
if curl -sfL -o "$TMP_EXTRA" "$EXTRA_RUS_URL" 2>/dev/null; then
    # Источник: Russian-services.txt из репо
    > "$TMP_SRC"
    sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$TMP_EXTRA" 2>/dev/null | grep -v '^$' >> "$TMP_SRC" 2>/dev/null || true
    sort -u "$TMP_SRC" -o "$TMP_SRC"

    # Фильтрация по del-usr
    > "$TMP_DELUSR"
    if [ -d "${LISTS_BASE}/del-usr" ]; then
        for f in "${LISTS_BASE}/del-usr"/*; do
            [ -f "$f" ] || continue
            sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$f" 2>/dev/null | grep -v '^$'
        done | sort -u > "$TMP_DELUSR" 2>/dev/null || true
    fi
    > "$TMP_SRC_FILTERED"
    if [ -s "$TMP_DELUSR" ]; then
        while IFS= read -r token; do
            [ -z "$token" ] && continue
            if grep -Fxq "$token" "$TMP_DELUSR" 2>/dev/null; then continue; fi
            printf '%s\n' "$token" >> "$TMP_SRC_FILTERED"
        done < "$TMP_SRC"
    else
        cat "$TMP_SRC" > "$TMP_SRC_FILTERED" 2>/dev/null || true
    fi

    # S_user из *_user.txt
    > "$TMP_USER"
    for sub in bypass zapret nonbypass; do
        dir="${LISTS_BASE}/${sub}"
        [ ! -d "$dir" ] && continue
        for f in "$dir"/*_user.txt; do
            [ -f "$f" ] || continue
            sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$f" 2>/dev/null | grep -v '^$'
        done
    done | sort -u > "$TMP_USER" 2>/dev/null || true
    > "$TMP_SRC"
    if [ -s "$TMP_USER" ]; then
        while IFS= read -r token; do
            [ -z "$token" ] && continue
            if grep -Fxq "$token" "$TMP_USER" 2>/dev/null; then continue; fi
            printf '%s\n' "$token" >> "$TMP_SRC"
        done < "$TMP_SRC_FILTERED"
    else
        cat "$TMP_SRC_FILTERED" > "$TMP_SRC" 2>/dev/null || true
    fi
    sort -u "$TMP_SRC" -o "$TMP_SRC"

    # TARGET_FILE для Russian-services: существующий или nonbypass по умолчанию
    FILE_IN_BYPASS="${LISTS_BASE}/bypass/${RUS_SERVICES_OUT_NAME}"
    FILE_IN_ZAPRET="${LISTS_BASE}/zapret/${RUS_SERVICES_OUT_NAME}"
    FILE_IN_NONBYPASS="${LISTS_BASE}/nonbypass/${RUS_SERVICES_OUT_NAME}"
    FILE_IN_DEL_USR="${LISTS_BASE}/del-usr/${RUS_SERVICES_OUT_NAME}"
    if [ -f "$FILE_IN_BYPASS" ]; then
        TARGET_FILE="$FILE_IN_BYPASS"
    elif [ -f "$FILE_IN_ZAPRET" ]; then
        TARGET_FILE="$FILE_IN_ZAPRET"
    elif [ -f "$FILE_IN_NONBYPASS" ]; then
        TARGET_FILE="$FILE_IN_NONBYPASS"
    elif [ -f "$FILE_IN_DEL_USR" ]; then
        TARGET_FILE="$FILE_IN_DEL_USR"
    else
        TARGET_FILE="$FILE_IN_NONBYPASS"
    fi

    # S_old и статистика
    > "$TMP_OLD"
    if [ -f "$TARGET_FILE" ]; then
        sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$TARGET_FILE" 2>/dev/null | grep -v '^$' | sort -u > "$TMP_OLD" 2>/dev/null || true
    fi
    ADDED_COUNT=0
    REMOVED_COUNT=0
    > "$TMP_ADDED_LIST"
    > "$TMP_REMOVED_LIST"
    if [ -s "$TMP_SRC" ]; then
        while IFS= read -r token; do
            [ -z "$token" ] && continue
            if ! grep -Fxq "$token" "$TMP_OLD" 2>/dev/null; then
                ADDED_COUNT=$((ADDED_COUNT + 1))
                printf '%s\n' "$token" >> "$TMP_ADDED_LIST"
            fi
        done < "$TMP_SRC"
    fi
    if [ -s "$TMP_OLD" ]; then
        while IFS= read -r token; do
            [ -z "$token" ] && continue
            if ! grep -Fxq "$token" "$TMP_SRC" 2>/dev/null; then
                REMOVED_COUNT=$((REMOVED_COUNT + 1))
                printf '%s\n' "$token" >> "$TMP_REMOVED_LIST"
            fi
        done < "$TMP_OLD"
    fi

    > "$TMP_AUTO"
    if [ -s "$TMP_SRC" ]; then
        cat "$TMP_SRC" > "$TMP_AUTO" 2>/dev/null || true
    else
        : > "$TMP_AUTO"
    fi
    if mv "$TMP_AUTO" "$TARGET_FILE" 2>/dev/null; then
        ADDED_LIST_SUFFIX=""
        REMOVED_LIST_SUFFIX=""
        if [ "$ADDED_COUNT" -gt 0 ] && [ -s "$TMP_ADDED_LIST" ]; then
            out=""; first=1
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [ $first -eq 1 ]; then out="$line"; first=0; else out="$out, $line"; fi
            done < "$TMP_ADDED_LIST"
            [ -n "$out" ] && ADDED_LIST_SUFFIX=" [$out]"
        fi
        if [ "$REMOVED_COUNT" -gt 0 ] && [ -s "$TMP_REMOVED_LIST" ]; then
            out=""; first=1
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [ $first -eq 1 ]; then out="$line"; first=0; else out="$out, $line"; fi
            done < "$TMP_REMOVED_LIST"
            [ -n "$out" ] && REMOVED_LIST_SUFFIX=" [$out]"
        fi
        log "  ${RUS_SERVICES_OUT_NAME}:"
        log "    added: ${ADDED_COUNT}${ADDED_LIST_SUFFIX}"
        log "    removed: ${REMOVED_COUNT}${REMOVED_LIST_SUFFIX}"
    else
        log "  [ERROR] не удалось обновить $TARGET_FILE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

for entry in $LISTS; do
    [ -z "$entry" ] && continue
    LIST_URL="${entry%%|*}"
    OUT_NAME="${entry##*|}"

    # 2. Скачивание remote в временный файл
    if ! curl -sfL -o "$TMP_REMOTE" "$LIST_URL" 2>/dev/null; then
        log "  [ERROR] ошибка загрузки: $LIST_URL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        # Не трогаем соответствующий auto‑файл при ошибке источника
        continue
    fi

    # 3. Определение extra‑файла для списка (имя файла в репо Vovanp70/Allow)
    EXTRA_FILENAME=""
    case "$OUT_NAME" in
        Anime_hosts_auto.txt)
            EXTRA_FILENAME="Anime.txt"
            ;;
        YouTube_hosts_auto.txt)
            EXTRA_FILENAME="YouTube.txt"
            ;;
        Block_hosts_auto.txt)
            EXTRA_FILENAME="Block.txt"
            ;;
        GeoBlock_hosts_auto.txt)
            EXTRA_FILENAME="GeoBlock.txt"
            ;;
        News_hosts_auto.txt)
            EXTRA_FILENAME="News.txt"
            ;;
        Porn_hosts_auto.txt)
            EXTRA_FILENAME="Porn.txt"
            ;;
        HODCA_hosts_auto.txt)
            EXTRA_FILENAME="HODCA.txt"
            ;;
        Cloudflare_subnets_auto.txt)
            EXTRA_FILENAME="Cloudflare.txt"
            ;;
        Discord_hosts_auto.txt)
            EXTRA_FILENAME="Discord.txt"
            ;;
        Discord_subnets_auto.txt)
            EXTRA_FILENAME="Discord-Subnets.txt"
            ;;
        HDRezka_hosts_auto.txt)
            EXTRA_FILENAME="HDRezka.txt"
            ;;
        Meta_hosts_auto.txt)
            EXTRA_FILENAME="Meta.txt"
            ;;
        Meta_subnets_auto.txt)
            EXTRA_FILENAME="Meta-Subnets.txt"
            ;;
        Telegram_hosts_auto.txt)
            EXTRA_FILENAME="Telegram.txt"
            ;;
        Telegram_subnets_auto.txt)
            EXTRA_FILENAME="Telegram-Subnets.txt"
            ;;
        TikTok_hosts_auto.txt)
            EXTRA_FILENAME="TikTok.txt"
            ;;
        Twitter_hosts_auto.txt)
            EXTRA_FILENAME="Twitter.txt"
            ;;
        Twitter_subnets_auto.txt)
            EXTRA_FILENAME="Twitter-Subnets.txt"
            ;;
    esac

    # 4. Построение исходного множества S_src = (remote ∪ extra), нормализованного
    > "$TMP_SRC"
    # remote
    sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$TMP_REMOTE" 2>/dev/null | grep -v '^$' >> "$TMP_SRC" 2>/dev/null || true
    # extra из репо Vovanp70/Allow
    if [ -n "$EXTRA_FILENAME" ] && curl -sfL -o "$TMP_EXTRA" "${EXTRA_REPO_URL}/${EXTRA_FILENAME}" 2>/dev/null; then
        sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$TMP_EXTRA" 2>/dev/null | grep -v '^$' >> "$TMP_SRC" 2>/dev/null || true
    fi
    # Удаляем дубликаты
    sort -u "$TMP_SRC" -o "$TMP_SRC"

    # 5. Собрать S_delusr из LISTS_BASE/del-usr (включая solitary.txt)
    > "$TMP_DELUSR"
    if [ -d "${LISTS_BASE}/del-usr" ]; then
        for f in "${LISTS_BASE}/del-usr"/*; do
            [ -f "$f" ] || continue
            sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$f" 2>/dev/null | grep -v '^$'
        done | sort -u > "$TMP_DELUSR" 2>/dev/null || true
    fi

    # 6. TMP_SRC_FILTERED = S_src \ S_delusr
    > "$TMP_SRC_FILTERED"
    if [ -s "$TMP_DELUSR" ]; then
        while IFS= read -r token; do
            [ -z "$token" ] && continue
            if grep -Fxq "$token" "$TMP_DELUSR" 2>/dev/null; then
                continue
            fi
            printf '%s\n' "$token" >> "$TMP_SRC_FILTERED"
        done < "$TMP_SRC"
    else
        cat "$TMP_SRC" > "$TMP_SRC_FILTERED" 2>/dev/null || true
    fi

    # 7. Собрать S_user из всех *_user.txt в bypass/zapret/nonbypass (read-only)
    > "$TMP_USER"
    for sub in bypass zapret nonbypass; do
        dir="${LISTS_BASE}/${sub}"
        [ ! -d "$dir" ] && continue
        # Только файлы с суффиксом _user.txt
        for f in "$dir"/*_user.txt; do
            [ -f "$f" ] || continue
            sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$f" 2>/dev/null | grep -v '^$'
        done
    done | sort -u > "$TMP_USER" 2>/dev/null || true

    # 8. Построить финальное множество для auto: S_auto = TMP_SRC_FILTERED \ S_user
    > "$TMP_SRC"
    if [ -s "$TMP_USER" ]; then
        while IFS= read -r token; do
            [ -z "$token" ] && continue
            if grep -Fxq "$token" "$TMP_USER" 2>/dev/null; then
                # Уже есть в user‑файле — не дублируем в auto
                continue
            fi
            printf '%s\n' "$token" >> "$TMP_SRC"
        done < "$TMP_SRC_FILTERED"
    else
        cat "$TMP_SRC_FILTERED" > "$TMP_SRC" 2>/dev/null || true
    fi
    sort -u "$TMP_SRC" -o "$TMP_SRC"

    # 9. Определить TARGET_FILE для OUT_NAME (как и раньше)
    # del-usr: если юзер перенёс весь список туда — пополняем/пересобираем его там
    FILE_IN_BYPASS="${LISTS_BASE}/bypass/${OUT_NAME}"
    FILE_IN_ZAPRET="${LISTS_BASE}/zapret/${OUT_NAME}"
    FILE_IN_NONBYPASS="${LISTS_BASE}/nonbypass/${OUT_NAME}"
    FILE_IN_DEL_USR="${LISTS_BASE}/del-usr/${OUT_NAME}"
    if [ -f "$FILE_IN_BYPASS" ]; then
        TARGET_FILE="$FILE_IN_BYPASS"
    elif [ -f "$FILE_IN_ZAPRET" ]; then
        TARGET_FILE="$FILE_IN_ZAPRET"
    elif [ -f "$FILE_IN_NONBYPASS" ]; then
        TARGET_FILE="$FILE_IN_NONBYPASS"
    elif [ -f "$FILE_IN_DEL_USR" ]; then
        TARGET_FILE="$FILE_IN_DEL_USR"
    else
        TARGET_FILE="$FILE_IN_BYPASS"
    fi

    # 10. Построить S_old (предыдущее содержимое auto‑файла, нормализованное)
    > "$TMP_OLD"
    if [ -f "$TARGET_FILE" ]; then
        sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$TARGET_FILE" 2>/dev/null | grep -v '^$' | sort -u > "$TMP_OLD" 2>/dev/null || true
    fi

    # 11. Подсчёт добавленных и удалённых токенов (по множествам S_new=TMP_SRC и S_old=TMP_OLD)
    ADDED_COUNT=0
    REMOVED_COUNT=0
    > "$TMP_ADDED_LIST"
    > "$TMP_REMOVED_LIST"

    # Добавленные: S_new \ S_old
    if [ -s "$TMP_SRC" ]; then
        while IFS= read -r token; do
            [ -z "$token" ] && continue
            if ! grep -Fxq "$token" "$TMP_OLD" 2>/dev/null; then
                ADDED_COUNT=$((ADDED_COUNT + 1))
                printf '%s\n' "$token" >> "$TMP_ADDED_LIST"
            fi
        done < "$TMP_SRC"
    fi

    # Удалённые: S_old \ S_new
    if [ -s "$TMP_OLD" ]; then
        while IFS= read -r token; do
            [ -z "$token" ] && continue
            if ! grep -Fxq "$token" "$TMP_SRC" 2>/dev/null; then
                REMOVED_COUNT=$((REMOVED_COUNT + 1))
                printf '%s\n' "$token" >> "$TMP_REMOVED_LIST"
            fi
        done < "$TMP_OLD"
    fi

    # 12. Пересобрать auto‑файл атомарно: записать во временный файл и mv поверх TARGET_FILE
    > "$TMP_AUTO"
    if [ -s "$TMP_SRC" ]; then
        cat "$TMP_SRC" > "$TMP_AUTO" 2>/dev/null || true
    else
        # Источник пустой — создаём пустой auto‑файл
        : > "$TMP_AUTO"
    fi
    mv "$TMP_AUTO" "$TARGET_FILE" 2>/dev/null || {
        log "  [ERROR] не удалось обновить $TARGET_FILE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    }

    # 13. Вывод статистики по этому списку с перечислением токенов
    ADDED_LIST_SUFFIX=""
    REMOVED_LIST_SUFFIX=""

    if [ "$ADDED_COUNT" -gt 0 ] && [ -s "$TMP_ADDED_LIST" ]; then
        out=""
        first=1
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if [ $first -eq 1 ]; then
                out="$line"
                first=0
            else
                out="$out, $line"
            fi
        done < "$TMP_ADDED_LIST"
        [ -n "$out" ] && ADDED_LIST_SUFFIX=" [$out]"
    fi

    if [ "$REMOVED_COUNT" -gt 0 ] && [ -s "$TMP_REMOVED_LIST" ]; then
        out=""
        first=1
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if [ $first -eq 1 ]; then
                out="$line"
                first=0
            else
                out="$out, $line"
            fi
        done < "$TMP_REMOVED_LIST"
        [ -n "$out" ] && REMOVED_LIST_SUFFIX=" [$out]"
    fi

    log "  ${OUT_NAME}:"
    log "    added: ${ADDED_COUNT}${ADDED_LIST_SUFFIX}"
    log "    removed: ${REMOVED_COUNT}${REMOVED_LIST_SUFFIX}"
done

log ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    log "=== sync-allow-lists finished $(date '+%Y-%m-%d %H:%M:%S') (errors: $FAIL_COUNT) ==="
    exit 1
fi

# После успешной синхронизации обновляем ipset/dnsmasq из списков (nonbypass, bypass)
# Порядок: sync-allow-lists.sh → process-hosts.sh. Альтернатива: cron/init.d вызывает оба по очереди.
PROCESS_HOSTS_SCRIPT="${PROCESS_HOSTS_SCRIPT:-/opt/etc/allow/dnsmasq-full/process-hosts.sh}"
if [ -x "$PROCESS_HOSTS_SCRIPT" ] || [ -f "$PROCESS_HOSTS_SCRIPT" ]; then
    LISTS_BASE="${LISTS_BASE}" sh "$PROCESS_HOSTS_SCRIPT" || true
fi

log ""
log "=== sync-allow-lists finished $(date '+%Y-%m-%d %H:%M:%S') ==="
exit 0
