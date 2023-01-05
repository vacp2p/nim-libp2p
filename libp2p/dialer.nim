# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
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
       multicodec,
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
declareCounter(libp2p_failed_upgrades_outgoing, "outgoing connections failed upgrades")

type
  DialFailedError* = object of LPError

  Dialer* = ref object of Dial
    localPeerId*: PeerId
    ms: MultistreamSelect
    connManager: ConnManager
    dialLock: Table[PeerId, AsyncLock]
    transports: seq[Transport]
    nameResolver: NameResolver

proc dialAndUpgrade(
  self: Dialer,
  peerId: Opt[PeerId],
  hostname: string,
  address: MultiAddress):
  Future[Connection] {.async.} =

  for transport in self.transports: # for each transport
    if transport.handles(address):   # check if it can dial it
      trace "Dialing address", address, peerId, hostname
      let dialed =
        try:
          libp2p_total_dial_attempts.inc()
          await transport.dial(hostname, address)
        except CancelledError as exc:
          debug "Dialing canceled", msg = exc.msg, peerId
          raise exc
        except CatchableError as exc:
          debug "Dialing failed", msg = exc.msg, peerId
          libp2p_failed_dials.inc()
          return nil # Try the next address

      # also keep track of the connection's bottom unsafe transport direction
      # required by gossipsub scoring
      dialed.transportDir = Direction.Out

      libp2p_successful_dials.inc()

      let conn =
        try:
          await transport.upgradeOutgoing(dialed, peerId)
        except CatchableError as exc:
          # If we failed to establish the connection through one transport,
          # we won't succeeded through another - no use in trying again
          await dialed.close()
          debug "Upgrade failed", msg = exc.msg, peerId
          if exc isnot CancelledError:
            libp2p_failed_upgrades_outgoing.inc()

          # Try other address
          return nil

      doAssert not isNil(conn), "connection died after upgradeOutgoing"
      debug "Dial successful", conn, peerId = conn.peerId
      return conn
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
  addrs: seq[MultiAddress]):
  Future[Connection] {.async.} =

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
        result = await self.dialAndUpgrade(addrPeerId, hostname, resolvedAddress)
        if not isNil(result):
          return result

proc internalConnect(
  self: Dialer,
  peerId: Opt[PeerId],
  addrs: seq[MultiAddress],
  forceDial: bool):
  Future[Connection] {.async.} =
  if Opt.some(self.localPeerId) == peerId:
    raise newException(CatchableError, "can't dial self!")

  # Ensure there's only one in-flight attempt per peer
  let lock = self.dialLock.mgetOrPut(peerId.get(default(PeerId)), newAsyncLock())
  try:
    await lock.acquire()

    # Check if we have a connection already and try to reuse it
    var conn =
      if peerId.isSome: self.connManager.selectConn(peerId.get())
      else: nil
    if conn != nil:
      if conn.atEof or conn.closed:
        # This connection should already have been removed from the connection
        # manager - it's essentially a bug that we end up here - we'll fail
        # for now, hoping that this will clean themselves up later...
        warn "dead connection in connection manager", conn
        await conn.close()
        raise newException(DialFailedError, "Zombie connection encountered")

      trace "Reusing existing connection", conn, direction = $conn.dir
      return conn

    let slot = self.connManager.getOutgoingSlot(forceDial)
    conn =
      try:
        await self.dialAndUpgrade(peerId, addrs)
      except CatchableError as exc:
        slot.release()
        raise exc
    slot.trackConnection(conn)
    if isNil(conn): # None of the addresses connected
      raise newException(DialFailedError, "Unable to establish outgoing link")

    # A disconnect could have happened right after
    # we've added the connection so we check again
    # to prevent races due to that.
    if conn.closed() or conn.atEof():
      # This can happen when the other ends drops us
      # before we get a chance to return the connection
      # back to the dialer.
      trace "Connection dead on arrival", conn
      raise newLPStreamClosedError()

    return conn
  finally:
    if lock.locked():
      lock.release()

method connect*(
  self: Dialer,
  peerId: PeerId,
  addrs: seq[MultiAddress],
  forceDial = false) {.async.} =
  ## connect remote peer without negotiating
  ## a protocol
  ##

  if self.connManager.connCount(peerId) > 0:
    return

  discard await self.internalConnect(Opt.some(peerId), addrs, forceDial)

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
      false)).peerId
  else:
    if allowUnknownPeerId == false:
      raise newException(DialFailedError, "Address without PeerID and unknown peer id disabled!")
    return (await self.internalConnect(
      Opt.none(PeerId),
      @[address],
      false)).peerId

proc negotiateStream(
  self: Dialer,
  conn: Connection,
  protos: seq[string]): Future[Connection] {.async.} =
  trace "Negotiating stream", conn, protos
  let selected = await self.ms.select(conn, protos)
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
    let conn = await self.dialAndUpgrade(Opt.some(peerId), addrs)
    if conn.isNil():
      raise newException(DialFailedError, "No valid multiaddress")
    await conn.close()
    return conn.observedAddr
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
    conn: Connection
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
  transports: seq[Transport],
  ms: MultistreamSelect,
  nameResolver: NameResolver = nil): Dialer =

  T(localPeerId: localPeerId,
    connManager: connManager,
    transports: transports,
    ms: ms,
    nameResolver: nameResolver)
