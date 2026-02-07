#!/bin/sh

# NDM netfilter hook for sing-box.
# Called by Keenetic NDM during firewall (iptables) apply procedure.
# NDM can set env var "table" to current iptables table (mangle/filter/nat/...).

case "${table:-}" in
  ""|mangle|filter)
    # proceed
    ;;
  *)
    # Not our phase/table
    exit 0
    ;;
esac

# Delegate all rule management to sing-box init script (zapret-style).
# Must NOT trigger system firewall apply here to avoid recursion.
cmd="restart-fw"
case "${1:-}" in
  stop|ifdown|wandown)
    cmd="stop-fw"
    ;;
  start|ifup|wanup|restart|reload|"")
    cmd="restart-fw"
    ;;
  *)
    cmd="restart-fw"
    ;;
esac

SB_INIT=""
for n in S98sing-box X98sing-box; do
  if [ -x "/opt/etc/allow/init.d/${n}" ]; then SB_INIT="/opt/etc/allow/init.d/${n}"; break; fi
done
if [ -n "$SB_INIT" ]; then
  "$SB_INIT" "$cmd" 2>/dev/null || sh "$SB_INIT" "$cmd" 2>/dev/null || true
else
  for n in S98sing-box X98sing-box; do
    if [ -f "/opt/etc/allow/init.d/${n}" ]; then sh "/opt/etc/allow/init.d/${n}" "$cmd" 2>/dev/null || true; break; fi
  done
fi

exit 0

