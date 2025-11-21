### Install dependencies locally (for faster docker builds)

```
nimble install -l
```

### Build docker image (run this after any change in code / dependencies)

```
docker build -t nim-libp2p/quic .
```

### Start simulation

```
TRANSPORT=QUIC NUM_LIBP2P_NODES=10 docker compose up
```
Environment variables you can use:
- `TRANSPORT` can be `QUIC` or `TCP` (default `QUIC`)
- `NUM_LIBP2P_NODES` number of libp2p nodes to start, default `10`
- `CONNECTTO` indicates the number of nodes each node will connect to, default `10`
- Optionally add the `-d` flag to run in the background (you can then see the logs with `docker logs container_name_here`)

### Stop simulation (if using -d flag)

```
docker compose down -v
```
