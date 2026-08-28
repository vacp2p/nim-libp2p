# AutoTLS integration test

`test_autotls_docker.nim` drives `AutotlsService` end to end against a local ACME server and a local AutoTLS broker, issuing a real certificate.

```sh
make test_autotls_docker_integration
```

The target builds the test image, brings both servers up, runs the test with `run --rm test` and tears down with `down -v`. All three containers share the host network namespace, so the broker can dial the test node back on loopback.

Both images are pinned by digest in `docker-compose.yml`.

## Pebble

Let's Encrypt's test ACME server: same protocol as Boulder, throwaway CA, no rate limits. Image `ghcr.io/letsencrypt/pebble:2`.

Pebble is deliberately flaky, and `docker-compose.yml` turns that off with `PEBBLE_VA_NOSLEEP=1`, `PEBBLE_WFE_NONCEREJECT=0` (default rejects 5% of good nonces) and `PEBBLE_AUTHZREUSE=0` (default reuses half of all authorizations). `PEBBLE_VA_ALWAYS_VALID` is unset, so the real TXT record is validated.

- https://github.com/letsencrypt/pebble
- https://github.com/letsencrypt/pebble#testing-at-full-speed
- https://github.com/letsencrypt/pebble#invalid-anti-replay-nonce-errors
- https://github.com/letsencrypt/pebble#object-reuse
- https://github.com/letsencrypt/pebble#skipping-validation

### `pebble-config.json`

Upstream's `test/config/pebble-config.json`, with `listenAddress` on `0.0.0.0:443`. Pebble builds the URLs it advertises in its directory from the request's `Host` header, and chronos writes `Host` without the port, so on any other port everything past the directory is unreachable. The image runs as root and can bind 443.

- https://github.com/letsencrypt/pebble/blob/main/test/config/pebble-config.json

## p2p-forge

The AutoTLS broker: a CoreDNS build serving `libp2p.direct` that, on `POST /v1/_acme-challenge`, authenticates the peer, dials its advertised multiaddrs back over libp2p and only then publishes the DNS-01 TXT record Pebble validates. The same software runs `registration.libp2p.direct` in production. Image `ghcr.io/ipshipyard/p2p-forge:v0.10.1`.

Neither the Corefile nor the zones are in the image, both are mounted.

- https://github.com/ipshipyard/p2p-forge
- https://github.com/ipshipyard/p2p-forge#peer-authentication-and-dns-01-challenge-and-certificate-issuance
- https://github.com/ipshipyard/p2p-forge#submitting-challenge-records
- https://github.com/ipshipyard/p2p-forge#health-check — `/v1/health` returns 204; the image carries no HTTP client, so compose cannot use it as a healthcheck

### `Corefile`

Upstream's `Corefile.local-dev`: DNS on 5354, HTTP on 5380, badger for the challenge database. `registration-domain` is `127.0.0.1`, which the forge matches against the request's `Host` header by exact string, and chronos sends that without the port. No `denylist` block, whose feeds are fetched from Spamhaus and URLhaus at startup, and no `prometheus`.

- https://github.com/ipshipyard/p2p-forge/blob/main/Corefile.local-dev
- https://github.com/ipshipyard/p2p-forge/blob/main/Corefile — production reference
- https://github.com/ipshipyard/p2p-forge#acme-syntax

### `zones/libp2p.direct`

The minimum `ipparser` starts with: it reads the SOA from this file at startup, independently of the `file` directive. NS and A point at `127.0.0.1`, and the CAA record names `pebble.letsencrypt.org`, the identity Pebble validates CAA against. Upstream's file of the same name is the live production zone: public nameservers, PSL entries, mail records.

- https://github.com/ipshipyard/p2p-forge/blob/main/zones/libp2p.direct
- https://github.com/ipshipyard/p2p-forge#ipparser-syntax

## Specs

- ACME, RFC 8555 — POST-as-GET is §6.3: https://www.rfc-editor.org/rfc/rfc8555
- `Host` header, RFC 9110 §7.2: https://www.rfc-editor.org/rfc/rfc9110#section-7.2
- `any` in the Corefile, RFC 8482: https://www.rfc-editor.org/rfc/rfc8482
- PeerID Auth, used by the broker call: https://github.com/libp2p/specs/blob/master/http/peer-id-auth.md
