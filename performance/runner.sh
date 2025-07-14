#!/bin/bash

custom_network_name="my_custom_network"
num_peers=10

if ! docker network inspect "$custom_network_name" >/dev/null 2>&1; then
  docker network create "$custom_network_name"
  docker network create --attachable --driver bridge "$custom_network_name"
fi

for ((i = 0; i < num_peers; i++)); do
    # Construct the hostname (e.g., peer1, peer2, ...)
    hostname="pod-$i"

    # Run the Docker container with the current hostname
    docker run -e PEERSPERPOD="1" -e PEERS="10" -e CONNECTTO="5" -e MSGRATE="1000" -e MSGSIZE="1000" -e PEERNUMBER="0" --hostname="$hostname" --network="$custom_network_name" dst-test-node &

done