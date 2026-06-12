#!/bin/sh

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

set -eu

# Work around a libp2p/test-plans router NAT setup race. This is not client
# behavior; it only makes the Docker topology deterministic before tests start.

poll_attempts=50
poll_interval=0.2

docker_api() {
  curl -fsS --unix-socket /var/run/docker.sock "$@"
}

docker_exec() {
  container_id="$1"
  command="$2"

  # The image ships curl/jq, not the Docker CLI. Use the Docker Engine API
  # over the mounted socket to run commands inside the router container.
  exec_id=$(
    jq -nc --arg cmd "$command" \
      '{AttachStdout:false,AttachStderr:false,Cmd:["/bin/sh","-c",$cmd]}' |
      docker_api -H 'Content-Type: application/json' -d @- \
        "http://localhost/containers/$container_id/exec" |
      jq -r '.Id'
  )

  jq -nc '{Detach:false,Tty:false}' |
    docker_api -H 'Content-Type: application/json' -d @- \
      "http://localhost/exec/$exec_id/start" >/dev/null

  # Docker fills ExitCode only after the exec command finishes; poll briefly.
  exit_code=""
  attempt=0
  while [ "$attempt" -lt "$poll_attempts" ]; do
    exit_code=$(
      docker_api "http://localhost/exec/$exec_id/json" |
        jq -r '.ExitCode // empty'
    )
    [ -n "$exit_code" ] && break
    attempt=$((attempt + 1))
    sleep "$poll_interval"
  done

  [ "$exit_code" = "0" ]
}

router_container_id() {
  project_name="$1"
  service_name="$2"
  jq_filter="
    .[] |
    select(
      .Labels[\"com.docker.compose.project\"] == \$project and
      .Labels[\"com.docker.compose.service\"] == \$service
    ) |
    .Id
  "

  docker_api "http://localhost/containers/json" |
    jq -r --arg project "$project_name" --arg service "$service_name" "$jq_filter" |
    head -n1
}

fix_router_nat() {
  [ -S /var/run/docker.sock ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  case "${MODE:-}" in
    dial | listen) ;;
    *) return 0 ;;
  esac

  self_id=$(hostname)
  project=$(
    docker_api "http://localhost/containers/$self_id/json" |
      jq -r '.Config.Labels["com.docker.compose.project"] // empty'
  ) || return 0
  [ -n "$project" ] || return 0

  # Fix the remote router first; Rust peers can start before this helper exits.
  case "${MODE:-}" in
    dial) router_services="listener_router dialer_router" ;;
    listen) router_services="dialer_router listener_router" ;;
  esac

  for router_service in $router_services; do
    router_ready=0
    router_id=""

    # The router can exist before setup finishes; wait for its setup marker.
    attempt=0
    while [ "$attempt" -lt "$poll_attempts" ]; do
      router_id=$(router_container_id "$project" "$router_service") ||
        router_id=""

      if [ -n "$router_id" ] &&
         docker_exec "$router_id" '[ "$(cat /tmp/setup_done 2>/dev/null)" = "1" ]'; then
        router_ready=1
        break
      fi

      attempt=$((attempt + 1))
      sleep "$poll_interval"
    done

    [ -n "$router_id" ] || continue
    [ "$router_ready" = "1" ] || continue

    # Derive interfaces dynamically; Compose network names change per test.
    docker_exec "$router_id" '
      relay_ip=$(getent hosts relay | head -n1 | cut -d" " -f1)
      iface_external=$(ip -json route get "$relay_ip" | jq -r ".[0].dev")
      iface_internal=$(ip -json addr show | jq -r --arg ext "$iface_external" '\''.[] | select(.ifname != "lo" and .ifname != $ext and any(.addr_info[]?; .family == "inet")) | .ifname'\'' | head -n1)
      addr_external=$(ip -json addr show "$iface_external" | jq -r '\''.[0].addr_info[] | select(.family == "inet") | .local'\'' | head -n1)
      subnet_internal=$(ip -json addr show "$iface_internal" | jq -r '\''.[0].addr_info[] | select(.family == "inet") | .local + "/" + (.prefixlen | tostring)'\'' | head -n1)
      [ -n "$relay_ip" ] && [ -n "$iface_external" ] && [ -n "$iface_internal" ] && [ -n "$addr_external" ] && [ -n "$subnet_internal" ]
      nft list table ip nat >/dev/null 2>&1 || exit 0
      nft add rule ip nat postrouting ip saddr "$subnet_internal" oifname "$iface_external" snat "$addr_external" 2>/dev/null || true
    ' || true
  done
}

fix_router_nat
