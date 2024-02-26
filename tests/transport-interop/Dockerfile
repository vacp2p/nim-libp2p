# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:1.6.16 as builder

WORKDIR /app

COPY .pinned libp2p.nimble nim-libp2p/

RUN cd nim-libp2p && nimble install_pinned && nimble install "redis@#b341fe240dbf11c544011dd0e033d3c3acca56af" -y

COPY . nim-libp2p/

RUN \
  cd nim-libp2p && \
  nim c --skipProjCfg --skipParentCfg --NimblePath:./nimbledeps/pkgs -p:nim-libp2p -d:chronicles_log_level=WARN --threads:off ./tests/transport-interop/main.nim

ENTRYPOINT ["/app/tests/transport-interop/main"]
