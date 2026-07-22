# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:2.2.10 as builder

WORKDIR /app

COPY libp2p.nimble nim-libp2p/
COPY interop/transport/interop_transport.nimble interop/transport/nimble.lock nim-libp2p/interop/transport/

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y --no-install-recommends ca-certificates binutils \
    && rm -rf /var/lib/apt/lists/*

RUN cd nim-libp2p/interop/transport && nimble -l install -dy

COPY . nim-libp2p/

RUN \
  cd nim-libp2p/interop/transport && \
  nimble -l setup && \
  nim c -d:release --mm:refc -d:chronicles_log_level=WARN -d:chronicles_default_output_device=stderr --threads:on -o:/app/interop main.nim


FROM debian:trixie-slim AS runtime

COPY --from=builder /app/interop /app/interop

ENTRYPOINT ["/app/interop"]
