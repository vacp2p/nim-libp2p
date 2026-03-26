# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:latest as builder

WORKDIR /workspace

COPY .pinned libp2p.nimble nim-libp2p/

RUN apt-get update && apt-get install -y libssl-dev

RUN cd nim-libp2p && nimble install_pinned && nimble install redis -y

COPY . nim-libp2p/

RUN cd nim-libp2p && nim c --skipParentCfg --NimblePath:./nimbledeps/pkgs2 --mm:refc -d:chronicles_log_level=DEBUG -d:chronicles_default_output_device=stderr -d:release --threads:off --skipProjCfg -o:hole-punching-tests ./interop/hole-punching/hole_punching.nim

FROM --platform=linux/amd64 debian:bullseye-slim
RUN apt-get update && apt-get install -y dnsutils jq curl tcpdump iproute2 libssl-dev && rm -rf /var/lib/apt/lists/*
COPY --from=builder /workspace/nim-libp2p/hole-punching-tests /usr/bin/hole-punch-client
ENV RUST_BACKTRACE=1
