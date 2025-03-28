# syntax=docker/dockerfile:1.5-labs
FROM nimlang/nim:1.6.16 as builder

WORKDIR /app

COPY .pinned libp2p.nimble nim-libp2p/

RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt install -y wget build-essential

RUN wget -nv https://www.openssl.org/source/openssl-3.0.13.tar.gz && \
    tar -xzf openssl-3.0.13.tar.gz && \
    cd openssl-3.0.13 && \
    ./Configure linux-x86_64 shared --prefix=/opt/openssl3 && \
    make -j$(nproc) && \
    make install_sw

RUN cd nim-libp2p && nimble install_pinned && nimble install "redis@#b341fe240dbf11c544011dd0e033d3c3acca56af" -y

COPY . nim-libp2p/

RUN \
  cd nim-libp2p && \
  nim c --skipProjCfg --skipParentCfg --NimblePath:./nimbledeps/pkgs \
  --passC:"-I/opt/openssl3/include" \
  --passL:"-L/opt/openssl3/lib64 -lcrypto" \
  -p:nim-libp2p -d:chronicles_log_level=WARN -d:chronicles_default_output_device=stderr --threads:off ./tests/transport-interop/main.nim

ENTRYPOINT ["/app/nim-libp2p/tests/transport-interop/main"]
