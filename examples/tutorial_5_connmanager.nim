{.used.}
## # Connection Manager Configuration
##
## This tutorial demonstrates the six ways to configure the connection
## manager through `SwitchBuilder` as a API showcase.  
## The connection manager controls how many simultaneous connections a switch accepts, 
## and can optionally trim idle peers via watermark logic.
##
## You'll find all configuration options in the `withMaxConnections`,
## `withMaxInOut`, and `withWatermark` builder methods.
import chronos

import libp2p

## Helper used to create `SwitchBuilder` with basic options shared in all scenarions.
proc createBaseBuilder(): SwitchBuilder =
  return SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddress(MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet())
    .withTcpTransport()
    .withMplex()
    .withNoise()

proc createPeer(): Switch =
  createBaseBuilder().build()

## The six configurations
##
## Each block below creates a switch with a different connection-manager
## configuration, starts it, connects one peer, prints the connected-peer
## count, then shuts everything down cleanly.

proc main() {.async.} =
  ## ### 1. `.build()` — default shared limit at 50
  ##
  ## When no connection-limit option is supplied the switch uses a default, 
  ## **shared** semaphore capped at `MaxConnections` (50).  Both incoming and outgoing
  ## connections draw from the same pool, so the total can never exceed 50.
  block:
    let switch = createBaseBuilder().build()
    await switch.start()

    let peer = createPeer()
    await peer.start()
    await peer.connect(switch.peerInfo.peerId, switch.peerInfo.addrs)
    let count = switch.connectedPeers(In).len
    echo "1. .build()\t\t\t\t\t\tconnected = ", count, "\t(shared limit: 50)"

    await allFutures(switch.stop(), peer.stop())

  ## ### 2. `.withMaxConnections(100)` — raise the shared cap
  ##
  ## Both incoming and outgoing connections share one semaphore of size 100.
  ## The 101st connection attempt raises `TooManyConnectionsError` on the
  ## dialing side (outgoing) or blocks until a slot is released (incoming).
  block:
    let switch = createBaseBuilder().withMaxConnections(100).build()
    await switch.start()

    let peer = createPeer()
    await peer.start()
    await peer.connect(switch.peerInfo.peerId, switch.peerInfo.addrs)
    let count = switch.connectedPeers(In).len
    echo "2. .withMaxConnections(100)\t\t\t\tconnected = ",
      count, "\t(shared limit: 100)"

    await allFutures(switch.stop(), peer.stop())

  ## ### 3. `.withMaxInOut(30, 20)` — independent per-direction caps
  ##
  ## Two separate semaphores are created: 30 slots for **incoming**
  ## connections and 20 slots for **outgoing** dials.  Outbound traffic
  ## can never exhaust the inbound pool and vice-versa, giving finer
  ## control over how bandwidth is allocated.
  block:
    let switch = createBaseBuilder().withMaxInOut(30, 20).build()
    await switch.start()

    let peer = createPeer()
    await peer.start()
    await peer.connect(switch.peerInfo.peerId, switch.peerInfo.addrs)
    let count = switch.connectedPeers(In).len
    echo "3. .withMaxInOut(30, 20)\t\t\t\tconnected = ",
      count, "\t(in-limit: 30, out-limit: 20)"

    await allFutures(switch.stop(), peer.stop())

  ## ### 4. `.withWatermark(10, 20)` — soft trimming, no hard cap
  ##
  ## No semaphore is created — the switch **never blocks** an incoming
  ## connection based on count alone.  Instead, once the connected-peer count
  ## reaches the **high-water mark** (20), the connection manager
  ## asynchronously trims down to the **low-water mark** (10) by closing
  ## the lowest-scoring peers.  Peers within the grace period (default 1 min)
  ## and protected peers are skipped during trimming.
  block:
    let switch = createBaseBuilder().withWatermark(10, 20).build()
    await switch.start()

    let peer = createPeer()
    await peer.start()
    await peer.connect(switch.peerInfo.peerId, switch.peerInfo.addrs)
    let count = switch.connectedPeers(In).len
    echo "4. .withWatermark(10, 20)\t\t\t\tconnected = ",
      count, "\t(no hard cap; trims to 10 once 20 are connected)"

    await allFutures(switch.stop(), peer.stop())

  ## ### 5. `.withWatermark(10, 20).withMaxConnections(30)` — hard cap + trimming
  ##
  ## A semaphore enforces an absolute ceiling of 30 connections while
  ## watermark trimming keeps the active peer count near 10 long before that
  ## ceiling is ever reached.  Both guards operate simultaneously: the
  ## semaphore blocks new connections at the limit, and the trimmer prunes
  ## existing ones once the high-water mark is hit.
  block:
    let switch =
      createBaseBuilder().withWatermark(10, 20).withMaxConnections(30).build()
    await switch.start()

    let peer = createPeer()
    await peer.start()
    await peer.connect(switch.peerInfo.peerId, switch.peerInfo.addrs)
    let count = switch.connectedPeers(In).len
    echo "5. .withWatermark(10,20).withMaxConnections(30)\t\tconnected = ",
      count, "\t(hard cap: 30; trims at 20)"

    await allFutures(switch.stop(), peer.stop())

  ## ### 6. `.withWatermark(10, 20).withMaxInOut(30, 20)` — per-direction caps + trimming
  ##
  ## The most granular configuration: two independent semaphores (30 incoming,
  ## 20 outgoing) combined with watermark trimming.  New connections are
  ## blocked by the per-direction caps, and existing connections are pruned
  ## asynchronously once the total peer count exceeds 20.
  block:
    let switch = createBaseBuilder().withWatermark(10, 20).withMaxInOut(30, 20).build()
    await switch.start()

    let peer = createPeer()
    await peer.start()
    await peer.connect(switch.peerInfo.peerId, switch.peerInfo.addrs)
    let count = switch.connectedPeers(In).len
    echo "6. .withWatermark(10,20).withMaxInOut(30,20)\t\tconnected = ",
      count, "\t(in-limit: 30, out-limit: 20; trims at 20)"

    await allFutures(switch.stop(), peer.stop())

waitFor(main())

## Running this program with `nim c -r -d:chronicles_log_level=error tutorial_5_connmanager.nim` produces
## one line per scenario, each showing `connected = 1`, confirming that each
## configuration accepts connections normally under its limit.
##
## ## Summary
##
## | Builder call | Effect |
## |---|---|
## | `.build()` | Shared limit at 50 (default `MaxConnections`) |
## | `.withMaxConnections(100)` | Shared limit at 100 |
## | `.withMaxInOut(30, 20)` | Separate limits: 30 incoming / 20 outgoing |
## | `.withWatermark(10, 20)` | No hard cap; trims to 10 once 20 connected |
## | `.withWatermark(10, 20).withMaxConnections(30)` | Hard cap at 30 + trim at 20 |
## | `.withWatermark(10, 20).withMaxInOut(30, 20)` | Separate limits + trim at 20 |
