# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import sequtils, strutils

import chronos, chronicles

import ./client,
       ./rconn,
       ./utils,
       ../../../switch,
       ../../../stream/connection,
       ../../../transports/transport

logScope:
  topics = "libp2p relay relay-transport"

type
  RelayTransport* = ref object of Transport
    client*: RelayClient
    queue: AsyncQueue[Connection]
    selfRunning: bool

method start*(self: RelayTransport, ma: seq[MultiAddress]) {.async.} =
  if self.selfRunning:
    trace "Relay transport already running"
    return

  self.client.onNewConnection = proc(
    conn: Connection,
    duration: uint32 = 0,
    data: uint64 = 0) {.async, gcsafe, raises: [].} =
      await self.queue.addLast(RelayConnection.new(conn, duration, data))
      await conn.join()
  self.selfRunning = true
  await procCall Transport(self).start(ma)
  trace "Starting Relay transport"

method stop*(self: RelayTransport) {.async, gcsafe.} =
  self.running = false
  self.selfRunning = false
  self.client.onNewConnection = nil
  while not self.queue.empty():
    await self.queue.popFirstNoWait().close()

method accept*(self: RelayTransport): Future[Connection] {.async, gcsafe.} =
  result = await self.queue.popFirst()

proc dial*(self: RelayTransport, ma: MultiAddress): Future[Connection] {.async, gcsafe.} =
  let
    sma = toSeq(ma.items())
    relayAddrs = sma[0..sma.len-4].mapIt(it.tryGet()).foldl(a & b)
  var
    relayPeerId: PeerId
    dstPeerId: PeerId
  if not relayPeerId.init(($(sma[^3].get())).split('/')[2]):
    raise newException(RelayV2DialError, "Relay doesn't exist")
  if not dstPeerId.init(($(sma[^1].get())).split('/')[2]):
    raise newException(RelayV2DialError, "Destination doesn't exist")
  trace "Dial", relayPeerId, dstPeerId

  let conn = await self.client.switch.dial(
    relayPeerId,
    @[ relayAddrs ],
    @[ RelayV2HopCodec, RelayV1Codec ])
  conn.dir = Direction.Out
  var rc: RelayConnection
  try:
    case conn.protocol:
    of RelayV1Codec:
      return await self.client.dialPeerV1(conn, dstPeerId, @[])
    of RelayV2HopCodec:
      rc = RelayConnection.new(conn, 0, 0)
      return await self.client.dialPeerV2(rc, dstPeerId, @[])
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    if not rc.isNil: await rc.close()
    raise exc

method dial*(
  self: RelayTransport,
  hostname: string,
  ma: MultiAddress,
  peerId: Opt[PeerId] = Opt.none(PeerId)): Future[Connection] {.async, gcsafe.} =
  let address = MultiAddress.init($ma & "/p2p/" & $peerId.get()).tryGet()
  result = await self.dial(address)

method handles*(self: RelayTransport, ma: MultiAddress): bool {.gcsafe} =
  if ma.protocols.isOk():
    let sma = toSeq(ma.items())
    result = sma.len >= 2 and CircuitRelay.match(sma[^1].get())
  trace "Handles return", ma, result

proc new*(T: typedesc[RelayTransport], cl: RelayClient, upgrader: Upgrade): T =
  result = T(client: cl, upgrader: upgrader)
  result.running = true
  result.queue = newAsyncQueue[Connection](0)
