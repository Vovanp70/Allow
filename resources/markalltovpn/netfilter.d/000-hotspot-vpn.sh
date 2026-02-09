#!/bin/sh

# NDM netfilter hook for hotspot VPN (mark 0xffffaab -> table 111 -> sbtun0).
# Called by Keenetic NDM during firewall (iptables) apply procedure.
# NDM can set env var "table" to current iptables table (mangle/filter/nat/...).
# Делегирует добавление/удаление ip rule в route-by-mark.sh (по аналогии с sing-box).

case "${table:-}" in
  ""|mangle|filter)
    # proceed
    ;;
  *)
    exit 0
    ;;
esac

cmd="addmark"
case "${1:-}" in
  stop|ifdown|wandown)
    cmd="delmark"
    ;;
  start|ifup|wanup|restart|reload|"")
    cmd="addmark"
    ;;
  *)
    cmd="addmark"
    ;;
esac

ROUTE_SCRIPT="/opt/etc/allow/route-by-mark.sh"
if [ -x "$ROUTE_SCRIPT" ]; then
  if [ "$cmd" = "addmark" ]; then
    "$ROUTE_SCRIPT" addmark 0xffffaab >/dev/null 2>&1 || true
  else
    "$ROUTE_SCRIPT" delmark >/dev/null 2>&1 || true
  fi
elif [ -f "$ROUTE_SCRIPT" ]; then
  if [ "$cmd" = "addmark" ]; then
    sh "$ROUTE_SCRIPT" addmark 0xffffaab >/dev/null 2>&1 || true
  else
    sh "$ROUTE_SCRIPT" delmark >/dev/null 2>&1 || true
  fi
fi

exit 0
