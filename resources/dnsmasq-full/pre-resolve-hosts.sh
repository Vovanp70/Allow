#!/bin/sh

# Скрипт для предварительного резолвинга доменов из hosts файлов в IP-адреса
# Резолвит домены и добавляет их в соответствующие ipset'ы
# Вызывается после process-hosts.sh для ускорения работы dnsmasq
# Оптимизированная версия с параллельными DNS-запросами и батчингом

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

IPSET_DIR="/opt/etc/allow/dnsmasq-full/ipsets"
MAX_PARALLEL_DNS=10  # Максимальное количество параллельных DNS-запросов

# Поиск mdig
find_mdig() {
    # Проверяем переменную окружения
    [ -n "$MDIG" ] && [ -x "$MDIG" ] && echo "$MDIG" && return 0
    
    # Проверяем стандартные пути
    for path in \
        "/opt/zapret/binaries/my/mdig" \
        "/opt/zapret/mdig/mdig" \
        "/opt/bin/mdig" \
        "/usr/local/bin/mdig" \
        "/usr/bin/mdig" \
        "$(which mdig 2>/dev/null)"; do
        [ -x "$path" ] && echo "$path" && return 0
    done
    
    return 1
}

# Функция для извлечения доменов из hosts файла (оптимизированная через awk)
extract_domains_from_hosts_file() {
    local hosts_file="$1"
    
    [ ! -f "$hosts_file" ] && return 0
    
    awk '
    BEGIN {
        in_hosts_block = 0
    }
    {
        # Убираем комментарии и пробелы
        gsub(/#.*$/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if (length($0) == 0) next
        
        # Проверяем начало блока HOSTS
        if ($0 ~ /@BLOCK_START:.*:HOSTS/) {
            in_hosts_block = 1
            next
        }
        
        # Проверяем конец блока
        if ($0 ~ /@BLOCK_END/) {
            in_hosts_block = 0
            next
        }
        
        # Пропускаем блоки IPS
        if ($0 ~ /@BLOCK_START:.*:IPS/) {
            in_hosts_block = 0
            next
        }
        
        # Обрабатываем только внутри блока HOSTS
        if (in_hosts_block != 1) next
        
        # Пропускаем строки, начинающиеся с IP-адреса
        if ($0 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?([[:space:]]|$)/) {
            # Если есть домены после IP, извлекаем их
            for (i = 2; i <= NF; i++) {
                if ($i != "" && $i !~ /^#/) {
                    domain = $i
                    # Убираем wildcard префикс
                    gsub(/^\*\./, "", domain)
                    if (length(domain) > 0) {
                        print domain
                    }
                }
            }
        } else {
            # Просто домен
            domain = $0
            # Убираем wildcard префикс
            gsub(/^\*\./, "", domain)
            if (length(domain) > 0) {
                print domain
            }
        }
    }
    ' "$hosts_file"
}

# Функция для извлечения прямых IP из hosts файла (оптимизированная)
extract_direct_ips_from_hosts_file() {
    local hosts_file="$1"
    
    [ ! -f "$hosts_file" ] && return 0
    
    awk '
    BEGIN {
        in_ips_block = 0
    }
    {
        # Убираем комментарии и пробелы
        gsub(/#.*$/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if (length($0) == 0) next
        
        # Проверяем начало блока IPS
        if ($0 ~ /@BLOCK_START:.*:IPS/) {
            in_ips_block = 1
            next
        }
        
        # Проверяем конец блока
        if ($0 ~ /@BLOCK_END/) {
            in_ips_block = 0
            next
        }
        
        # Пропускаем блоки HOSTS
        if ($0 ~ /@BLOCK_START:.*:HOSTS/) {
            in_ips_block = 0
            next
        }
        
        # Обрабатываем только внутри блока IPS или строки с IP в начале
        if (in_ips_block == 1 || $0 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?([[:space:]]|$)/) {
            if ($0 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?([[:space:]]|$)/) {
                print $1
            }
        }
    }
    ' "$hosts_file"
}

# Функция для параллельного резолвинга доменов
resolve_domains_parallel() {
    local domains_file="$1"
    local output_file="$2"
    local resolver="$3"
    
    if [ "$resolver" = "mdig" ] && [ -n "$MDIG" ]; then
        # Используем mdig для пакетного резолвинга (самый быстрый вариант)
        "$MDIG" --family=4 < "$domains_file" 2>/dev/null | \
            grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' > "$output_file" 2>/dev/null || true
    else
        # Используем параллельные запросы через xargs
        > "$output_file"
        if command -v xargs >/dev/null 2>&1; then
            # Параллельные запросы через xargs -P
            cat "$domains_file" | xargs -P "$MAX_PARALLEL_DNS" -I {} sh -c '
                domain="$1"
                ip=$(dig +short +time=3 +tries=1 A "$domain" 2>/dev/null | grep -E "^([0-9]{1,3}\.){3}[0-9]{1,3}$" | head -1)
                [ -n "$ip" ] && echo "$ip"
            ' _ {} >> "$output_file" 2>/dev/null || true
        else
            # Fallback: последовательные запросы (медленнее)
            while read -r domain; do
                [ -z "$domain" ] && continue
                ip=$(dig +short +time=3 +tries=1 A "$domain" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1)
                [ -n "$ip" ] && echo "$ip" >> "$output_file"
            done < "$domains_file"
        fi
    fi
}

# Функция для батчинга добавления IP в ipset
batch_add_ips_to_ipset() {
    local ipset_name="$1"
    local ips_file="$2"
    
    if [ ! -s "$ips_file" ]; then
        return 0
    fi
    
    # Сортируем и удаляем дубликаты
    sort -u "$ips_file" > "${ips_file}.sorted" 2>/dev/null || return 1
    
    # Добавляем IP пакетами (по 50 за раз для оптимизации)
    local count=0
    local batch=""
    while read -r ip; do
        [ -z "$ip" ] && continue
        if [ $count -eq 0 ]; then
            batch="${ip}/32"
        else
            batch="$batch\n${ip}/32"
        fi
        count=$((count + 1))
        
        if [ $count -ge 50 ]; then
            echo -e "$batch" | while read -r ip_line; do
                [ -n "$ip_line" ] && ipset add "$ipset_name" "$ip_line" 2>/dev/null || true
            done
            count=0
            batch=""
        fi
    done < "${ips_file}.sorted"
    
    # Добавляем оставшиеся IP
    if [ $count -gt 0 ] && [ -n "$batch" ]; then
        echo -e "$batch" | while read -r ip_line; do
            [ -n "$ip_line" ] && ipset add "$ipset_name" "$ip_line" 2>/dev/null || true
        done
    fi
    
    rm -f "${ips_file}.sorted" 2>/dev/null || true
}

# Функция для резолвинга доменов и добавления в ipset (оптимизированная)
resolve_and_populate_ipset() {
    local ipset_name="$1"
    local hosts_file="$2"
    local resolver="$3"
    local temp_domains_file="/tmp/domains_${ipset_name}_$$"
    local temp_ips_file="/tmp/ips_${ipset_name}_$$"
    local temp_direct_ips_file="/tmp/direct_ips_${ipset_name}_$$"
    
    # Проверяем существование ipset
    if ! ipset list "$ipset_name" >/dev/null 2>&1; then
        return 1
    fi
    
    # Извлекаем прямые IP из файла (оптимизированно)
    extract_direct_ips_from_hosts_file "$hosts_file" | sort -u > "$temp_direct_ips_file" 2>/dev/null
    
    # НЕ очищаем ipset - добавляем к существующим IP (оптимизация)
    # ipset flush "$ipset_name" 2>/dev/null || true
    
    # Восстанавливаем прямые IP батчами (если они были в файле)
    if [ -s "$temp_direct_ips_file" ]; then
        batch_add_ips_to_ipset "$ipset_name" "$temp_direct_ips_file"
    fi
    
    # Извлекаем домены из файла во временный файл (оптимизированно)
    extract_domains_from_hosts_file "$hosts_file" | sort -u > "$temp_domains_file" 2>/dev/null
    
    # Если нет доменов для резолвинга, удаляем временные файлы и выходим
    if [ ! -s "$temp_domains_file" ]; then
        rm -f "$temp_domains_file" "$temp_ips_file" "$temp_direct_ips_file" 2>/dev/null
        return 0
    fi
    
    # Резолвим домены параллельно (оптимизация)
    resolve_domains_parallel "$temp_domains_file" "$temp_ips_file" "$resolver"
    
    # Добавляем резолвленные IP в ipset батчами (оптимизация)
    if [ -s "$temp_ips_file" ]; then
        batch_add_ips_to_ipset "$ipset_name" "$temp_ips_file"
    fi
    
    # Удаляем временные файлы
    rm -f "$temp_domains_file" "$temp_ips_file" "$temp_direct_ips_file" 2>/dev/null
    
    return 0
}

# Основная функция
main() {
    local MDIG_PATH
    local resolver="dig"
    
    # Ищем mdig
    MDIG_PATH=$(find_mdig)
    if [ -n "$MDIG_PATH" ]; then
        MDIG="$MDIG_PATH"
        resolver="mdig"
    else
        # Проверяем наличие dig
        if ! command -v dig >/dev/null 2>&1; then
            return 1
        fi
    fi
    
    # Маппинг файлов на ipset'ы
    resolve_and_populate_ipset "nonbypass" "$IPSET_DIR/nonbypass.txt" "$resolver"
    resolve_and_populate_ipset "nonbypass" "$IPSET_DIR/zapret.txt" "$resolver"  # zapret → nonbypass
    resolve_and_populate_ipset "bypass" "$IPSET_DIR/bypass.txt" "$resolver"
    
    return 0
}

# Запуск
main "$@"
