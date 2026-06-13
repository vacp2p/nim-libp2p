# Hole-punch Interop Test App

Test app for the [libp2p/test-plans](https://github.com/libp2p/test-plans)
hole-punch interop test.

The upstream harness runs `hole-punch-client` with `MODE=listen|dial`,
`TRANSPORT=tcp|quic`, and a Redis server at `redis:6379`. The client reads the
relay address from the `RELAY_TCP_ADDRESS` or `RELAY_QUIC_ADDRESS` Redis lists,
the listener pushes `LISTEN_CLIENT_PEER_ID`, and the dialer prints a single JSON
line:

```json
{"rtt_to_holepunched_peer_millis":200.00}
```
