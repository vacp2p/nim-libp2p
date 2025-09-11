#!/bin/bash

set -euo pipefail

# Create Docker network
network="performance-test-network"
if ! docker network inspect "$network" > /dev/null 2>&1; then
  docker network create --attachable --driver bridge "$network" > /dev/null
fi

# Clean up output
output_dir="$(pwd)/performance/output"
mkdir -p "$output_dir"
rm -f "$output_dir"/*.json

# Run Test Nodes
container_names=()
PEERS=10
for ((i = 0; i < $PEERS; i++)); do
    hostname_prefix="node-" 
    hostname="$hostname_prefix$i"

    docker run -d \
      --cap-add=NET_ADMIN \
      --name "$hostname" \
      -e NODE_ID="$i" \
      -e HOSTNAME_PREFIX="$hostname_prefix" \
      -v "$output_dir:/output" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      --hostname="$hostname" \
      --network="$network" \
      test-node > /dev/null

    container_names+=("$hostname")
done

# Show logs in real time for all containers
for container_name in "${container_names[@]}"; do
    docker logs -f "$container_name" &
done

# Wait for all containers to finish
for container_name in "${container_names[@]}"; do
    docker wait "$container_name" > /dev/null
done

# Clean up all containers
for container_name in "${container_names[@]}"; do
    docker rm -f "$container_name" > /dev/null
done

# Remove the custom Docker network
docker network rm "$network" > /dev/null
exit 0