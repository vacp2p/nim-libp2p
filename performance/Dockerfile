# Create the build image
FROM nimlang/nim:1.6.18 AS build

WORKDIR /node

COPY libp2p.nimble config.nims ./
RUN git config --global http.sslVerify false
RUN nimble install -y

COPY . .
RUN nimble c -d:chronicles_colors=None --threads:on -d:metrics -d:libp2p_network_protocols_metrics -d:release performance/main.nim


FROM nimlang/nim:1.6.18

WORKDIR /node

COPY --from=build /node/performance/main /node/main

RUN chmod +x main

EXPOSE 5000 8008

# The shared volume will be mounted at /output by runner.sh
VOLUME ["/output"]

ENTRYPOINT ["./main"]