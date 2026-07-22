# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:2.2.10 as builder

WORKDIR /app

COPY libp2p.nimble nim-libp2p/

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y --no-install-recommends ca-certificates binutils \
    && rm -rf /var/lib/apt/lists/*

RUN cd nim-libp2p && nimble --noLockfile --requires:"nim == 2.2.10" --resolver:minver -l setup -y && nimble -l --noLockfile install -y redis

COPY . nim-libp2p/

RUN \
  cd nim-libp2p && \
  nimble --noLockfile --requires:"nim == 2.2.10" --resolver:minver -l setup -y && \
  REDIS_PATH="$(nimble -l --noLockfile path redis)" && \
  nim c -d:release --path:"$REDIS_PATH/src" \
  --mm:refc --threads:on \
  -d:chronicles_log_level=INFO -d:chronicles_default_output_device=stderr -d:chronicles_colors=None \
  -o:/app/peer ./interop/kad-dht-v2/peer.nim

FROM debian:trixie-slim AS runtime
COPY --from=builder /app/peer /usr/bin/peer
ENTRYPOINT ["/usr/bin/peer"]
