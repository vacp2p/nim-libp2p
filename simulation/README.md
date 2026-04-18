# nim-libp2p Network Simulation

Spins up a configurable number of nim-libp2p nodes in Docker, connects them via GossipSub, and continuously publishes messages to measure propagation latency. An observability stack (Grafana + Prometheus + Loki) is included for real-time monitoring.

## How it works

1. Each node starts a libp2p switch (QUIC or TCP+Yamux) and registers a GossipSub router on the `test` topic.
2. Nodes register their multiaddress in **Redis**; once all nodes are present, each node connects to a random subset of peers.
3. **Network emulation** (`tc netem`) is applied per-container via the `NETEM` env var (default: `delay 100ms 10ms distribution normal`) to simulate realistic latency.
4. Each node sends `WARMUP_MESSAGES` initial warm-up publishes with an explicit warm-up flag; receivers drop those from latency reporting after all fragments arrive.
5. After warm-up, every 5 seconds each node publishes a ~50 KiB timestamped message; receivers compute end-to-end latency.
6. Mesh state (mesh peers, gossip peers) is logged every 10 seconds.

## Quick start

From the repo root:

```sh
cd simulation
TRANSPORT=QUIC NUM_LIBP2P_NODES=10 docker compose up --build
```

> Note: Use `--scale simulation=...` when starting the stack; local `docker compose up` may ignore `deploy.replicas`.

Grafana will be available at **http://localhost:3000** (user/pass: `admin`/`admin`). Two dashboards are pre-provisioned:

- **libp2p-metrics** - protocol-level metrics (connections, streams, GossipSub stats)
- **monitoring** - container resource usage via cAdvisor

## Environment variables

| Variable           | Default                                | Description                                                               |
| ------------------ | -------------------------------------- | ------------------------------------------------------------------------- |
| `TRANSPORT`        | `QUIC`                                 | Transport protocol: `QUIC` or `TCP`                                       |
| `NUM_LIBP2P_NODES` | `10`                                   | Number of libp2p nodes (Docker replicas)                                  |
| `CONNECTTO`        | `10`                                   | Number of peers each node dials on startup                                |
| `FRAGMENTS`        | `1`                                    | Number of message fragments per publish                                   |
| `MAXCONNECTIONS`   | `250`                                  | Max concurrent connections per node                                       |
| `REDIS_WAIT_TIMEOUT_SECONDS` | `120`                        | Max time to wait for all nodes to register in Redis before exiting        |
| `WARMUP_MESSAGES`  | `3`                                    | Number of initial publish cycles flagged as warm-up and excluded from latency logs |
| `SELFTRIGGER`      | `true`                                 | Whether a node receives its own published messages                        |
| `NETEM`            | `delay 100ms 10ms distribution normal` | `tc netem` args applied to each container's `eth0` (set empty to disable) |
| `redis_addr`       | `redis:6379`                           | Redis host/port used for node registration and discovery                  |

## Local compilation (without Docker)

```sh
cd simulation
nimble install -y --depsOnly
nim c -d:metrics -d:release main.nim
```

The binary expects a running Redis instance (see `redis_addr` env var, default `redis:6379`).

## Stopping the simulation

```sh
cd simulation
docker compose down -v
```

## Architecture

```
┌─────────────┐
│   Grafana    │:3000  ── dashboards + log explorer
├─────────────┤
│  Prometheus  │:9090  ── scrapes :8008 from each node
│    Loki      │:3100  ── receives logs from Promtail
│  Promtail    │       ── tails Docker container logs
│  cAdvisor    │       ── container CPU/mem/net metrics
├─────────────┤
│   Redis      │:6379  ── peer discovery registry
├─────────────┤
│  simulation  │       ── N replicas, each running main
│  (node 1..N) │:5000 (libp2p) / :8008 (metrics)
└─────────────┘
```
