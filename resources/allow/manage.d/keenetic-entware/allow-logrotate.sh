#!/bin/sh
#
# allow-logrotate.sh
# Ротация логов компонентов ALLOW по размеру (copytruncate).
# Совместимо с BusyBox / ash.
#
# По умолчанию:
# - dnsmasq* : 2MB, хранить 5 ротаций
# - остальное: 1MB, хранить 3 ротации
#
# Настройка через переменные окружения:
# - ALLOW_LOGROTATE_DNSMASQ_MAX_BYTES (default: 2097152)
# - ALLOW_LOGROTATE_DNSMASQ_KEEP      (default: 5)
# - ALLOW_LOGROTATE_OTHER_MAX_BYTES  (default: 1048576)
# - ALLOW_LOGROTATE_OTHER_KEEP       (default: 3)
# - ALLOW_LOGROTATE_COMPRESS         (default: 0)  # gzip старых ротаций (.2..N)
#

set +e

DNSMASQ_MAX_BYTES="${ALLOW_LOGROTATE_DNSMASQ_MAX_BYTES:-2097152}"
DNSMASQ_KEEP="${ALLOW_LOGROTATE_DNSMASQ_KEEP:-5}"
OTHER_MAX_BYTES="${ALLOW_LOGROTATE_OTHER_MAX_BYTES:-1048576}"
OTHER_KEEP="${ALLOW_LOGROTATE_OTHER_KEEP:-3}"
COMPRESS="${ALLOW_LOGROTATE_COMPRESS:-0}"

LOCKDIR="/tmp/allow-logrotate.lock"
if mkdir "$LOCKDIR" 2>/dev/null; then
  trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM
else
  # Уже запущено в другом процессе
  exit 0
fi

log() {
  # Умышленно без tee: cron обычно перенаправляет в /dev/null
  TS="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  echo "[$TS] $*"
}

file_size_bytes() {
  # wc -c печатает число и newline; убираем пробелы
  wc -c < "$1" 2>/dev/null | tr -d ' \n\r'
}

rotate_copytruncate() {
  FILE="$1"
  MAX_BYTES="$2"
  KEEP="$3"

  [ -n "$FILE" ] || return 0
  [ -n "$MAX_BYTES" ] || return 0
  [ -n "$KEEP" ] || KEEP=1
  [ "$KEEP" -ge 1 ] 2>/dev/null || KEEP=1

  [ -f "$FILE" ] || return 0

  SIZE="$(file_size_bytes "$FILE")"
  [ -n "$SIZE" ] || return 0

  # Если файл пустой или меньше порога — ничего не делаем
  [ "$SIZE" -gt "$MAX_BYTES" ] 2>/dev/null || return 0

  # Сдвигаем ротации: .(KEEP-1)->.KEEP и т.д.
  i="$KEEP"
  while [ "$i" -ge 1 ] 2>/dev/null; do
    if [ "$i" -eq "$KEEP" ] 2>/dev/null; then
      rm -f "$FILE.$i" "$FILE.$i.gz" 2>/dev/null || true
    else
      next=$((i + 1))
      if [ -f "$FILE.$i.gz" ]; then
        mv -f "$FILE.$i.gz" "$FILE.$next.gz" 2>/dev/null || true
      fi
      if [ -f "$FILE.$i" ]; then
        mv -f "$FILE.$i" "$FILE.$next" 2>/dev/null || true
      fi
    fi
    i=$((i - 1))
  done

  # Копируем текущее содержимое в .1 и обнуляем исходник (сохраняем inode)
  if cp -f "$FILE" "$FILE.1" 2>/dev/null; then
    : > "$FILE" 2>/dev/null || true
  else
    # Если не получилось скопировать — не трогаем исходник
    return 0
  fi

  # Опционально: gzip старых ротаций (.2..KEEP), оставляя .1 несжатым
  if [ "$COMPRESS" = "1" ] && command -v gzip >/dev/null 2>&1; then
    j=2
    while [ "$j" -le "$KEEP" ] 2>/dev/null; do
      if [ -f "$FILE.$j" ] && [ ! -f "$FILE.$j.gz" ]; then
        gzip -f "$FILE.$j" 2>/dev/null || true
      fi
      j=$((j + 1))
    done
  fi
}

# DNSMASQ logs (самые шумные)
rotate_copytruncate "/opt/var/log/allow/dnsmasq.log" "$DNSMASQ_MAX_BYTES" "$DNSMASQ_KEEP"
rotate_copytruncate "/opt/var/log/allow/dnsmasq-family.log" "$DNSMASQ_MAX_BYTES" "$DNSMASQ_KEEP"

# Stubby logs
rotate_copytruncate "/opt/var/log/allow/stubby.log" "$OTHER_MAX_BYTES" "$OTHER_KEEP"
rotate_copytruncate "/opt/var/log/allow/stubby-family.log" "$OTHER_MAX_BYTES" "$OTHER_KEEP"

# Общий лог автозапуска
rotate_copytruncate "/opt/var/log/allow/allowstart.log" "$OTHER_MAX_BYTES" "$OTHER_KEEP"

# sync-allow-lists (1 MB)
rotate_copytruncate "/opt/var/log/allow/sync-allow-lists.log" "$OTHER_MAX_BYTES" "$OTHER_KEEP"

# Логи компонентов в /opt/var/log/allow/** (install/runtime)
for f in /opt/var/log/allow/*.log /opt/var/log/allow/*/*.log /opt/var/log/allow/*/*.log.* /opt/var/log/allow/*/error.log; do
  [ -e "$f" ] || continue
  # Не трогаем уже-ротированные файлы вида *.log.N / *.log.N.gz (их вращает базовый файл)
  case "$f" in
    *.log.[0-9]*|*.log.[0-9]*.gz) continue ;;
  esac
  rotate_copytruncate "$f" "$OTHER_MAX_BYTES" "$OTHER_KEEP"
done

exit 0
