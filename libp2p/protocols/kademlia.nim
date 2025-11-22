# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, chronicles, results
import ../utils/heartbeat
import ../[peerid, switch, multihash]
import ./protocol
import ./kademlia/[routingtable, protobuf, types, find, get, put, provider, ping]

export routingtable, protobuf, types, find, get, put, provider, ping

logScope:
  topics = "kad-dht"

proc bootstrapNode(
    kad: KadDHT, peerId: PeerId, addrs: seq[MultiAddress]
) {.async: (raises: [CancelledError]).} =
  try:
    await kad.switch.connect(peerId, addrs)
    debug "Connected to bootstrap peer", peerId = peerId
  except DialFailedError as exc:
    # at some point will want to bubble up a Result[void, SomeErrorEnum]
    error "failed to dial to bootstrap peer", peerId = peerId, error = exc.msg
    return

  let msg =
    try:
      await kad.sendFindNode(peerId, addrs, kad.rtable.selfId).wait(kad.config.timeout)
    except CatchableError as exc:
      debug "Send find node exception during bootstrap",
        target = peerId, addrs = addrs, err = exc.msg
      return

  for peer in msg.closerPeers:
    let p = PeerId.init(peer.id).valueOr:
      debug "Invalid peer id received", error = error
      return
    discard kad.rtable.insert(p)

    kad.switch.peerStore[AddressBook][p] = peer.addrs

  # bootstrap node replied succesfully, add to routing table
  discard kad.rtable.insert(peerId)

proc bootstrap*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  for (peerId, addrs) in kad.bootstrapNodes:
    await kad.bootstrapNode(peerId, addrs)

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
  heartbeat "refresh buckets", kad.config.bucketRefreshTime:
    await kad.refreshBuckets()

proc new*(
    T: typedesc[KadDHT],
    switch: Switch,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    config: KadDHTConfig = KadDHTConfig.new(),
    rng: ref HmacDrbgContext = newRng(),
    client: bool = false,
): T {.raises: [].} =
  var rtable = RoutingTable.new(
    switch.peerInfo.peerId.toKey(),
    config = RoutingTableConfig.new(replication = config.replication),
  )
  let kad = T(
    rng: rng,
    switch: switch,
    bootstrapNodes: bootstrapNodes,
    rtable: rtable,
    config: config,
    providerManager:
      ProviderManager.new(config.providerRecordCapacity, config.providedKeyCapacity),
  )

  kad.codec = KadCodec
  if not client:
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
        of MessageType.getProviders:
          await kad.handleGetProviders(conn, msg)
        of MessageType.ping:
          await kad.handlePing(conn, msg)
        else:
          error "Unhandled kad-dht message type", msg = msg
          return
  return kad

method start*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  if kad.started:
    warn "Starting kad-dht twice"
    return

  kad.maintenanceLoop = kad.maintainBuckets()
  kad.republishLoop = kad.manageRepublishProvidedKeys()
  kad.expiredLoop = kad.manageExpiredProviders()

  await kad.bootstrap()

  kad.started = true

  info "Kad DHT started"

method stop*(kad: KadDHT) {.async: (raises: []).} =
  if not kad.started:
    return

  kad.started = false

  kad.maintenanceLoop.cancelSoon()
  kad.maintenanceLoop = nil

  kad.republishLoop.cancelSoon()
  kad.republishLoop = nil

  kad.expiredLoop.cancelSoon()
  kad.expiredLoop = nil
