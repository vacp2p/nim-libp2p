# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:latest as builder

WORKDIR /app

COPY .pinned libp2p.nimble nim-libp2p/ 

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y libssl-dev

RUN cd nim-libp2p && nimble install_pinned && nimble install redis -y

COPY . nim-libp2p/

RUN \
  cd nim-libp2p && \
  nim c --skipProjCfg --skipParentCfg --NimblePath:./nimbledeps/pkgs -p:nim-libp2p --mm:refc -d:libp2p_quic_support -d:chronicles_log_level=WARN -d:chronicles_default_output_device=stderr --threads:off ./interop/transport/main.nim

ENTRYPOINT ["/app/nim-libp2p/interop/transport/main"]
