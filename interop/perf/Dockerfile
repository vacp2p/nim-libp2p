# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:2.2.10 as builder

WORKDIR /app

COPY libp2p.nimble nim-libp2p/
COPY interop/perf/interop_perf.nimble interop/perf/nimble.lock nim-libp2p/interop/perf/

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y --no-install-recommends ca-certificates binutils \
    && rm -rf /var/lib/apt/lists/*

RUN cd nim-libp2p/interop/perf && nimble -l install -dy

COPY . nim-libp2p/

RUN \
  cd nim-libp2p/interop/perf && \
  nimble -l setup && \
  nim c -d:release --mm:refc -d:chronicles_log_level=INFO -d:chronicles_default_output_device=stderr -d:chronicles_colors=None --threads:on -o:/app/perf-interop main.nim

FROM debian:trixie-slim AS runtime

COPY --from=builder /app/perf-interop /app/perf-interop

ENTRYPOINT ["/app/perf-interop"]
