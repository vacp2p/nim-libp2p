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
# The upstream harness runs these tools in participant containers before the client.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bind9-dnsutils curl iproute2 jq tcpdump \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/peer /usr/bin/nim-hole-punch-client
COPY interop/hole-punching/hole-punch-client.sh /usr/bin/hole-punch-client
COPY interop/hole-punching/hole-punch-router-nat.sh /usr/bin/hole-punch-router-nat
COPY interop/hole-punching/hole-punch-entrypoint.sh /usr/bin/hole-punch-entrypoint
RUN chmod +x /usr/bin/hole-punch-client /usr/bin/hole-punch-router-nat /usr/bin/hole-punch-entrypoint
ENTRYPOINT ["/usr/bin/hole-punch-entrypoint"]
CMD ["hole-punch-client"]
