{.used.}
## # Connection Manager Configuration
##
## This tutorial demonstrates how to configure the connection
## manager through `SwitchBuilder` as an API showcase.  
## The connection manager controls how many simultaneous connections a switch accepts, 
## and can optionally trim low-scoring peers via watermark logic.
##
## You'll find all configuration options in the `withMaxConnections`,
## `withMaxInOut`, and `withWatermark` builder methods.
import chronos, strformat

import libp2p

## Helper used to create `SwitchBuilder` with basic options shared in all scenarios.
proc createBaseBuilder(): SwitchBuilder =
  return SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddress(MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet())
    .withTcpTransport()
    .withMplex()
    .withNoise()

proc connectPeer(switch: Switch, name: string, description: string) {.async.} =
  await switch.start()

  let peer = createBaseBuilder().build()
  await peer.start()
  await peer.connect(switch.peerInfo.peerId, switch.peerInfo.addrs)

  let count = switch.connectedPeers(In).len
  echo fmt"{name:<60} connected = {count}", "\t", description

  await allFutures(switch.stop(), peer.stop())

## The seven configurations
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

    await connectPeer(switch, "1. .build()", "(shared limit: 50)")

  ## ### 2. `.withMaxConnections(100)` — raise the shared cap
  ##
  ## Both incoming and outgoing connections share one semaphore of size 100.
  ## The 101st connection attempt raises error on the dialing side (outgoing) or 
  ## blocks until a slot is released (incoming).
  block:
    let switch = createBaseBuilder().withMaxConnections(100).build()

    await connectPeer(switch, "2. .withMaxConnections(100)", "(shared limit: 100)")

  ## ### 3. `.withMaxInOut(30, 20)` — independent per-direction caps
  ##
  ## Two separate semaphores are created: 30 slots for **incoming**
  ## connections and 20 slots for **outgoing** dials.  Outbound traffic
  ## can never exhaust the inbound pool and vice-versa, giving finer
  ## control over how bandwidth is allocated.
  block:
    let switch = createBaseBuilder().withMaxInOut(30, 20).build()

    await connectPeer(
      switch, "3. .withMaxInOut(30, 20)", "(in-limit: 30, out-limit: 20)"
    )

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

    await connectPeer(
      switch, "4. .withWatermark(10, 20)",
      "(no hard cap; trims to 10 once 20 are connected)",
    )

  ## ### 5. `.withWatermark(10, 20, gracePeriod = 30.seconds, silencePeriod = 5.seconds)` — custom timing
  ##
  ## `gracePeriod` protects newly connected peers from being trimmed: any peer
  ## that connected less than `gracePeriod` ago is skipped when the connection
  ## manager prunes down to `lowWater`.  Shortening it from the default 1 minute
  ## to 30 seconds makes the trimmer willing to drop peers sooner after they connect.
  ##
  ## `silencePeriod` is a cooldown between successive trim cycles: once a trim
  ## run finishes, the next cycle cannot start until `silencePeriod` has elapsed.
  ## Reducing it from the default 10 seconds to 5 seconds lets the connection
  ## manager react faster when many peers connect in quick succession.
  ##
  ## Tune these two durations together to balance connection churn against
  ## responsiveness: a long grace period preserves recently opened connections
  ## longer, while a short silence period allows more frequent pruning passes.
  block:
    let switch = createBaseBuilder()
      .withWatermark(10, 20, gracePeriod = 30.seconds, silencePeriod = 5.seconds)
      .build()

    await connectPeer(
      switch, "5. .withWatermark(gracePeriod=30s, silencePeriod=5s)",
      "(trims at 20; grace 30 s; silence 5 s)",
    )

  ## ### 6. `.withWatermark(10, 20).withMaxConnections(30)` — hard cap + trimming
  ##
  ## A semaphore enforces an absolute ceiling of 30 connections while
  ## watermark trimming keeps the active peer count near 10 long before that
  ## ceiling is ever reached.  Both guards operate simultaneously: the
  ## semaphore blocks new connections at the limit, and the trimmer prunes
  ## existing ones once the high-water mark is hit.
  block:
    let switch =
      createBaseBuilder().withWatermark(10, 20).withMaxConnections(30).build()

    await connectPeer(
      switch, "6. .withWatermark(10,20).withMaxConnections(30)",
      "(hard cap: 30; trims at 20)",
    )

  ## ### 7. `.withWatermark(10, 20).withMaxInOut(30, 20)` — per-direction caps + trimming
  ##
  ## The most granular configuration: two independent semaphores (30 incoming,
  ## 20 outgoing) combined with watermark trimming.  New connections are
  ## blocked by the per-direction caps, and existing connections are pruned
  ## asynchronously once the total peer count exceeds 20.
  block:
    let switch = createBaseBuilder().withWatermark(10, 20).withMaxInOut(30, 20).build()

    await connectPeer(
      switch, "7. .withWatermark(10,20).withMaxInOut(30,20)",
      "(in-limit: 30, out-limit: 20; trims at 20)",
    )

waitFor(main())

## Running this program with `nim c -p:../ -d:chronicles_log_level=error -r tutorial_5_connmanager.nim` produces
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
## | `.withWatermark(10, 20, gracePeriod = 30.seconds, silencePeriod = 5.seconds)` | Custom trim timing: 30s grace, 5s cooldown |
## | `.withWatermark(10, 20).withMaxConnections(30)` | Hard cap at 30 + trim at 20 |
## | `.withWatermark(10, 20).withMaxInOut(30, 20)` | Separate limits + trim at 20 |
