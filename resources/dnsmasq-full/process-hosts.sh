#!/bin/sh

# Скрипт для обработки hosts файлов и генерации конфигурации dnsmasq
# Создает правила ipset=/domain/ipset для каждого домена из hosts файлов
# Добавляет IP адреса напрямую в ipset (если указаны в hosts файлах)
# Приоритет: nonbypass > bypass
# Оптимизированная версия с батчингом и кэшированием

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

IPSET_DIR="/opt/etc/allow/dnsmasq-full/ipsets"
PROCESS_SCRIPT_DIR="/opt/etc/allow/dnsmasq-full"
DNSMASQ_IPSET_CONF="/opt/etc/allow/dnsmasq-full/dnsmasq-ipset.conf"
DNSMASQ_IPSET_CONF_TMP="${DNSMASQ_IPSET_CONF}.tmp"

# Создаем директории для hosts-файлов, если не существует
mkdir -p "$IPSET_DIR" 2>/dev/null || true

# Создаем временный файл для конфигурации
> "$DNSMASQ_IPSET_CONF_TMP"

# Временные файлы для батчинга операций
PROCESSED_DOMAINS_FILE="/tmp/processed_domains_$$"
IPS_TO_ADD_NONBYPASS="/tmp/ips_nonbypass_$$"
IPS_TO_ADD_BYPASS="/tmp/ips_bypass_$$"

# Очистка временных файлов при выходе
cleanup_temp_files() {
    rm -f "$PROCESSED_DOMAINS_FILE" "$IPS_TO_ADD_NONBYPASS" "$IPS_TO_ADD_BYPASS" 2>/dev/null || true
}
trap cleanup_temp_files EXIT

# Инициализация временных файлов
> "$PROCESSED_DOMAINS_FILE"
> "$IPS_TO_ADD_NONBYPASS"
> "$IPS_TO_ADD_BYPASS"

# Функция для быстрой проверки домена (использует сортированный файл)
is_domain_processed() {
    local domain="$1"
    [ -s "$PROCESSED_DOMAINS_FILE" ] && grep -Fxq "$domain" "$PROCESSED_DOMAINS_FILE" 2>/dev/null
}

# Функция для добавления домена в список обработанных
mark_domain_processed() {
    local domain="$1"
    echo "$domain" >> "$PROCESSED_DOMAINS_FILE" 2>/dev/null || true
}

# Функция для добавления IP в батч
add_ip_to_batch() {
    local ip="$1"
    local ipset_name="$2"
    local batch_file=""
    
    case "$ipset_name" in
        nonbypass) batch_file="$IPS_TO_ADD_NONBYPASS" ;;
        bypass) batch_file="$IPS_TO_ADD_BYPASS" ;;
        *) return 1 ;;
    esac
    
    # Проверяем, содержит ли IP маску подсети (CIDR)
    if echo "$ip" | grep -qE '/[0-9]{1,2}$'; then
        echo "$ip" >> "$batch_file"
    else
        echo "${ip}/32" >> "$batch_file"
    fi
}

# Функция для батчинга добавления IP в ipset
batch_add_ips() {
    local ipset_name="$1"
    local batch_file=""
    
    case "$ipset_name" in
        nonbypass) batch_file="$IPS_TO_ADD_NONBYPASS" ;;
        bypass) batch_file="$IPS_TO_ADD_BYPASS" ;;
        *) return 1 ;;
    esac
    
    if [ ! -s "$batch_file" ]; then
        return 0
    fi
    
    # Сортируем и удаляем дубликаты
    sort -u "$batch_file" > "${batch_file}.sorted" 2>/dev/null || return 1
    
    # Добавляем IP пакетами (по 100 за раз для оптимизации)
    local count=0
    local batch=""
    while read -r ip; do
        [ -z "$ip" ] && continue
        if [ $count -eq 0 ]; then
            batch="$ip"
        else
            batch="$batch\n$ip"
        fi
        count=$((count + 1))
        
        if [ $count -ge 100 ]; then
            echo -e "$batch" | while read -r ip_line; do
                [ -n "$ip_line" ] && ipset add "$ipset_name" "$ip_line" 2>/dev/null || true
            done
            count=0
            batch=""
        fi
    done < "${batch_file}.sorted"
    
    # Добавляем оставшиеся IP
    if [ $count -gt 0 ] && [ -n "$batch" ]; then
        echo -e "$batch" | while read -r ip_line; do
            [ -n "$ip_line" ] && ipset add "$ipset_name" "$ip_line" 2>/dev/null || true
        done
    fi
    
    rm -f "${batch_file}.sorted" 2>/dev/null || true
    > "$batch_file"
}

# Функция для обработки hosts файла (оптимизированная)
process_hosts_file() {
    local hosts_file="$1"
    local ipset_name="$2"
    local description="$3"
    local skip_processed="${4:-0}"
    
    if [ ! -f "$hosts_file" ]; then
        return 0
    fi
    
    echo "# $description" >> "$DNSMASQ_IPSET_CONF_TMP"
    echo "# Источник: $hosts_file" >> "$DNSMASQ_IPSET_CONF_TMP"
    
    # Определяем файл для батчинга IP
    local batch_file=""
    case "$ipset_name" in
        nonbypass) batch_file="$IPS_TO_ADD_NONBYPASS" ;;
        bypass) batch_file="$IPS_TO_ADD_BYPASS" ;;
        *) return 1 ;;
    esac
    
    # Используем awk для более быстрой обработки
    awk -v ipset_name="$ipset_name" -v skip_processed="$skip_processed" -v processed_file="$PROCESSED_DOMAINS_FILE" -v conf_file="$DNSMASQ_IPSET_CONF_TMP" -v batch_file="$batch_file" '
    BEGIN {
        # Загружаем обработанные домены в память (если нужно)
        if (skip_processed == 1 && length(processed_file) > 0) {
            while ((getline domain < processed_file) > 0) {
                processed[domain] = 1
            }
            close(processed_file)
        }
    }
    {
        # Убираем комментарии и пробелы
        gsub(/#.*$/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if (length($0) == 0) next
        
        # Проверяем формат: IP[/mask] или domain
        if ($0 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?([[:space:]]|$)/) {
            ip = $1
            domain_count = NF
            
            # Добавляем IP в батч
            if (length(ip) > 0) {
                if (ip ~ /\/[0-9]{1,2}$/) {
                    print ip >> batch_file
                } else {
                    print ip "/32" >> batch_file
                }
            }
            
            # Обрабатываем домены
            if (domain_count > 1) {
                for (i = 2; i <= domain_count; i++) {
                    domain = $i
                    if (length(domain) == 0 || domain ~ /^#/) continue
                    
                    # Проверяем приоритет
                    if (skip_processed == 1 && domain in processed) continue
                    if (skip_processed == 1) processed[domain] = 1
                    
                    # Обрабатываем wildcard (*.example.com)
                    # В dnsmasq для ipset используем обычный синтаксис: ipset=/example.com/ipset
                    # (покрывает домен и поддомены). Синтаксис вида "#." не является стандартным.
                    if (domain ~ /^\*\./) {
                        clean_domain = substr(domain, 3)
                        if (length(clean_domain) > 0) {
                            print "ipset=/" clean_domain "/" ipset_name >> conf_file
                        }
                    } else {
                        print "ipset=/" domain "/" ipset_name >> conf_file
                    }
                }
            }
        } else {
            # Просто домен
            domain = $0
            
            # Проверяем приоритет
            if (skip_processed == 1 && domain in processed) next
            if (skip_processed == 1) processed[domain] = 1
            
            # Обрабатываем wildcard (*.example.com)
            # В dnsmasq для ipset используем обычный синтаксис: ipset=/example.com/ipset
            # (покрывает домен и поддомены). Синтаксис вида "#." не является стандартным.
            if (domain ~ /^\*\./) {
                clean_domain = substr(domain, 3)
                if (length(clean_domain) > 0) {
                    print "ipset=/" clean_domain "/" ipset_name >> conf_file
                }
            } else {
                print "ipset=/" domain "/" ipset_name >> conf_file
            }
        }
    }
    END {
        # Сохраняем обработанные домены обратно в файл
        if (skip_processed == 1) {
            for (domain in processed) {
                print domain >> processed_file
            }
            close(processed_file)
        }
    }
    ' "$hosts_file"
    
    echo "" >> "$DNSMASQ_IPSET_CONF_TMP"
}

# Создаем ipset'ы (hash:net для всех)
create_ipsets() {
    local ipset_name="$1"
    if ! ipset list "$ipset_name" >/dev/null 2>&1; then
        echo "Создание ipset '$ipset_name' (hash:net)..." >&2
        ipset create "$ipset_name" hash:net 2>/dev/null || {
            echo "Ошибка: не удалось создать ipset '$ipset_name'" >&2
            return 1
        }
    fi
    return 0
}

# Функция для извлечения доменов из hosts файла (только из блоков HOSTS)
extract_hosts_domains() {
    local hosts_file="$1"
    local temp_domains_file="/tmp/bypass_domains_$$"
    
    [ ! -f "$hosts_file" ] && return 1
    
    # Извлекаем домены из блоков HOSTS
    awk '
    BEGIN {
        in_hosts_block = 0
    }
    {
        # Сначала проверяем маркеры блоков (до удаления комментариев)
        # Проверяем начало блока HOSTS (может быть с # в начале)
        if ($0 ~ /#\s*@BLOCK_START:.*:HOSTS/ || $0 ~ /@BLOCK_START:.*:HOSTS/) {
            in_hosts_block = 1
            next
        }
        
        # Проверяем конец блока
        if ($0 ~ /#\s*@BLOCK_END/ || $0 ~ /@BLOCK_END/) {
            in_hosts_block = 0
            next
        }
        
        # Пропускаем блоки IPS
        if ($0 ~ /#\s*@BLOCK_START:.*:IPS/ || $0 ~ /@BLOCK_START:.*:IPS/) {
            in_hosts_block = 0
            next
        }
        
        # Теперь убираем комментарии и пробелы
        gsub(/#.*$/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if (length($0) == 0) next
        
        # Обрабатываем только внутри блока HOSTS
        if (in_hosts_block != 1) next
        
        # Пропускаем строки, начинающиеся с IP-адреса
        if ($0 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?([[:space:]]|$)/) {
            # Если есть домены после IP, извлекаем их
            for (i = 2; i <= NF; i++) {
                if ($i != "" && $i !~ /^#/) {
                    domain = $i
                    # Убираем wildcard префикс для сохранения
                    gsub(/^\*\./, "", domain)
                    if (length(domain) > 0) {
                        print domain
                    }
                }
            }
        } else {
            # Просто домен
            domain = $0
            # Убираем wildcard префикс для сохранения
            gsub(/^\*\./, "", domain)
            if (length(domain) > 0) {
                print domain
            }
        }
    }
    ' "$hosts_file" | sort -u > "$temp_domains_file" 2>/dev/null
    
    if [ -s "$temp_domains_file" ]; then
        cat "$temp_domains_file"
        rm -f "$temp_domains_file" 2>/dev/null || true
        return 0
    else
        rm -f "$temp_domains_file" 2>/dev/null || true
        return 1
    fi
}

# Функция для синхронизации доменов из bypass.txt в netrogat.txt
sync_bypass_to_netrogat() {
    local bypass_file="$IPSET_DIR/bypass.txt"
    local netrogat_file="/opt/zapret/lists/netrogat.txt"
    
    # Проверяем наличие файла netrogat.txt
    if [ ! -f "$netrogat_file" ]; then
        echo "Файл $netrogat_file не существует, пропускаю синхронизацию" >&2
        return 0  # Файл не существует, ничего не делаем
    fi
    
    echo "Начинаю синхронизацию доменов из $bypass_file в $netrogat_file" >&2
    
    # Проверяем наличие bypass.txt
    if [ ! -f "$bypass_file" ]; then
        echo "Ошибка: файл $bypass_file не найден" >&2
        return 1
    fi
    
    # Извлекаем домены из bypass.txt
    local temp_bypass_domains="/tmp/bypass_domains_for_netrogat_$$"
    extract_hosts_domains "$bypass_file" > "$temp_bypass_domains" 2>/dev/null
    
    if [ ! -s "$temp_bypass_domains" ]; then
        echo "Предупреждение: не удалось извлечь домены из $bypass_file или файл пустой" >&2
        rm -f "$temp_bypass_domains" 2>/dev/null || true
        return 0  # Нет доменов для синхронизации
    fi
    
    local domains_count=$(wc -l < "$temp_bypass_domains" 2>/dev/null || echo "0")
    echo "Извлечено доменов из bypass.txt: $domains_count" >&2
    
    # Создаем временный файл для нового содержимого netrogat.txt
    local temp_netrogat="/tmp/netrogat_$$"
    
    # Читаем существующие домены из netrogat.txt (если есть)
    local existing_domains="/tmp/netrogat_existing_$$"
    if [ -s "$netrogat_file" ]; then
        # Извлекаем только валидные домены (не комментарии, не пустые строки)
        grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$netrogat_file" | \
            sed 's/[[:space:]]*#.*$//' | \
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
            grep -vE '^$' > "$existing_domains" 2>/dev/null || true
        local existing_count=$(wc -l < "$existing_domains" 2>/dev/null || echo "0")
        echo "Существующих доменов в netrogat.txt: $existing_count" >&2
    else
        > "$existing_domains"
        echo "Файл netrogat.txt пустой или не существует" >&2
    fi
    
    # Объединяем существующие и новые домены, удаляем дубликаты
    cat "$existing_domains" "$temp_bypass_domains" 2>/dev/null | sort -u > "$temp_netrogat" 2>/dev/null
    
    # Сохраняем обновленный файл
    if [ -s "$temp_netrogat" ]; then
        local total_count=$(wc -l < "$temp_netrogat" 2>/dev/null || echo "0")
        echo "Всего доменов после объединения: $total_count" >&2
        
        # Создаем директорию, если не существует
        mkdir -p "$(dirname "$netrogat_file")" 2>/dev/null || true
        
        # Сохраняем с сохранением прав доступа (если файл существовал)
        if [ -f "$netrogat_file" ]; then
            cp "$netrogat_file" "${netrogat_file}.bak" 2>/dev/null || true
        fi
        
        if cp "$temp_netrogat" "$netrogat_file" 2>/dev/null; then
            echo "Синхронизировано доменов из bypass.txt в netrogat.txt: $domains_count" >&2
        else
            echo "Ошибка: не удалось обновить $netrogat_file (возможно, нет прав доступа)" >&2
            rm -f "$temp_bypass_domains" "$temp_netrogat" "$existing_domains" 2>/dev/null || true
            return 1
        fi
    else
        echo "Ошибка: временный файл пустой, нечего сохранять" >&2
    fi
    
    # Очистка временных файлов
    rm -f "$temp_bypass_domains" "$temp_netrogat" "$existing_domains" 2>/dev/null || true
    
    return 0
}

# Обрабатываем hosts файлы
echo "# Автоматически сгенерированная конфигурация dnsmasq для ipset" > "$DNSMASQ_IPSET_CONF_TMP"
echo "# Сгенерировано: $(date)" >> "$DNSMASQ_IPSET_CONF_TMP"
echo "" >> "$DNSMASQ_IPSET_CONF_TMP"

# Создаем необходимые ipset'ы
create_ipsets "nonbypass"
create_ipsets "bypass"

# Обрабатываем hosts файлы в порядке приоритета (высший приоритет первым)
# Приоритет: nonbypass > zapret > bypass
# nonbypass - самый высокий приоритет, обрабатывается первым, не пропускаем
process_hosts_file "$IPSET_DIR/nonbypass.txt" "nonbypass" "Исключения (высший приоритет)" "0"

# zapret обрабатываем с проверкой приоритета (домены попадают в ipset nonbypass)
process_hosts_file "$IPSET_DIR/zapret.txt" "nonbypass" "Zapret → nonbypass" "1"

# bypass обрабатываем с проверкой приоритета
process_hosts_file "$IPSET_DIR/bypass.txt" "bypass" "Обход → bypass" "1"

# Синхронизируем домены из bypass.txt в netrogat.txt (если файл существует)
sync_bypass_to_netrogat

# Добавляем IP в ipset батчами (оптимизация)
batch_add_ips "nonbypass"
batch_add_ips "bypass"

# Перемещаем временный файл в финальный
mv "$DNSMASQ_IPSET_CONF_TMP" "$DNSMASQ_IPSET_CONF"

echo "Конфигурация dnsmasq для ipset обновлена: $DNSMASQ_IPSET_CONF"

# Запускаем предварительный резолвинг доменов в фоне (не блокируем запуск)
if [ -f "${PROCESS_SCRIPT_DIR}/pre-resolve-hosts.sh" ]; then
    sh "${PROCESS_SCRIPT_DIR}/pre-resolve-hosts.sh" >/dev/null 2>&1 &
fi
