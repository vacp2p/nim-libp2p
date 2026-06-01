#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${IS_DIALER:-}" ]]; then
  case "${MODE:-${ROLE:-}}" in
    dial|dialer) export IS_DIALER=true ;;
    listen|listener) export IS_DIALER=false ;;
  esac
fi

if [[ -n "${TEST_TIMEOUT_SECONDS:-}" && -z "${TEST_TIMEOUT_SECS:-}" ]]; then
  export TEST_TIMEOUT_SECS="${TEST_TIMEOUT_SECONDS}"
fi

# The v2 hole-punch test-plan provides ROUTER_LAN_IP and expects peers to route
# all non-local traffic through their NAT router. Older runners provided
# WAN_SUBNET/WAN_ROUTER_IP instead, so keep that fallback for compatibility.
if [[ -n "${ROUTER_LAN_IP:-}" ]]; then
  echo "Setting default route via ${ROUTER_LAN_IP}" >&2
  ip route del default 2>/dev/null || true
  ip route add default via "${ROUTER_LAN_IP}"
elif [[ -n "${WAN_SUBNET:-}" && -n "${WAN_ROUTER_IP:-}" ]]; then
  echo "Setting route to relay subnet ${WAN_SUBNET} via ${WAN_ROUTER_IP}" >&2
  if ip link show lan0 >/dev/null 2>&1; then
    ip route add "${WAN_SUBNET}" via "${WAN_ROUTER_IP}" dev lan0
  else
    ip route add "${WAN_SUBNET}" via "${WAN_ROUTER_IP}"
  fi
else
  echo "No route configuration variables provided; leaving routes unchanged" >&2
fi

# Execute the peer binary, passing through all arguments
exec /usr/bin/peer "$@"
