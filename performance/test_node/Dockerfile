# Create the build image
FROM nimlang/nim:2.2.6-ubuntu-regular AS build

WORKDIR /node

COPY libp2p.nimble config.nims ./
RUN nimble install -y

COPY . .
RUN nimble c \
    --mm:refc \
    -d:chronicles_colors=None \
    -d:chronicles_log_level:INFO \
    --threads:on \
    -d:metrics \
    -d:libp2p_network_protocols_metrics \
    -d:release \
    performance/test_node/main.nim


FROM nimlang/nim:2.2.6-alpine-slim

COPY --from=build /node/performance/test_node/main /node/main
COPY performance/test_node/entrypoint.sh /node/entrypoint.sh

RUN chmod +x /node/main /node/entrypoint.sh \
    && apk add --no-cache curl iproute2

VOLUME ["/output"]

ENTRYPOINT ["/node/entrypoint.sh"]