# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:2.2.10 as builder

WORKDIR /app

COPY libp2p.nimble nim-libp2p/
COPY interop/kad-dht-v2/interop_kad_dht_v2.nimble interop/kad-dht-v2/nimble.lock nim-libp2p/interop/kad-dht-v2/

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y --no-install-recommends ca-certificates binutils \
    && rm -rf /var/lib/apt/lists/*

RUN cd nim-libp2p/interop/kad-dht-v2 && nimble -l install -dy

COPY . nim-libp2p/

RUN \
  cd nim-libp2p/interop/kad-dht-v2 && \
  nimble -l setup && \
  nim c -d:release \
  --mm:refc --threads:on \
  -d:chronicles_log_level=INFO -d:chronicles_default_output_device=stderr -d:chronicles_colors=None \
  -o:/app/peer peer.nim

FROM debian:trixie-slim
COPY --from=builder /app/peer /usr/bin/peer
ENTRYPOINT ["/usr/bin/peer"]
