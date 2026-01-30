#!/bin/sh
set -eu

# setsettings.sh
# Управляет "System DNS" на Keenetic через ndmc:
# - preset: привести System DNS к 1.1.1.1 + 8.8.8.8 (может временно переключить engine с public на opkg)
# - apply (по умолчанию): backup -> set System DNS to 192.168.1.1:<dnsmasq_port> (engine opkg) -> verify
# - restore: восстановить настройки из backup -> verify (опционально)
# - print-engine: вывести текущее значение dns-proxy filter engine
# - set-engine <engine>: установить dns-proxy filter engine, сохранить конфигурацию
#
# Хранение backup: /opt/etc/allow/setsettings.backup

SOFT="${SOFT:-0}"

ACTION="${1:-apply}"
case "$ACTION" in
  --soft)
    SOFT=1
    shift || true
    ACTION="${1:-apply}"
    ;;
esac

if [ "$ACTION" = "--help" ] || [ "$ACTION" = "-h" ]; then
  echo "Usage:"
  echo "  $0 preset           # set System DNS to 1.1.1.1 + 8.8.8.8 (may switch engine public->opkg)"
  echo "  $0                  # backup -> set System DNS to 192.168.1.1:<port> (engine opkg) -> verify"
  echo "  $0 apply            # same as default"
  echo "  $0 restore          # restore previous settings from backup"
  echo "  $0 print-engine     # print current dns-proxy filter engine"
  echo "  $0 set-engine <e>   # set dns-proxy filter engine to <e> and save"
  echo "  $0 --soft <action>  # never fail hard; only warn and continue"
  exit 0
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DETECT_SH="$SCRIPT_DIR/detect_system.sh"

STATE_DIR="/opt/etc/allow"
BACKUP_FILE="${STATE_DIR}/setsettings.backup"

log() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() {
  warn "ERROR: $*"
  if [ "$SOFT" = "1" ]; then
    warn "WARN: Продолжаю (soft mode). Возможно потребуется ручная настройка DNS."
    exit 0
  fi
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ndmc_cmd() {
  # Wrap to make tracing/override easier later
  ndmc -c "$1"
}

read_dnsmasq_port() {
  DNSMASQ_INIT="/opt/etc/allow/init.d/S98dnsmasq-full"
  [ -x "$DNSMASQ_INIT" ] || DNSMASQ_INIT="/opt/etc/init.d/S98dnsmasq-full"

  # Policy 1: берём EFFECTIVE_PORT (active если running, иначе config)
  if [ -x "$DNSMASQ_INIT" ]; then
    PORT="$(sh "$DNSMASQ_INIT" status --kv 2>/dev/null | awk -F= '$1=="EFFECTIVE_PORT"{print $2; exit}' 2>/dev/null | tr -cd '0-9' | head -c 6 || true)"
    if [ -n "${PORT:-}" ]; then
      echo "$PORT"
      return 0
    fi
  fi

  # Fallback: читаем из конфига
  for cfg in /opt/etc/allow/dnsmasq-full/dnsmasq.conf /opt/etc/dnsmasq-full.conf; do
    if [ -f "$cfg" ]; then
      PORT="$(awk -F= '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*port[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}
      ' "$cfg" 2>/dev/null | tr -cd '0-9' | head -c 6 || true)"
      if [ -n "${PORT:-}" ]; then
        echo "$PORT"
        return 0
      fi
    fi
  done

  echo "5300"
}

get_running_config() {
  ndmc_cmd "show running-config"
}

get_name_servers() {
  # Prints full lines: "ip name-server ..."
  get_running_config | awk '/^ip name-server /{print}'
}

get_dns_filter_engine() {
  # Extract engine inside dns-proxy block: public|opkg|interceptor (or empty)
  get_running_config | awk '
    /^dns-proxy[[:space:]]*$/ {inblock=1; next}
    /^!$/ {inblock=0}
    inblock && $0 ~ /filter engine/ {
      # line looks like: "    filter engine opkg"
      for (i=1; i<=NF; i++) last=$i
      print last
      exit
    }
  '
}

backup_current_state() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  if [ -f "$BACKUP_FILE" ]; then
    # simple rotation to keep previous backup
    cp -f "$BACKUP_FILE" "${BACKUP_FILE}.prev" 2>/dev/null || true
  fi

  # detect_system is optional but useful for metadata
  DS_SYSTEM=""
  DS_SUBSYS=""
  DS_ENTWARE=""
  DS_NDM_RELEASE=""
  DS_NDM_TITLE=""
  if [ -f "$DETECT_SH" ]; then
    DS_OUT="$(sh "$DETECT_SH" --machine 2>/dev/null || true)"
    DS_SYSTEM="$(printf '%s\n' "$DS_OUT" | awk -F= '$1=="SYSTEM"{print $2; exit}')"
    DS_SUBSYS="$(printf '%s\n' "$DS_OUT" | awk -F= '$1=="SUBSYS"{print $2; exit}')"
    DS_ENTWARE="$(printf '%s\n' "$DS_OUT" | awk -F= '$1=="ENTWARE"{print $2; exit}')"
    DS_NDM_RELEASE="$(printf '%s\n' "$DS_OUT" | awk -F= '$1=="NDM_RELEASE"{print $2; exit}')"
    DS_NDM_TITLE="$(printf '%s\n' "$DS_OUT" | awk -F= '$1=="NDM_TITLE"{print $2; exit}')"
  fi

  ENGINE="$(get_dns_filter_engine || true)"
  NAME_SERVERS="$(get_name_servers || true)"

  {
    echo "TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
    [ -n "$DS_SYSTEM" ] && echo "SYSTEM=$DS_SYSTEM"
    [ -n "$DS_SUBSYS" ] && echo "SUBSYS=$DS_SUBSYS"
    [ -n "$DS_ENTWARE" ] && echo "ENTWARE=$DS_ENTWARE"
    [ -n "$DS_NDM_RELEASE" ] && echo "NDM_RELEASE=$DS_NDM_RELEASE"
    [ -n "$DS_NDM_TITLE" ] && echo "NDM_TITLE=$DS_NDM_TITLE"
    echo "ENGINE=${ENGINE:-}"
    echo "NAME_SERVERS_BEGIN"
    printf '%s\n' "$NAME_SERVERS"
    echo "NAME_SERVERS_END"
  } >"$BACKUP_FILE"

  log "Backup saved to: $BACKUP_FILE"
}

preset_public_dns() {
  # Step 1 preset: 1.1.1.1 + 8.8.8.8.
  # Важно: при engine=public Keenetic может блокировать запись System DNS (ip name-server),
  # поэтому делаем best-effort public->opkg перед установкой DNS.
  CURRENT_ENGINE="$(get_dns_filter_engine || true)"
  if [ "${CURRENT_ENGINE:-}" = "public" ]; then
    log "dns-proxy filter engine is public; switching to opkg to allow DNS changes."
    ndmc_cmd "dns-proxy filter engine opkg" >/dev/null 2>&1 || die "Failed to set dns-proxy filter engine opkg"
  fi

  delete_all_name_servers
  ndmc_cmd "ip name-server 1.1.1.1" >/dev/null 2>&1 || die "Failed to set ip name-server 1.1.1.1"
  ndmc_cmd "ip name-server 8.8.8.8" >/dev/null 2>&1 || die "Failed to set ip name-server 8.8.8.8"
  ndmc_cmd "system configuration save" >/dev/null 2>&1 || die "Failed to save configuration"

  # Verify only via running-config (soft about dns-proxy internals)
  RC_NS="$(get_name_servers || true)"
  printf '%s\n' "$RC_NS" | grep -Fxq "ip name-server 1.1.1.1" || die "Verify failed: missing ip name-server 1.1.1.1"
  printf '%s\n' "$RC_NS" | grep -Fxq "ip name-server 8.8.8.8" || die "Verify failed: missing ip name-server 8.8.8.8"

  # Informational check: dns-proxy may still be influenced by DoT/DoH (127.0.0.1:405xx)
  if ! ndmc_cmd "show dns-proxy" 2>/dev/null | grep -q "dns_server = 1.1.1.1"; then
    warn "WARN: dns-proxy не показывает dns_server=1.1.1.1 (возможен активный DoT/DoH). Это допустимо на preset-этапе."
  fi

  log "OK: Preset applied (DNS 1.1.1.1 + 8.8.8.8)"
}

print_engine() {
  get_dns_filter_engine || true
}

set_engine() {
  ENGINE_VALUE="${1:-}"
  [ -n "$ENGINE_VALUE" ] || die "Missing engine value (use: set-engine <public|opkg|interceptor>)"

  ndmc_cmd "dns-proxy filter engine ${ENGINE_VALUE}" >/dev/null 2>&1 || die "Failed to set dns-proxy filter engine ${ENGINE_VALUE}"
  ndmc_cmd "system configuration save" >/dev/null 2>&1 || die "Failed to save configuration"

  # Best-effort verify via running-config
  NEW_ENGINE="$(get_dns_filter_engine || true)"
  if [ -n "${NEW_ENGINE:-}" ] && [ "$NEW_ENGINE" != "$ENGINE_VALUE" ]; then
    die "Verify failed: dns-proxy filter engine is ${NEW_ENGINE}, expected ${ENGINE_VALUE}"
  fi
  log "OK: dns-proxy filter engine set to ${ENGINE_VALUE}"
}

load_backup() {
  [ -f "$BACKUP_FILE" ] || die "Backup file not found: $BACKUP_FILE"

  SAVED_ENGINE=""
  SAVED_NAME_SERVERS=""
  IN_NS=0

  # shellcheck disable=SC2162
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ENGINE=*)
        SAVED_ENGINE="${line#ENGINE=}"
        ;;
      NAME_SERVERS_BEGIN)
        IN_NS=1
        ;;
      NAME_SERVERS_END)
        IN_NS=0
        ;;
      *)
        if [ "$IN_NS" -eq 1 ]; then
          # keep exact line
          if [ -z "$SAVED_NAME_SERVERS" ]; then
            SAVED_NAME_SERVERS="$line"
          else
            SAVED_NAME_SERVERS="${SAVED_NAME_SERVERS}
${line}"
          fi
        fi
        ;;
    esac
  done <"$BACKUP_FILE"

  # export via globals
  RESTORE_ENGINE="$SAVED_ENGINE"
  RESTORE_NAME_SERVERS="$SAVED_NAME_SERVERS"
}

delete_all_name_servers() {
  CURRENT_NS="$(get_name_servers || true)"
  if [ -z "${CURRENT_NS:-}" ]; then
    return 0
  fi

  printf '%s\n' "$CURRENT_NS" | while IFS= read -r nsline; do
    [ -z "$nsline" ] && continue
    # nsline: "ip name-server ..."
    ndmc_cmd "no $nsline" >/dev/null 2>&1 || true
  done
}

set_system_dns_to_local() {
  PORT="$(read_dnsmasq_port)"

  CURRENT_ENGINE="$(get_dns_filter_engine || true)"
  if [ "$CURRENT_ENGINE" = "public" ]; then
    log "dns-proxy filter engine is public; switching to opkg (disables public)."
    ndmc_cmd "dns-proxy filter engine opkg" >/dev/null 2>&1 || die "Failed to set dns-proxy filter engine opkg"
    NEW_ENGINE="$(get_dns_filter_engine || true)"
    [ "$NEW_ENGINE" = "opkg" ] || die "Failed to switch dns-proxy filter engine to opkg (current: ${NEW_ENGINE:-<empty>})"
  fi

  delete_all_name_servers

  TARGET="192.168.1.1:${PORT}"
  ndmc_cmd "ip name-server $TARGET" >/dev/null 2>&1 || die "Failed to set ip name-server $TARGET"
  ndmc_cmd "system configuration save" >/dev/null 2>&1 || die "Failed to save configuration"

  verify_target "$TARGET"
}

restore_from_backup() {
  load_backup

  # Restore engine first (best effort)
  if [ -n "${RESTORE_ENGINE:-}" ]; then
    log "Restoring dns-proxy filter engine: ${RESTORE_ENGINE}"
    ndmc_cmd "dns-proxy filter engine ${RESTORE_ENGINE}" >/dev/null 2>&1 || warn "WARN: failed to set dns-proxy filter engine ${RESTORE_ENGINE}"
  fi

  delete_all_name_servers

  if [ -n "${RESTORE_NAME_SERVERS:-}" ]; then
    printf '%s\n' "$RESTORE_NAME_SERVERS" | while IFS= read -r nsline; do
      [ -z "$nsline" ] && continue
      # nsline is expected to start with "ip name-server "
      ndmc_cmd "$nsline" >/dev/null 2>&1 || warn "WARN: failed to apply: $nsline"
    done
  fi

  ndmc_cmd "system configuration save" >/dev/null 2>&1 || die "Failed to save configuration"

  verify_restore
}

verify_target() {
  TARGET="$1"
  RC_NS="$(get_name_servers || true)"
  [ -n "$RC_NS" ] || die "Verify failed: no ip name-server entries after apply"

  # Ensure exactly one name-server and it matches target.
  NS_COUNT="$(printf '%s\n' "$RC_NS" | awk 'NF{c++} END{print c+0}')"
  if [ "$NS_COUNT" -ne 1 ]; then
    warn "Current ip name-server entries:"
    warn "$RC_NS"
    die "Verify failed: expected exactly 1 ip name-server entry, got $NS_COUNT"
  fi

  printf '%s\n' "$RC_NS" | grep -q "^ip name-server ${TARGET}\$" || die "Verify failed: running-config does not contain: ip name-server ${TARGET}"

  # Informational check only: show dns-proxy may still use 127.0.0.1:405xx if DoT/DoH is enabled.
  if ! ndmc_cmd "show dns-proxy" 2>/dev/null | grep -q "dns_server = ${TARGET}"; then
    warn "WARN: dns-proxy не показывает dns_server=${TARGET} (возможен активный DoT/DoH)."
    warn "WARN: Если DNS фактически не идёт через dnsmasq-full Allow — удалите все DNS адреса кроме адресов Allow и отключите DoT/DoH профили."
  fi

  log "OK: System DNS set to ${TARGET}"
}

verify_restore() {
  # Verify that all saved name-server lines are present after restore.
  load_backup

  RC_NS="$(get_name_servers || true)"
  if [ -z "${RESTORE_NAME_SERVERS:-}" ]; then
    # Nothing to compare
    log "OK: Restore completed (no saved name-servers to verify)."
    return 0
  fi

  FAILED=0
  # Avoid pipelines here to keep FAILED in the same shell
  while IFS= read -r nsline; do
    [ -z "$nsline" ] && continue
    printf '%s\n' "$RC_NS" | grep -Fxq "$nsline" || FAILED=1
  done <<EOF
$RESTORE_NAME_SERVERS
EOF

  if [ "$FAILED" -ne 0 ]; then
    warn "WARN: Restore verification mismatch. Current name-servers:"
    warn "$RC_NS"
    warn "Expected name-servers:"
    warn "$RESTORE_NAME_SERVERS"
    exit 1
  fi

  log "OK: Restored previous System DNS settings."
}

main() {
  need_cmd ndmc
  need_cmd awk
  need_cmd grep

  # Best-effort platform detection; enforce Keenetic if detect_system.sh is present
  if [ -f "$DETECT_SH" ]; then
    DS_OUT="$(sh "$DETECT_SH" --machine 2>/dev/null || true)"
    DS_SUBSYS="$(printf '%s\n' "$DS_OUT" | awk -F= '$1=="SUBSYS"{print $2; exit}')"
    if [ -n "$DS_SUBSYS" ] && [ "$DS_SUBSYS" != "keenetic" ]; then
      if [ "$SOFT" = "1" ]; then
        warn "WARN: setsettings: SUBSYS=$DS_SUBSYS (не keenetic). Пропускаю."
        exit 0
      fi
      die "Unsupported subsystem (expected keenetic): SUBSYS=$DS_SUBSYS"
    fi
  fi

  case "$ACTION" in
    preset)
      preset_public_dns
      ;;
    print-engine)
      print_engine
      ;;
    set-engine)
      shift || true
      set_engine "$@"
      ;;
    apply|"")
      backup_current_state
      set_system_dns_to_local
      ;;
    restore)
      restore_from_backup
      ;;
    *)
      die "Unknown action: $ACTION (use: preset|apply|restore|print-engine|set-engine)"
      ;;
  esac
}

main "$@"

