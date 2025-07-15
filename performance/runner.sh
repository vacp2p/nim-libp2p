#!/bin/bash

custom_network_name="my_custom_network"
PEERS=10
CONNECT_TO=5
MSG_COUNT=50
MSG_INTERVAL=100 # ms
MSG_SIZE=100 # bytes

if ! docker network inspect "$custom_network_name" >/dev/null 2>&1; then
  docker network create "$custom_network_name"
  docker network create --attachable --driver bridge "$custom_network_name"
fi


# Start containers and collect their names
container_names=()
for ((i = 0; i < $PEERS; i++)); do
    hostname="pod-$i"
    publish_port=""
    [[ $i -eq 0 ]] && publish_port="-p 8008:8008"

    container_name="testnode-$i"
    docker run \
      --name "$container_name" \
      -e PEER_NUMBER="$i" \
      -e PEERS="$PEERS" \
      -e CONNECT_TO="$CONNECT_TO" \
      -e MSG_COUNT="$MSG_COUNT" \
      -e MSG_INTERVAL="$MSG_INTERVAL" \
      -e MSG_SIZE="$MSG_SIZE" \
      --hostname="$hostname" \
      --network="$custom_network_name" \
      $publish_port \
      dst-test-node &
    container_names+=("$container_name")
done

# Wait for all containers to finish
for cname in "${container_names[@]}"; do
    docker wait "$cname"
done