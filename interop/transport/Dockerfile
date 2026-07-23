# syntax=docker/dockerfile:1.5-labs
ARG NIM_VERSION=2.2.10
FROM nimlang/nim:${NIM_VERSION} as builder
ARG NIM_VERSION

WORKDIR /app

COPY libp2p.nimble nim-libp2p/
COPY interop/transport/interop_transport.nimble nim-libp2p/interop/transport/

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y --no-install-recommends ca-certificates binutils \
    && rm -rf /var/lib/apt/lists/*

COPY . nim-libp2p/

RUN \
  cd nim-libp2p/interop/transport && \
  nimble --noLockfile --requires:"nim == ${NIM_VERSION}" --resolver:minver -l setup -y && \
  nim c -d:release --mm:refc -d:chronicles_log_level=WARN -d:chronicles_default_output_device=stderr --threads:on -o:/app/interop main.nim


FROM debian:trixie-slim AS runtime

COPY --from=builder /app/interop /app/interop

ENTRYPOINT ["/app/interop"]
