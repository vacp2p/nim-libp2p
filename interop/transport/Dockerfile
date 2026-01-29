# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:2.2.6-ubuntu-regular as builder

WORKDIR /app

COPY .pinned libp2p.nimble nim-libp2p/

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y --no-install-recommends ca-certificates binutils \
    && rm -rf /var/lib/apt/lists/*

RUN cd nim-libp2p && nimble install_pinned && nimble install redis -y

COPY . nim-libp2p/

RUN \
  cd nim-libp2p && \
  nim c -d:release --skipProjCfg --skipParentCfg --NimblePath:./nimbledeps/pkgs2 -p:nim-libp2p --mm:refc -d:chronicles_log_level=WARN -d:chronicles_default_output_device=stderr --threads:on -o:/app/interop ./interop/transport/main.nim


FROM debian:trixie-slim AS runtime

COPY --from=builder /app/interop /app/interop

ENTRYPOINT ["/app/interop"]
