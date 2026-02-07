#!/bin/sh

# Скрипт для обработки hosts файлов и генерации конфигурации dnsmasq
# Создает правила ipset=/domain/ipset для каждого домена из hosts файлов
# Добавляет IP адреса напрямую в ipset (если указаны в hosts файлах)
# Приоритет: nonbypass > bypass
# Источник списков: LISTS_BASE/nonbypass и LISTS_BASE/bypass (результат sync-allow-lists.sh).
# Папка zapret для ipset не обрабатывается.
#
# Порядок запуска: сначала sync-allow-lists.sh (заполняет LISTS_BASE), затем этот скрипт.
# sync-allow-lists.sh по успеху сам вызывает process-hosts.sh; можно также вызывать вручную
# или из cron/init.d после sync-allow-lists.sh.
#
# Ручная проверка: 1) sync-allow-lists.sh  2) process-hosts.sh
# 3) проверить: cat dnsmasq-ipset.conf (ipset=/domain/nonbypass, ipset=/domain/bypass)
# 4) ipset list nonbypass; ipset list bypass

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LISTS_BASE="${LISTS_BASE:-/opt/etc/allow/lists}"
PROCESS_SCRIPT_DIR="/opt/etc/allow/dnsmasq-full"
DNSMASQ_IPSET_CONF="/opt/etc/allow/dnsmasq-full/dnsmasq-ipset.conf"
DNSMASQ_IPSET_CONF_TMP="${DNSMASQ_IPSET_CONF}.tmp"

# Проверка наличия хотя бы одного каталога-источника
if [ ! -d "${LISTS_BASE}/nonbypass" ] && [ ! -d "${LISTS_BASE}/bypass" ]; then
    echo "process-hosts: ни ${LISTS_BASE}/nonbypass, ни ${LISTS_BASE}/bypass не найдены. Запустите sync-allow-lists.sh." >&2
    exit 1
fi

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

# Обрабатываем hosts файлы
echo "# Автоматически сгенерированная конфигурация dnsmasq для ipset" > "$DNSMASQ_IPSET_CONF_TMP"
echo "# Сгенерировано: $(date)" >> "$DNSMASQ_IPSET_CONF_TMP"
echo "" >> "$DNSMASQ_IPSET_CONF_TMP"

# Создаем необходимые ipset'ы
create_ipsets "nonbypass"
create_ipsets "bypass"

# Обрабатываем hosts файлы из LISTS_BASE (результат sync-allow-lists.sh)
# Приоритет: nonbypass > bypass. zapret не обрабатываем для ipset.
# nonbypass — первый, все файлы из LISTS_BASE/nonbypass/ → ipset nonbypass
if [ -d "${LISTS_BASE}/nonbypass" ]; then
    for f in "${LISTS_BASE}/nonbypass/"*.txt; do
        [ -f "$f" ] || continue
        process_hosts_file "$f" "nonbypass" "nonbypass: $(basename "$f")" "0"
    done
fi

# bypass — второй, с skip_processed=1 (домен из nonbypass не дублируем в bypass)
if [ -d "${LISTS_BASE}/bypass" ]; then
    for f in "${LISTS_BASE}/bypass/"*.txt; do
        [ -f "$f" ] || continue
        process_hosts_file "$f" "bypass" "bypass: $(basename "$f")" "1"
    done
fi

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
