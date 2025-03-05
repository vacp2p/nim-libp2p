# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:1.6.16 as builder

WORKDIR /app

COPY .pinned libp2p.nimble nim-libp2p/

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y python python3 python3-pip python3-venv curl

RUN  mkdir .venv && python3 -m venv .venv && . .venv/bin/activate

RUN cd nim-libp2p && nimble install_pinned && nimble install "redis@#b341fe240dbf11c544011dd0e033d3c3acca56af" -y

COPY . nim-libp2p/

RUN \
  cd nim-libp2p && \
  nim c --skipProjCfg --skipParentCfg --NimblePath:./nimbledeps/pkgs -p:nim-libp2p -d:chronicles_log_level=WARN -d:chronicles_default_output_device=stderr --threads:off ./tests/transport-interop/main.nim

ENTRYPOINT ["/app/nim-libp2p/tests/transport-interop/main"]
