#!/bin/sh
# Скачивает RAW-списки из itdoginfo/allow-domains в lists/itdoginfo/
# Источник: https://github.com/itdoginfo/allow-domains

BASE_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LISTS_DIR="${SCRIPT_DIR}/itdoginfo"
mkdir -p "$LISTS_DIR"

# URL -> локальный файл
# Формат: "URL|filename"
LISTS="
${BASE_URL}/Categories/anime.lst|Anime.txt
${BASE_URL}/Categories/block.lst|Block.txt
${BASE_URL}/Categories/geoblock.lst|GeoBlock.txt
${BASE_URL}/Categories/news.lst|News.txt
${BASE_URL}/Categories/porn.lst|Porn.txt
${BASE_URL}/Categories/hodca.lst|HODCA.txt
${BASE_URL}/Subnets/IPv4/cloudflare.lst|Cloudflare.txt
${BASE_URL}/Services/discord.lst|Discord.txt
${BASE_URL}/Subnets/IPv4/discord.lst|Discord-Subnets.txt
${BASE_URL}/Services/hdrezka.lst|HDRezka.txt
${BASE_URL}/Services/meta.lst|Meta.txt
${BASE_URL}/Subnets/IPv4/meta.lst|Meta-Subnets.txt
${BASE_URL}/Services/telegram.lst|Telegram.txt
${BASE_URL}/Subnets/IPv4/telegram.lst|Telegram-Subnets.txt
${BASE_URL}/Services/tiktok.lst|TikTok.txt
${BASE_URL}/Services/twitter.lst|Twitter.txt
${BASE_URL}/Subnets/IPv4/twitter.lst|Twitter-Subnets.txt
${BASE_URL}/Services/youtube.lst|YouTube.txt
"

download() {
    url="$1"
    out="$2"
    name="$(basename "$url")"
    printf "  %-35s -> %-25s ... " "$name" "$out"
    if curl -sfL -o "${out}.tmp" "$url" 2>/dev/null; then
        mv "${out}.tmp" "$out"
        count=$(grep -cEv '^[[:space:]]*$|^#' "$out" 2>/dev/null || echo "0")
        echo "OK ($count строк)"
        return 0
    fi
    rm -f "${out}.tmp"
    echo "FAIL"
    return 1
}

echo "Скачивание RAW-списков itdoginfo/allow-domains"
echo "=============================================="

success=0
fail=0
for entry in $LISTS; do
    [ -z "$entry" ] && continue
    url="${entry%%|*}"
    out="${LISTS_DIR}/${entry##*|}"
    if download "$url" "$out"; then
        success=$((success + 1))
    else
        fail=$((fail + 1))
    fi
done

echo "=============================================="
echo "Готово: $success успешно, $fail ошибок"
exit $fail
