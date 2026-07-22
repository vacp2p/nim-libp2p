# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:2.2.10 as builder

WORKDIR /app

COPY libp2p.nimble nimble.lock nim-libp2p/

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y --no-install-recommends ca-certificates binutils \
    && rm -rf /var/lib/apt/lists/*

RUN cd nim-libp2p && nimble -l install -dy && nimble -l --noLockfile install -y redis

COPY . nim-libp2p/

RUN \
  cd nim-libp2p && \
  nimble -l setup && \
  REDIS_PATH="$(nimble -l --noLockfile path redis)" && \
  nim c -d:release --path:"$REDIS_PATH/src" --mm:refc -d:chronicles_log_level=WARN -d:chronicles_default_output_device=stderr --threads:on -o:/app/interop ./interop/transport/main.nim


FROM debian:trixie-slim AS runtime

COPY --from=builder /app/interop /app/interop

ENTRYPOINT ["/app/interop"]
