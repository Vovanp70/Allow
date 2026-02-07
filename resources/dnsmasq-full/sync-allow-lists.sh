#!/bin/sh
# Синхронизация списков allow: скачивает списки из itdoginfo/allow-domains,
# создаёт /opt/etc/allow/lists/{bypass,zapret,nonbypass,del-usr}, пересобирает auto‑листы
# из upstream+extra с учётом del-usr и user‑файлов (*_user.txt, только чтение).

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

LISTS_BASE="${LISTS_BASE:-/opt/etc/allow/lists}"
TMP_DIR="${TMP_DIR:-/tmp}"
BASE_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main"
EXTRA_BASE="${EXTRA_BASE:-${LISTS_BASE}/itdoginfo-extra}"
RUS_SERVICES_OUT_NAME="russian_services_hosts_auto.txt"

# Формат: "URL|имя_файла" (без пробелов вокруг |)
LISTS="
${BASE_URL}/Categories/anime.lst|anime_hosts_auto.txt
${BASE_URL}/Services/youtube.lst|youtube_hosts_auto.txt
${BASE_URL}/Categories/block.lst|block_hosts_auto.txt
${BASE_URL}/Categories/geoblock.lst|geoblock_hosts_auto.txt
${BASE_URL}/Categories/news.lst|news_hosts_auto.txt
${BASE_URL}/Categories/porn.lst|porn_hosts_auto.txt
${BASE_URL}/Categories/hodca.lst|hodca_hosts_auto.txt
${BASE_URL}/Subnets/IPv4/cloudflare.lst|cloudflare_subnets_auto.txt
${BASE_URL}/Services/discord.lst|discord_hosts_auto.txt
${BASE_URL}/Subnets/IPv4/discord.lst|discord_subnets_auto.txt
${BASE_URL}/Services/hdrezka.lst|hdrezka_hosts_auto.txt
${BASE_URL}/Services/meta.lst|meta_hosts_auto.txt
${BASE_URL}/Subnets/IPv4/meta.lst|meta_subnets_auto.txt
${BASE_URL}/Services/telegram.lst|telegram_hosts_auto.txt
${BASE_URL}/Subnets/IPv4/telegram.lst|telegram_subnets_auto.txt
${BASE_URL}/Services/tiktok.lst|tiktok_hosts_auto.txt
${BASE_URL}/Services/twitter.lst|twitter_hosts_auto.txt
${BASE_URL}/Subnets/IPv4/twitter.lst|twitter_subnets_auto.txt
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

cleanup() {
    rm -f "$TMP_REMOTE" "$TMP_SRC" "$TMP_SRC_FILTERED" \
          "$TMP_DELUSR" "$TMP_USER" "$TMP_AUTO" "$TMP_OLD" \
          "$TMP_ADDED_LIST" "$TMP_REMOVED_LIST" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Создание директорий (POSIX: без brace expansion)
mkdir -p "$LISTS_BASE" 2>/dev/null || true
mkdir -p "$LISTS_BASE/bypass" "$LISTS_BASE/zapret" "$LISTS_BASE/nonbypass" "$LISTS_BASE/del-usr" 2>/dev/null || true
mkdir -p "$TMP_DIR" 2>/dev/null || true

FAIL_COUNT=0

# Russian-services: локальный список (только extra), обрабатывается первым, по умолчанию в nonbypass
EXTRA_RUS="${EXTRA_BASE}/Russian-services.txt"
if [ -f "$EXTRA_RUS" ]; then
    # Источник: только Russian-services.txt
    > "$TMP_SRC"
    sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$EXTRA_RUS" 2>/dev/null | grep -v '^$' >> "$TMP_SRC" 2>/dev/null || true
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
        echo "${RUS_SERVICES_OUT_NAME}: added ${ADDED_COUNT}${ADDED_LIST_SUFFIX}, removed ${REMOVED_COUNT}${REMOVED_LIST_SUFFIX}"
    else
        echo "sync-allow-lists: не удалось обновить $TARGET_FILE" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

for entry in $LISTS; do
    [ -z "$entry" ] && continue
    LIST_URL="${entry%%|*}"
    OUT_NAME="${entry##*|}"

    # 2. Скачивание remote в временный файл
    if ! curl -sfL -o "$TMP_REMOTE" "$LIST_URL" 2>/dev/null; then
        echo "sync-allow-lists: ошибка загрузки $LIST_URL" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
        # Не трогаем соответствующий auto‑файл при ошибке источника
        continue
    fi

    # 3. Определение extra‑файла для списка
    EXTRA_FILE=""
    case "$OUT_NAME" in
        anime_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/Anime.txt"
            ;;
        youtube_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/YouTube.txt"
            ;;
        block_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/Block.txt"
            ;;
        geoblock_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/GeoBlock.txt"
            ;;
        news_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/News.txt"
            ;;
        porn_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/Porn.txt"
            ;;
        hodca_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/HODCA.txt"
            ;;
        cloudflare_subnets_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/Cloudflare.txt"
            ;;
        discord_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/Discord.txt"
            ;;
        discord_subnets_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/Discord-Subnets.txt"
            ;;
        hdrezka_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/HDRezka.txt"
            ;;
        meta_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/Meta.txt"
            ;;
        meta_subnets_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/Meta-Subnets.txt"
            ;;
        telegram_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/Telegram.txt"
            ;;
        telegram_subnets_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/Telegram-Subnets.txt"
            ;;
        tiktok_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/TikTok.txt"
            ;;
        twitter_hosts_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/Twitter.txt"
            ;;
        twitter_subnets_auto.txt)
            EXTRA_FILE="${EXTRA_BASE}/Twitter-Subnets.txt"
            ;;
    esac

    # 4. Построение исходного множества S_src = (remote ∪ extra), нормализованного
    > "$TMP_SRC"
    # remote
    sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$TMP_REMOTE" 2>/dev/null | grep -v '^$' >> "$TMP_SRC" 2>/dev/null || true
    # extra
    if [ -n "$EXTRA_FILE" ] && [ -f "$EXTRA_FILE" ]; then
        sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$EXTRA_FILE" 2>/dev/null | grep -v '^$' >> "$TMP_SRC" 2>/dev/null || true
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
        echo "sync-allow-lists: не удалось обновить $TARGET_FILE" >&2
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

    echo "${OUT_NAME}: added ${ADDED_COUNT}${ADDED_LIST_SUFFIX}, removed ${REMOVED_COUNT}${REMOVED_LIST_SUFFIX}"
done

[ "$FAIL_COUNT" -gt 0 ] && exit 1

# После успешной синхронизации обновляем ipset/dnsmasq из списков (nonbypass, bypass)
# Порядок: sync-allow-lists.sh → process-hosts.sh. Альтернатива: cron/init.d вызывает оба по очереди.
PROCESS_HOSTS_SCRIPT="${PROCESS_HOSTS_SCRIPT:-/opt/etc/allow/dnsmasq-full/process-hosts.sh}"
if [ -x "$PROCESS_HOSTS_SCRIPT" ] || [ -f "$PROCESS_HOSTS_SCRIPT" ]; then
    LISTS_BASE="${LISTS_BASE}" sh "$PROCESS_HOSTS_SCRIPT" || true
fi

exit 0
