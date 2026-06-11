#!/bin/sh

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

set -eu

docker_api() {
  curl -fsS --unix-socket /var/run/docker.sock "$@"
}

docker_exec() {
  container_id="$1"
  command="$2"

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

  exit_code=""
  for _ in 1 2 3 4 5 6 7 8 9 10 \
    11 12 13 14 15 16 17 18 19 20 \
    21 22 23 24 25 26 27 28 29 30 \
    31 32 33 34 35 36 37 38 39 40 \
    41 42 43 44 45 46 47 48 49 50; do
    exit_code=$(
      docker_api "http://localhost/exec/$exec_id/json" |
        jq -r '.ExitCode // empty'
    )
    [ -n "$exit_code" ] && break
    sleep 0.2
  done

  [ "$exit_code" = "0" ]
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

  for router_service in dialer_router listener_router; do
    router_ready=0
    router_id=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      router_id=$(
        docker_api "http://localhost/containers/json" |
          jq -r --arg project "$project" --arg service "$router_service" \
            '.[] | select(.Labels["com.docker.compose.project"] == $project and .Labels["com.docker.compose.service"] == $service) | .Id' |
          head -n1
      ) || router_id=""

      if [ -n "$router_id" ] &&
         docker_exec "$router_id" '[ "$(cat /tmp/setup_done 2>/dev/null)" = "1" ]'; then
        router_ready=1
        break
      fi

      sleep 1
    done

    [ -n "$router_id" ] || continue
    [ "$router_ready" = "1" ] || continue

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

exec /usr/bin/hole-punch-client.bin "$@"
