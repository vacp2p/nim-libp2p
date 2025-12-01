# Create the build image
FROM nimlang/nim:2.2.6-ubuntu-regular AS build

WORKDIR /node
COPY . .

RUN git config --global http.sslVerify false

#    --passL:"./libtcmalloc.so" \
#     --gc:orc -d:useMalloc \

RUN nim c \
     -d:chronicles_sinks=json \
    --threads:on \  
    --mm:refc \
    -d:metrics \
    -d:libp2p_network_protocols_metrics \
    -d:pubsubpeer_queue_metrics \
    -d:release \
    quic.nim

FROM nimlang/nim:2.2.6-ubuntu-regular

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    iproute2 \
    ethtool \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

WORKDIR /node

COPY --from=build /node/quic /node/quic

COPY ./libtcmalloc.so .

COPY ./entrypoint.sh .

RUN chmod +x quic

EXPOSE 5000 8008

ENTRYPOINT ["./entrypoint.sh"]