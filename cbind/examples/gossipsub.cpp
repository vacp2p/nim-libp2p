// GossipSub pub/sub: two TCP nodes connect on a shared topic and exchange one
// message, delivered to the subscriber via `addOnPubsubMessageListener`. The
// old `cbindings.c` also drove Kademlia/service-discovery via host-supplied
// validator/selector callbacks, which can't cross the nim-ffi boundary.
#include "libp2p.hpp"
#include "bytes.hpp"

#include <chrono>
#include <condition_variable>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>

namespace {
constexpr int64_t TransportTcp = 1;
constexpr int64_t MuxerMplex = 0;

const std::string Topic = "/cbind/demo";

Libp2pConfig gossipsubConfig(const std::string& listenAddr) {
  return Libp2pConfig{
      .mountGossipsub = true,
      .gossipsubTriggerSelf = true,
      .mountKad = false,
      .mountServiceDiscovery = false,
      .addrs = {listenAddr},
      .muxer = MuxerMplex,
      .transport = TransportTcp,
  };
}
} // namespace

int main() {
  auto sub = LibP2PCtx::create(gossipsubConfig("/ip4/127.0.0.1/tcp/5021"));
  auto pub = LibP2PCtx::create(gossipsubConfig("/ip4/127.0.0.1/tcp/5022"));
  if (sub.isErr() || pub.isErr()) {
    std::cerr << "create: " << (sub.isErr() ? sub.error() : pub.error()) << "\n";
    return 1;
  }
  auto subscriber = std::move(sub.value());
  auto publisher = std::move(pub.value());

  std::mutex mtx;
  std::condition_variable cv;
  std::string received;
  bool got = false;

  subscriber->addOnPubsubMessageListener(
      [&](const OnPubsubMessagePayload& m) {
        std::lock_guard<std::mutex> lock(mtx);
        received = toString(m.data);
        got = true;
        cv.notify_one();
      });

  // Both peers subscribe so a GossipSub mesh can form between them.
  for (auto* node : {subscriber.get(), publisher.get()}) {
    if (auto r = node->gossipsub_subscribe(Topic); r.isErr()) {
      std::cerr << "subscribe: " << r.error() << "\n";
      return 1;
    }
    if (auto r = node->start(); r.isErr()) {
      std::cerr << "start: " << r.error() << "\n";
      return 1;
    }
  }

  auto subInfo = subscriber->peerinfo();
  if (subInfo.isErr()) {
    std::cerr << "peerinfo: " << subInfo.error() << "\n";
    return 1;
  }
  std::cout << "Subscriber: " << subInfo->peerId << "\n";

  if (auto r = publisher->connect(
          ConnectRequest{subInfo->peerId, subInfo->addrs, 0});
      r.isErr()) {
    std::cerr << "connect: " << r.error() << "\n";
    return 1;
  }

  // Give the subscription to propagate and the mesh to graft before publishing.
  std::this_thread::sleep_for(std::chrono::seconds(2));

  const std::string message = "hello gossipsub";
  std::cout << "Publishing: " << message << "\n";
  if (auto r = publisher->gossipsub_publish(PublishRequest{Topic, toBytes(message)});
      r.isErr()) {
    std::cerr << "publish: " << r.error() << "\n";
    return 1;
  }

  int status = 1;
  {
    std::unique_lock<std::mutex> lock(mtx);
    if (cv.wait_for(lock, std::chrono::seconds(10), [&] { return got; })) {
      std::cout << "Subscriber received: " << received << "\n";
      status = (received == message) ? 0 : 1;
    } else {
      std::cerr << "Error: timed out waiting for the message\n";
    }
  }

  (void)publisher->stop();
  (void)subscriber->stop();
  return status;
}
