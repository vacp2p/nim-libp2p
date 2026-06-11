# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:2.2.10 as builder

WORKDIR /app

COPY .pinned libp2p.nimble nim-libp2p/

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y --no-install-recommends ca-certificates binutils libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN cd nim-libp2p && nimble install -y redis && nimble install_pinned

COPY . nim-libp2p/

RUN cd nim-libp2p && \
  nim c -d:release --skipProjCfg --skipParentCfg --NimblePath:./nimbledeps/pkgs2 \
  --mm:refc --threads:on \
  -d:chronicles_log_level=INFO -d:chronicles_default_output_device=stderr -d:chronicles_colors=None \
  -o:/app/peer ./interop/hole-punching/hole_punching.nim

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends bind9-dnsutils curl iproute2 jq tcpdump \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/peer /usr/bin/hole-punch-client
CMD ["hole-punch-client"]
