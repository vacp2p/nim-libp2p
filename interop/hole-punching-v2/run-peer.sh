#!/usr/bin/env bash
set -e

# Set route to relay subnet
echo "Setting route to relay subnet ${WAN_SUBNET} via ${WAN_ROUTER_IP}" >&2
ip route add "${WAN_SUBNET}" via "${WAN_ROUTER_IP}" dev lan0

# Execute the peer binary, passing through all arguments
exec /usr/bin/peer "$@"
