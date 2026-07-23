# syntax=docker/dockerfile:1.5-labs
ARG NIM_VERSION=2.2.10
FROM nimlang/nim:${NIM_VERSION} as builder
ARG NIM_VERSION

WORKDIR /app

COPY libp2p.nimble nim-libp2p/
COPY interop/hole-punching-v2/interop_hole_punching_v2.nimble nim-libp2p/interop/hole-punching-v2/

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y --no-install-recommends ca-certificates binutils libssl-dev \
  && rm -rf /var/lib/apt/lists/*

COPY . nim-libp2p/

RUN cd nim-libp2p/interop/hole-punching-v2 && \
  nimble --noLockfile --requires:"nim == ${NIM_VERSION}" --resolver:minver -l setup -y && \
  nim c -d:release \
  --mm:refc --threads:on \
  -d:chronicles_log_level=INFO -d:chronicles_default_output_device=stderr -d:chronicles_colors=None \
  -o:/app/peer hole_punching.nim

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y iproute2 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/peer /usr/bin/peer
COPY interop/hole-punching-v2/run-peer.sh /usr/bin/run-peer.sh
RUN chmod +x /usr/bin/run-peer.sh
ENTRYPOINT ["/usr/bin/run-peer.sh"]
