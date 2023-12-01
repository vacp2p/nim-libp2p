# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:1.6.14 as builder

WORKDIR /workspace

COPY .pinned libp2p.nimble nim-libp2p/

RUN cd nim-libp2p && nimble install_pinned && nimble install redis -y

COPY . nim-libp2p/

RUN cd nim-libp2p && nim c --skipParentCfg --NimblePath:./nimbledeps/pkgs -d:chronicles_log_level=DEBUG -d:chronicles_default_output_device=stderr -d:release --threads:off --skipProjCfg -o:hole-punching-tests ./tests/hole-punching-interop/hole_punching.nim

FROM --platform=linux/amd64 debian:bookworm-slim
RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y dnsutils jq curl tcpdump iproute2
COPY --from=builder /workspace/nim-libp2p/hole-punching-tests /usr/bin/hole-punch-client
ENV RUST_BACKTRACE=1
