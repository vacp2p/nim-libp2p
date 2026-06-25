// Echo over a custom `/cbind/echo/1.0.0` protocol: a server node echoes the
// bytes it reads; a client node dials, sends a payload and verifies the echo.
// Generated methods are synchronous and return `Result<T>`; the only async
// surface is the server's incoming-stream event.
#include "libp2p.hpp"
#include "bytes.hpp"

#include <functional>
#include <iostream>
#include <string>
#include <thread>

namespace {
// TransportType / MuxerType ordinals, mirrored from cbind/libp2p.nim.
constexpr int64_t TransportTcp = 1;
constexpr int64_t MuxerMplex = 0;

const std::string EchoProto = "/cbind/echo/1.0.0";
constexpr int64_t EchoMaxSize = 4096;

// Runs on a detached thread so the library's event-dispatch thread is free
// while we block reading the request and writing the echo back.
void serveEcho(const LibP2PCtx& server, std::uint64_t streamId) {
  auto read = server.stream_read_lp(StreamReadLpRequest{streamId, EchoMaxSize});
  if (read.isErr()) {
    std::cerr << "server read: " << read.error() << "\n";
    return;
  }
  auto wrote = server.stream_write_lp(StreamWriteRequest{streamId, read->data});
  if (wrote.isErr()) {
    std::cerr << "server write: " << wrote.error() << "\n";
    return;
  }
  if (auto released = server.stream_release(streamId); released.isErr())
    std::cerr << "server release: " << released.error() << "\n";
}
} // namespace

int main() {
  Libp2pConfig serverCfg{
      .mountGossipsub = false,
      .mountKad = false,
      .mountServiceDiscovery = false,
      .addrs = {"/ip4/127.0.0.1/tcp/5013"},
      .muxer = MuxerMplex,
      .transport = TransportTcp,
  };

  auto serverRes = LibP2PCtx::create(serverCfg);
  if (serverRes.isErr()) {
    std::cerr << "create server: " << serverRes.error() << "\n";
    return 1;
  }
  auto server = std::move(serverRes.value());

  // Mount before start so peers learn about the protocol during identify.
  server->addOnIncomingStreamListener(
      [srv = server.get()](const OnIncomingStreamPayload& s) {
        std::thread(serveEcho, std::cref(*srv), s.streamId).detach();
      });
  if (auto r = server->mount_protocol(EchoProto); r.isErr()) {
    std::cerr << "mount_protocol: " << r.error() << "\n";
    return 1;
  }
  if (auto r = server->start(); r.isErr()) {
    std::cerr << "start server: " << r.error() << "\n";
    return 1;
  }

  auto serverInfoRes = server->peerinfo();
  if (serverInfoRes.isErr()) {
    std::cerr << "peerinfo: " << serverInfoRes.error() << "\n";
    return 1;
  }
  const auto& serverInfo = serverInfoRes.value();
  std::cout << "Echo server started: " << serverInfo.peerId << "\n";
  for (const auto& a : serverInfo.addrs)
    std::cout << "  " << a << "\n";

  Libp2pConfig clientCfg{
      .mountGossipsub = false,
      .mountKad = false,
      .mountServiceDiscovery = false,
      .addrs = {"/ip4/127.0.0.1/tcp/0"},
      .muxer = MuxerMplex,
      .transport = TransportTcp,
  };

  auto clientRes = LibP2PCtx::create(clientCfg);
  if (clientRes.isErr()) {
    std::cerr << "create client: " << clientRes.error() << "\n";
    return 1;
  }
  auto client = std::move(clientRes.value());
  if (auto r = client->start(); r.isErr()) {
    std::cerr << "start client: " << r.error() << "\n";
    return 1;
  }

  // Establish the peer connection first, then open a protocol stream via dial.
  if (auto r = client->connect(
          ConnectRequest{serverInfo.peerId, serverInfo.addrs, 0});
      r.isErr()) {
    std::cerr << "connect: " << r.error() << "\n";
    return 1;
  }

  auto dialRes = client->dial(DialRequest{serverInfo.peerId, EchoProto});
  if (dialRes.isErr()) {
    std::cerr << "dial: " << dialRes.error() << "\n";
    return 1;
  }
  const std::uint64_t streamId = dialRes->streamId;

  const std::string sent = "hello from cbind echo";
  std::cout << "Client sending: " << sent << "\n";
  if (auto r = client->stream_write_lp(StreamWriteRequest{streamId, toBytes(sent)});
      r.isErr()) {
    std::cerr << "stream_write_lp: " << r.error() << "\n";
    return 1;
  }

  auto readRes = client->stream_read_lp(StreamReadLpRequest{streamId, EchoMaxSize});
  if (readRes.isErr()) {
    std::cerr << "stream_read_lp: " << readRes.error() << "\n";
    return 1;
  }
  const std::string echoed = toString(readRes->data);
  std::cout << "Client received: " << echoed << "\n";

  int status = 0;
  if (echoed != sent) {
    std::cerr << "Error: echoed payload did not match\n";
    status = 1;
  }

  if (auto r = client->stream_close_with_eof(streamId); r.isErr())
    std::cerr << "stream_close_with_eof: " << r.error() << "\n";
  if (auto r = client->stream_release(streamId); r.isErr())
    std::cerr << "stream_release: " << r.error() << "\n";

  (void)client->stop();
  (void)server->stop();
  return status;
}
