{.used.}
## # Peer Scoring, Protection, and Trimming
##
## Tutorial 5 covered the `SwitchBuilder` knobs that *configure* the
## connection manager. This tutorial drives one of those configurations at
## runtime and shows what the connection manager actually *does*:
##
## 1. **When trim fires**: `highWater` triggers a trim cycle; the manager
##    schedules a trim cycle that attempts to reduce peers to `lowWater`,
##    skipping grace/protected peers.
## 2. **`protect` / `unprotect`**: keep a chosen peer immune from trim.
## 3. **Static tags**: bias trim selection with `tagPeer(peerId, tag, value)`.
## 4. **Decaying tags**: `tagPeerDecaying` plus `bumpDecayingTag`, watching
##    a score decay and recover.
##
## All four scenarios use one host plus several short-lived clients. The
## host is configured with very small timings so the example finishes in a
## couple of seconds:
##
## ```nim
## .withWatermark(
##   lowWater = 2, highWater = 3,
##   gracePeriod = 100.millis, silencePeriod = 50.millis)
## .withScoring(ScoringConfig(decayResolution: 50.millis))
## ```
##
## **Important:** trim is not time-based, it only runs when a new
## `storeMuxer` pushes the connected-peer count above `highWater`. Each
## scenario therefore stages its tags / protections *before* the connection
## that pushes the count over the line.

import chronos, strformat, std/sequtils
import libp2p

const
  LowWater = 2
  HighWater = 3
  GracePeriod = 100.millis
  SilencePeriod = 50.millis
  DecayResolution = 50.millis
  ## Long enough that all staged peers leave the grace window before the
  ## trigger connection is made.
  PostStageWait = 200.millis
  ## Long enough for `trimConnections` to finish once it is scheduled.
  TrimWait = 200.millis

proc createBaseBuilder(): SwitchBuilder =
  SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddress(MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet())
    .withTcpTransport()
    .withMplex()
    .withNoise()

proc makeHost(): Switch =
  createBaseBuilder()
    .withWatermark(
      lowWater = LowWater,
      highWater = HighWater,
      gracePeriod = GracePeriod,
      silencePeriod = SilencePeriod,
    )
    .withScoring(ScoringConfig(decayResolution: DecayResolution))
    .build()

proc makeClient(): Switch =
  createBaseBuilder().build()

proc connectClient(host, client: Switch) {.async.} =
  await client.connect(host.peerInfo.peerId, host.peerInfo.addrs)
  # Tiny gap so each peer's `connectedAt` is distinguishable.
  await sleepAsync(5.millis)

proc connectedIds(host: Switch): seq[PeerId] =
  host.connectedPeers(Direction.In)

proc main() {.async.} =
  ## ## 1. Trim fires when `highWater` is crossed
  ##
  ## Connect three clients (`= highWater`, no trim yet), wait out the grace
  ## period, then connect a fourth. The fourth connection's `storeMuxer`
  ## crosses `highWater` and schedules `trimConnections`, which closes peers
  ## until the count is back at `lowWater`. All clients have score 0, so the
  ## tiebreaker (oldest connection first) decides which two are dropped.
  block:
    let host = makeHost()
    let clients = @[makeClient(), makeClient(), makeClient(), makeClient()]
    await host.start()
    for c in clients:
      await c.start()

    for i in 0 .. 2:
      await connectClient(host, clients[i])
    echo fmt"1a. before trigger: connected = {host.connectedIds().len}"

    await sleepAsync(PostStageWait)
    await connectClient(host, clients[3])
    await sleepAsync(TrimWait)
    echo fmt"1b. after trigger:  connected = {host.connectedIds().len} (lowWater = {LowWater})"

    await allFutures(@[host.stop()] & clients.mapIt(it.stop()))

  ## ## 2. Protect / Unprotect
  ##
  ## A protected peer is skipped during trim regardless of score. Protection
  ## uses string tags and is multi-valued: a peer stays protected until *every*
  ## tag has been removed. `unprotect` returns `true` if any tag remains.
  ##
  ## To demonstrate that, the protection (not luck) is what saves the peer, the
  ## scenario runs trim twice. Once with the peer protected and once after
  ## `unprotect`. After unprotection the same peer is now eligible and gets
  ## dropped during the second trim.
  block:
    let host = makeHost()
    let clients = @[
      makeClient(), makeClient(), makeClient(), makeClient(), makeClient(), makeClient()
    ]
    await host.start()
    for c in clients:
      await c.start()

    let vipId = clients[0].peerInfo.peerId
    for i in 0 .. 2:
      await connectClient(host, clients[i])

    host.connManager.protect(vipId, "vip")
    echo fmt"2a. isProtected(vip) = {host.connManager.isProtected(vipId)}"

    await sleepAsync(PostStageWait)
    await connectClient(host, clients[3])
    await sleepAsync(TrimWait)
    let survived1 = vipId in host.connectedIds()
    echo fmt"2b. first trim:  vip survived = {survived1}, connected = {host.connectedIds().len}"

    let stillProtected = host.connManager.unprotect(vipId, "vip")
    echo fmt"2c. unprotect:   still-protected = {stillProtected}"

    # After the first trim the count is back at lowWater (2). We need to push
    # it strictly above highWater (3) again, count must reach 4, so connect
    # two more spares. The 4th connection schedules a fresh trim cycle.
    await sleepAsync(PostStageWait)
    await connectClient(host, clients[4])
    await connectClient(host, clients[5])
    await sleepAsync(TrimWait)
    let survived2 = vipId in host.connectedIds()
    echo fmt"2d. second trim: vip survived = {survived2}, connected = {host.connectedIds().len}"

    await allFutures(@[host.stop()] & clients.mapIt(it.stop()))

  ## ## 3. Static tags drive trim selection
  ##
  ## `tagPeer(peerId, tag, value)` adds `value` to the peer's score. Trim
  ## sorts candidates ascending by score and drops them in order until the
  ## peer count is back at `lowWater`. Tagged peers are pruned last.
  ##
  ## Two important caveats are visible in the output:
  ##
  ## * **Tags must be applied *before* the connection that triggers trim.**
  ##   The scoring snapshot is taken inside `trimConnections`, not later.
  ## * **The trigger peer is always inside `gracePeriod`** at the moment trim
  ##   runs (it just connected), so it is skipped regardless of score. The
  ##   trigger therefore always survives the trim cycle that it caused.
  block:
    let host = makeHost()
    let clients = @[makeClient(), makeClient(), makeClient(), makeClient()]
    await host.start()
    for c in clients:
      await c.start()

    let vip = clients[0].peerInfo.peerId
    let plain1 = clients[1].peerInfo.peerId
    let plain2 = clients[2].peerInfo.peerId
    let trigger = clients[3].peerInfo.peerId

    await connectClient(host, clients[0])
    host.connManager.tagPeer(vip, "vip", 100)
    await connectClient(host, clients[1])
    await connectClient(host, clients[2])

    await sleepAsync(PostStageWait)
    await connectClient(host, clients[3])
    await sleepAsync(TrimWait)

    let connected = host.connectedIds()
    echo fmt"3. survivors = {connected.len} (lowWater = {LowWater}), " &
      fmt"vip(100) in = {vip in connected}, " &
      fmt"plain1(0) in = {plain1 in connected}, " &
      fmt"plain2(0) in = {plain2 in connected}, " &
      fmt"trigger(grace) in = {trigger in connected}"
    echo fmt"   peerScore(vip) = {host.connManager.peerScore(vip)}"

    await allFutures(@[host.stop()] & clients.mapIt(it.stop()))

  ## ## 4. Decaying tags
  ##
  ## A decaying tag has an initial value and a `DecayFn` that is applied every
  ## `interval` by the connection manager's decay loop. Three factories ship
  ## with nim-libp2p:
  ##
  ## * `decayLinear(coef)`: multiply by `coef` each tick (e.g. 0.9 → -10%).
  ## * `decayFixed(amount)`: subtract `amount` each tick.
  ## * `decayNone()`: value stays constant; useful for "ephemeral but managed".
  ##
  ## When the value reaches 0 the tag is removed, so a later
  ## `bumpDecayingTag` is a no-op on a removed tag, re-call `tagPeerDecaying`
  ## to bring a fully-decayed peer back up.
  block:
    let host = makeHost()
    let clients = @[makeClient(), makeClient(), makeClient(), makeClient()]
    await host.start()
    for c in clients:
      await c.start()

    let p1 = clients[0].peerInfo.peerId
    let p2 = clients[1].peerInfo.peerId
    let p3 = clients[2].peerInfo.peerId
    let p4 = clients[3].peerInfo.peerId

    for i in 0 .. 2:
      await connectClient(host, clients[i])

    host.connManager.tagPeerDecaying(p1, "boost", 100, 50.millis, decayFixed(20))
    host.connManager.tagPeerDecaying(p2, "boost", 100, 50.millis, decayFixed(20))

    echo fmt"4a. initial scores: p1 = {host.connManager.peerScore(p1)}, p2 = {host.connManager.peerScore(p2)}, p3 = {host.connManager.peerScore(p3)}"

    # Five 50ms ticks at -20 each → tag drops to 0 and is removed.
    await sleepAsync(350.millis)
    echo fmt"4b. after decay:    p1 = {host.connManager.peerScore(p1)}, p2 = {host.connManager.peerScore(p2)}, p3 = {host.connManager.peerScore(p3)}"

    # p1 was auto-removed; re-establish its decaying tag instead of bumping.
    host.connManager.tagPeerDecaying(p1, "boost", 100, 50.millis, decayNone())
    echo fmt"4c. after re-tag:   p1 = {host.connManager.peerScore(p1)}"

    # Trigger trim by connecting the fourth client. At trim time p1 has
    # score 100, p2 and p3 have score 0, and p4 is in grace. Trim drops the
    # two zero-score peers; p1 survives on score, p4 survives on grace.
    await connectClient(host, clients[3])
    await sleepAsync(TrimWait)
    let connected = host.connectedIds()
    echo fmt"4d. survivors = {connected.len}, " & fmt"p1(100) in = {p1 in connected}, " &
      fmt"p2(0) in = {p2 in connected}, " & fmt"p3(0) in = {p3 in connected}, " &
      fmt"p4(grace) in = {p4 in connected}"
    echo fmt"   peerScore(p1) = {host.connManager.peerScore(p1)}"

    # `bumpDecayingTag` adds to a *live* tag. Demonstrate it by bumping p1
    # while its tag still exists.
    host.connManager.bumpDecayingTag(p1, "boost", 50)
    echo fmt"4e. after bump:    p1 = {host.connManager.peerScore(p1)}"

    await allFutures(@[host.stop()] & clients.mapIt(it.stop()))

waitFor(main())

## ## Running
##
## ```
## nim c -p:../ -d:chronicles_log_level=error -r tutorial_6_peerscoring.nim
## ```
##
## ## Summary
##
## | Scenario | API exercised | Outcome |
## |---|---|---|
## | 1. Trim trigger | `withWatermark` | count drops from `highWater + 1` to `lowWater` after the next `storeMuxer` |
## | 2. Protect / Unprotect | `protect`, `unprotect`, `isProtected` | tagged peer survives trim; loses immunity once all tags removed |
## | 3. Static tags | `tagPeer`, `peerScore` | high-score peers survive; low/no-score peers pruned first |
## | 4. Decaying tags | `tagPeerDecaying`, `bumpDecayingTag`, `decayFixed` / `decayNone` / `decayLinear` | score decays per tick, can be bumped while live, must be re-tagged once removed |
