# Runs test_autotls_docker.nim inside the containers' network namespace.
# Docker on macOS runs containers in a Linux VM, so `network_mode: host` attaches to the
# VM's loopback rather than the host's: a test running natively on macOS advertises an
# address the forge cannot reach.
ARG NIM_VERSION=2.2.10
ARG NIMBLE_COMMIT=aa8e6ea09ecac774b6fad42552569ce07bef37ec
FROM nimlang/nim:${NIM_VERSION}
ARG NIM_VERSION
ARG NIMBLE_COMMIT
ENV PATH="/root/.nimble/bin:/opt/nim/bin:${PATH}"

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates make \
    && rm -rf /var/lib/apt/lists/*

RUN nimble install "nimble@#${NIMBLE_COMMIT}" -y

COPY . .

# the context carries the host's nimble.paths and nimbledeps, which resolve to paths
# that do not exist here
RUN make clean-nim && make setup

RUN nim c -o:/app/test_autotls_docker tests/integration/autotls_docker/test_autotls_docker.nim

CMD ["/app/test_autotls_docker", "--output-level=VERBOSE", "--console"]
