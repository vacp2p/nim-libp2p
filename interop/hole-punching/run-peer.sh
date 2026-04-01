#!/usr/bin/env bash
set -e

# Detect LAN interface by peer IP (interface_name requires Docker Engine v28.1+)
PEER_IP="${DIALER_IP:-${LISTENER_IP}}"
LAN_IF=$(ip -o addr show | awk -v ip="${PEER_IP}" '$4 ~ ("^" ip "/") {print $2; exit}')
echo "LAN interface: ${LAN_IF} (peer IP: ${PEER_IP})" >&2

# Set route to relay subnet
echo "Setting route to relay subnet ${WAN_SUBNET} via ${WAN_ROUTER_IP}" >&2
ip route add "${WAN_SUBNET}" via "${WAN_ROUTER_IP}" dev "${LAN_IF}"

# Execute the peer binary, passing through all arguments
exec /usr/bin/peer "$@"
