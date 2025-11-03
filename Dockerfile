# Create the build image
FROM nimlang/nim:2.2.6-ubuntu-regular AS build

WORKDIR /node
COPY . .

RUN git config --global http.sslVerify false

RUN nimble install -dy

RUN nimble c \
    -d:chronicles_colors=None --threads:on \
    -d:metrics -d:libp2p_network_protocols_metrics -d:release \
    quic.nim

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    iproute2 \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

WORKDIR /node

COPY --from=build /node/quic /node/quic

RUN chmod +x quic

EXPOSE 5000 8008

ENTRYPOINT ["./quic"]