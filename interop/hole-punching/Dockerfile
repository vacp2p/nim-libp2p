# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:2.2.10-ubuntu-regular as builder

WORKDIR /app

COPY .pinned libp2p.nimble nim-libp2p/

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y --no-install-recommends ca-certificates binutils libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN cd nim-libp2p && nimble install_pinned && nimble install redis -y

COPY . nim-libp2p/

RUN cd nim-libp2p && \
  nim c -d:release --skipProjCfg --skipParentCfg --NimblePath:./nimbledeps/pkgs2 \
  -p:nim-libp2p --mm:refc --threads:on \
  -d:chronicles_log_level=INFO -d:chronicles_default_output_device=stderr -d:chronicles_colors=None \
  -o:/app/peer ./interop/hole-punching/hole_punching.nim

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y iproute2 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/peer /usr/bin/peer
COPY interop/hole-punching/run-peer.sh /usr/bin/run-peer.sh
RUN chmod +x /usr/bin/run-peer.sh
ENTRYPOINT ["/usr/bin/run-peer.sh"]
