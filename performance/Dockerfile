# Create the build image
FROM nimlang/nim:2.2.4-alpine-regular AS build

# Build argument to toggle reliability scenarios
ARG PERF_RELIABILITY=false
ENV PERF_RELIABILITY=${PERF_RELIABILITY}

WORKDIR /node

COPY libp2p.nimble config.nims ./
RUN git config --global http.sslVerify false
RUN apk add --no-cache openssl-dev pkgconfig
RUN nimble install -y

COPY . .
RUN set -e && \
    if [ "$PERF_RELIABILITY" = "true" ]; then \
        EXTRA="-d:perf_reliability"; \
    else \
        EXTRA=""; \
    fi && \
    echo "Building with PERF_RELIABILITY=$PERF_RELIABILITY (flags: $EXTRA)" && \
    nimble c \
        -d:chronicles_colors=None \
        -d:chronicles_log_level:INFO \
        --threads:on \
        -d:metrics \
        -d:libp2p_network_protocols_metrics \
        -d:libp2p_quic_support \
        -d:release \
        $EXTRA \
        performance/main.nim


FROM nimlang/nim:2.2.4-alpine-slim

WORKDIR /node

COPY --from=build /node/performance/main /node/main

RUN chmod +x main \
  && apk add --no-cache curl iproute2 openssl

VOLUME ["/output"]

ENTRYPOINT ["./main"]