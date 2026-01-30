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

if [ -x /opt/etc/allow/init.d/S98sing-box ]; then
  /opt/etc/allow/init.d/S98sing-box "$cmd"
else
  # fallback to sh if not executable yet
  sh /opt/etc/allow/init.d/S98sing-box "$cmd" 2>/dev/null || true
fi

exit 0

