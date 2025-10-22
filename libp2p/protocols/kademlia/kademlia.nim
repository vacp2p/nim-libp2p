# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, chronicles, results
import ../../utils/heartbeat
import ../../[peerid, switch, multihash]
import ../protocol
import ./[routingtable, protobuf, types]
import rpc/[find, get, put, provider, ping]

export find, get, put, provider, ping

logScope:
  topics = "kad-dht"

proc bootstrap*(
    kad: KadDHT, bootstrapNodes: seq[PeerInfo]
) {.async: (raises: [CancelledError]).} =
  for b in bootstrapNodes:
    try:
      await kad.switch.connect(b.peerId, b.addrs)
      debug "Connected to bootstrap peer", peerId = b.peerId
    except DialFailedError as exc:
      # at some point will want to bubble up a Result[void, SomeErrorEnum]
      error "failed to dial to bootstrap peer", peerId = b.peerId, error = exc.msg
      continue

    let msg =
      try:
        await kad.sendFindNode(b.peerId, b.addrs, kad.rtable.selfId).wait(
          chronos.seconds(5)
        )
      except CatchableError as exc:
        debug "Send find node exception during bootstrap",
          target = b.peerId, addrs = b.addrs, err = exc.msg
        continue
    for peer in msg.closerPeers:
      let p = PeerId.init(peer.id).valueOr:
        debug "Invalid peer id received", error = error
        continue
      discard kad.rtable.insert(p)

      kad.switch.peerStore[AddressBook][p] = peer.addrs

    # bootstrap node replied succesfully. Adding to routing table
    discard kad.rtable.insert(b.peerId)

  let key = PeerId.random(kad.rng).valueOr:
    doAssert(false, "this should never happen")
    return
  discard await kad.findNode(key.toKey())
  info "Bootstrap lookup complete"

proc refreshBuckets(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  for i in 0 ..< kad.rtable.buckets.len:
    if kad.rtable.buckets[i].isStale():
      let randomKey = randomKeyInBucketRange(kad.rtable.selfId, i, kad.rng)
      discard await kad.findNode(randomKey)

proc maintainBuckets(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh buckets", chronos.minutes(10):
    await kad.refreshBuckets()

proc new*(
    T: typedesc[KadDHT],
    switch: Switch,
    config: KadDHTConfig = KadDHTConfig.new(),
    rng: ref HmacDrbgContext = newRng(),
): T {.raises: [].} =
  var rtable = RoutingTable.new(
    switch.peerInfo.peerId.toKey(),
    config = RoutingTableConfig.new(replication = config.replication),
  )
  let kad = T(rng: rng, switch: switch, rtable: rtable, config: config)

  kad.codec = KadCodec
  kad.handler = proc(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    defer:
      await conn.close()
    while not conn.atEof:
      let buf =
        try:
          await conn.readLp(MaxMsgSize)
        except LPStreamEOFError:
          return
        except LPStreamError as exc:
          debug "Read error when handling kademlia RPC", conn = conn, err = exc.msg
          return
      let msg = Message.decode(buf).valueOr:
        debug "Failed to decode message", err = error
        return

      case msg.msgType
      of MessageType.findNode:
        await kad.handleFindNode(conn, msg)
      of MessageType.putValue:
        await kad.handlePutValue(conn, msg)
      of MessageType.getValue:
        await kad.handleGetValue(conn, msg)
      of MessageType.addProvider:
        await kad.handleAddProvider(conn, msg)
      of MessageType.ping:
        await kad.handlePing(conn, msg)
      else:
        error "Unhandled kad-dht message type", msg = msg
        return
  return kad

method start*(kad: KadDHT): Future[void] {.async: (raises: [CancelledError]).} =
  if kad.started:
    warn "Starting kad-dht twice"
    return

  kad.maintenanceLoop = kad.maintainBuckets()
  kad.started = true

  info "Kad DHT started"

method stop*(kad: KadDHT): Future[void] {.async: (raises: []).} =
  if not kad.started:
    return

  kad.started = false
  kad.maintenanceLoop.cancelSoon()
  kad.maintenanceLoop = nil
