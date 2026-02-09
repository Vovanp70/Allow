#!/bin/sh

# NDM netfilter hook for hotspot VPN.
# Called by Keenetic NDM during firewall (iptables) apply procedure.
# NDM can set env var "table" to current iptables table (mangle/filter/nat/...).
# Логика: дёргает route-by-mark.sh — sync (восстановить правило по state) или delmark (снять правило и очистить state).
# Марку задаёт только пользователь через route-by-mark.sh addmark <value>.

case "${table:-}" in
  ""|mangle|filter)
    # proceed
    ;;
  *)
    exit 0
    ;;
esac

cmd="sync"
case "${1:-}" in
  stop|ifdown|wandown)
    cmd="delmark"
    ;;
  start|ifup|wanup|restart|reload|"")
    cmd="sync"
    ;;
  *)
    cmd="sync"
    ;;
esac

ROUTE_SCRIPT="/opt/etc/allow/route-by-mark.sh"
if [ -x "$ROUTE_SCRIPT" ]; then
  "$ROUTE_SCRIPT" "$cmd" >/dev/null 2>&1 || true
elif [ -f "$ROUTE_SCRIPT" ]; then
  sh "$ROUTE_SCRIPT" "$cmd" >/dev/null 2>&1 || true
fi

exit 0
