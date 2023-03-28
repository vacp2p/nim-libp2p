# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[sugar, tables, sequtils]

import stew/results
import pkg/[chronos,
            chronicles,
            metrics]

import dial,
       peerid,
       peerinfo,
       peerstore,
       multicodec,
       muxers/muxer,
       multistream,
       connmanager,
       stream/connection,
       transports/transport,
       nameresolving/nameresolver,
       upgrademngrs/upgrade,
       errors

export dial, errors, results

logScope:
  topics = "libp2p dialer"

declareCounter(libp2p_total_dial_attempts, "total attempted dials")
declareCounter(libp2p_successful_dials, "dialed successful peers")
declareCounter(libp2p_failed_dials, "failed dials")

type
  DialFailedError* = object of LPError

  Dialer* = ref object of Dial
    localPeerId*: PeerId
    connManager: ConnManager
    dialLock: Table[PeerId, AsyncLock]
    transports: seq[Transport]
    peerStore: PeerStore
    nameResolver: NameResolver

proc dialAndUpgrade(
  self: Dialer,
  peerId: Opt[PeerId],
  hostname: string,
  address: MultiAddress,
  isSimultaneousConnServer = false):
  Future[Muxer] {.async.} =

  for transport in self.transports: # for each transport
    if transport.handles(address):   # check if it can dial it
      trace "Dialing address", address, peerId, hostname
      let dialed =
        try:
          libp2p_total_dial_attempts.inc()
          await transport.dial(hostname, address, peerId)
        except CancelledError as exc:
          debug "Dialing canceled", msg = exc.msg, peerId
          raise exc
        except CatchableError as exc:
          debug "Dialing failed", msg = exc.msg, peerId
          libp2p_failed_dials.inc()
          return nil # Try the next address

      libp2p_successful_dials.inc()

      let mux =
        try:
          if isSimultaneousConnServer:
            dialed.transportDir = Direction.In
            let upgradedConn = await transport.upgradeIncoming(dialed)
            doAssert not isNil(upgradedConn), "connection died after upgradeIncoming"
            upgradedConn
          else:
            # also keep track of the connection's bottom unsafe transport direction
            # required by gossipsub scoring
            dialed.transportDir = Direction.Out
            # This is related to the simultaneous connection through DCUtr. According to the spec, the server side of
            # the DCUtr protocol should be the client of the simultaneous connection.
            let upgradedConn = await transport.upgradeOutgoing(dialed, peerId)
            doAssert not isNil(upgradedConn), "connection died after upgradeOutgoing"
            upgradedConn

        except CatchableError as exc:
          # If we failed to establish the connection through one transport,
          # we won't succeeded through another - no use in trying again
          await dialed.close()
          debug "Upgrade failed", msg = exc.msg, peerId
          if exc isnot CancelledError:
            if isSimultaneousConnServer:
              libp2p_failed_upgrades_outgoing.inc()
            else:
              libp2p_failed_upgrades_incoming.inc()

          # Try other address
          return nil

      doAssert not isNil(mux), "connection died after upgradeOutgoing"
      debug "Dial successful", peerId = mux.connection.peerId
      return mux
  return nil

proc expandDnsAddr(
  self: Dialer,
  peerId: Opt[PeerId],
  address: MultiAddress): Future[seq[(MultiAddress, Opt[PeerId])]] {.async.} =

  if not DNSADDR.matchPartial(address): return @[(address, peerId)]
  if isNil(self.nameResolver):
    info "Can't resolve DNSADDR without NameResolver", ma=address
    return @[]

  let
    toResolve =
      if peerId.isSome:
        address & MultiAddress.init(multiCodec("p2p"), peerId.tryGet()).tryGet()
      else:
        address
    resolved = await self.nameResolver.resolveDnsAddr(toResolve)

  for resolvedAddress in resolved:
    let lastPart = resolvedAddress[^1].tryGet()
    if lastPart.protoCode == Result[MultiCodec, string].ok(multiCodec("p2p")):
      let
        peerIdBytes = lastPart.protoArgument().tryGet()
        addrPeerId = PeerId.init(peerIdBytes).tryGet()
      result.add((resolvedAddress[0..^2].tryGet(), Opt.some(addrPeerId)))
    else:
      result.add((resolvedAddress, peerId))

proc dialAndUpgrade(
  self: Dialer,
  peerId: Opt[PeerId],
  addrs: seq[MultiAddress],
  isSimultaneousConnServer = false):
  Future[Muxer] {.async.} =

  debug "Dialing peer", peerId

  for rawAddress in addrs:
    # resolve potential dnsaddr
    let addresses = await self.expandDnsAddr(peerId, rawAddress)

    for (expandedAddress, addrPeerId) in addresses:
      # DNS resolution
      let
        hostname = expandedAddress.getHostname()
        resolvedAddresses =
          if isNil(self.nameResolver): @[expandedAddress]
          else: await self.nameResolver.resolveMAddress(expandedAddress)

      for resolvedAddress in resolvedAddresses:
        result = await self.dialAndUpgrade(addrPeerId, hostname, resolvedAddress, isSimultaneousConnServer)
        if not isNil(result):
          return result

proc tryReusingConnection(self: Dialer, peerId: PeerId): Future[Opt[Muxer]] {.async.} =
  let muxer = self.connManager.selectMuxer(peerId)
  if muxer == nil:
    return Opt.none(Muxer)

  trace "Reusing existing connection", muxer, direction = $muxer.connection.dir
  return Opt.some(muxer)

proc internalConnect(
  self: Dialer,
  peerId: Opt[PeerId],
  addrs: seq[MultiAddress],
  forceDial: bool,
  reuseConnection = true,
  isSimultaneousConnServer = false):
  Future[Muxer] {.async.} =
  if Opt.some(self.localPeerId) == peerId:
    raise newException(CatchableError, "can't dial self!")

  # Ensure there's only one in-flight attempt per peer
  let lock = self.dialLock.mgetOrPut(peerId.get(default(PeerId)), newAsyncLock())
  try:
    await lock.acquire()

    if peerId.isSome and reuseConnection:
      let muxOpt = await self.tryReusingConnection(peerId.get())
      if muxOpt.isSome:
        return muxOpt.get()

    let slot = self.connManager.getOutgoingSlot(forceDial)
    let muxed =
      try:
        await self.dialAndUpgrade(peerId, addrs, isSimultaneousConnServer)
      except CatchableError as exc:
        slot.release()
        raise exc
    slot.trackMuxer(muxed)
    if isNil(muxed): # None of the addresses connected
      raise newException(DialFailedError, "Unable to establish outgoing link")

    try:
      self.connManager.storeMuxer(muxed)
      await self.peerStore.identify(muxed)
    except CatchableError as exc:
      trace "Failed to finish outgoung upgrade", err=exc.msg
      await muxed.close()
      raise exc

    return muxed
  finally:
    if lock.locked():
      lock.release()

method connect*(
  self: Dialer,
  peerId: PeerId,
  addrs: seq[MultiAddress],
  forceDial = false,
  reuseConnection = true,
  isSimultaneousConnServer = false) {.async.} =
  ## connect remote peer without negotiating
  ## a protocol
  ##

  if self.connManager.connCount(peerId) > 0 and reuseConnection:
    return

  discard await self.internalConnect(Opt.some(peerId), addrs, forceDial, reuseConnection, isSimultaneousConnServer)

method connect*(
  self: Dialer,
  address: MultiAddress,
  allowUnknownPeerId = false): Future[PeerId] {.async.} =
  ## Connects to a peer and retrieve its PeerId

  let fullAddress = parseFullAddress(address)
  if fullAddress.isOk:
    return (await self.internalConnect(
      Opt.some(fullAddress.get()[0]),
      @[fullAddress.get()[1]],
      false)).connection.peerId
  else:
    if allowUnknownPeerId == false:
      raise newException(DialFailedError, "Address without PeerID and unknown peer id disabled!")
    return (await self.internalConnect(
      Opt.none(PeerId),
      @[address],
      false)).connection.peerId

proc negotiateStream(
  self: Dialer,
  conn: Connection,
  protos: seq[string]): Future[Connection] {.async.} =
  trace "Negotiating stream", conn, protos
  let selected = await MultistreamSelect.select(conn, protos)
  if not protos.contains(selected):
    await conn.closeWithEOF()
    raise newException(DialFailedError, "Unable to select sub-protocol " & $protos)

  return conn

method tryDial*(
  self: Dialer,
  peerId: PeerId,
  addrs: seq[MultiAddress]): Future[Opt[MultiAddress]] {.async.} =
  ## Create a protocol stream in order to check
  ## if a connection is possible.
  ## Doesn't use the Connection Manager to save it.
  ##

  trace "Check if it can dial", peerId, addrs
  try:
    let mux = await self.dialAndUpgrade(Opt.some(peerId), addrs)
    if mux.isNil():
      raise newException(DialFailedError, "No valid multiaddress")
    await mux.close()
    return mux.connection.observedAddr
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    raise newException(DialFailedError, exc.msg)

method dial*(
  self: Dialer,
  peerId: PeerId,
  protos: seq[string]): Future[Connection] {.async.} =
  ## create a protocol stream over an
  ## existing connection
  ##

  trace "Dialing (existing)", peerId, protos
  let stream = await self.connManager.getStream(peerId)
  if stream.isNil:
    raise newException(DialFailedError, "Couldn't get muxed stream")

  return await self.negotiateStream(stream, protos)

method dial*(
  self: Dialer,
  peerId: PeerId,
  addrs: seq[MultiAddress],
  protos: seq[string],
  forceDial = false): Future[Connection] {.async.} =
  ## create a protocol stream and establish
  ## a connection if one doesn't exist already
  ##

  var
    conn: Muxer
    stream: Connection

  proc cleanup() {.async.} =
    if not(isNil(stream)):
      await stream.closeWithEOF()

    if not(isNil(conn)):
      await conn.close()

  try:
    trace "Dialing (new)", peerId, protos
    conn = await self.internalConnect(Opt.some(peerId), addrs, forceDial)
    trace "Opening stream", conn
    stream = await self.connManager.getStream(conn)

    if isNil(stream):
      raise newException(DialFailedError,
        "Couldn't get muxed stream")

    return await self.negotiateStream(stream, protos)
  except CancelledError as exc:
    trace "Dial canceled", conn
    await cleanup()
    raise exc
  except CatchableError as exc:
    debug "Error dialing", conn, msg = exc.msg
    await cleanup()
    raise exc

method addTransport*(self: Dialer, t: Transport) =
  self.transports &= t

proc new*(
  T: type Dialer,
  localPeerId: PeerId,
  connManager: ConnManager,
  peerStore: PeerStore,
  transports: seq[Transport],
  nameResolver: NameResolver = nil): Dialer =

  T(localPeerId: localPeerId,
    connManager: connManager,
    transports: transports,
    peerStore: peerStore,
    nameResolver: nameResolver)
