# Create the build image
FROM nimlang/nim:2.2.4-alpine-regular AS build

WORKDIR /node

COPY libp2p.nimble config.nims ./
RUN git config --global http.sslVerify false
RUN nimble install -y
RUN apk add --no-cache build-base openssl-dev

COPY . .
RUN nimble c -d:chronicles_colors=None --threads:on -d:metrics -d:libp2p_quic_support -d:libp2p_network_protocols_metrics -d:release  performance/main.nim



FROM nimlang/nim:2.2.4-alpine-slim


WORKDIR /node


COPY --from=build /node/performance/main /node/main

RUN apk add --no-cache build-base openssl-dev


RUN chmod +x main \
  && apk add --no-cache curl iproute2

VOLUME ["/output"]

ENTRYPOINT ["./main"]