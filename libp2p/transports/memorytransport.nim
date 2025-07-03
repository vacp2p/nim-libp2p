# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Memory transport implementation

import std/sequtils
import pkg/chronos
import pkg/chronicles
import ./transport
import ../multiaddress
import ../stream/connection
import ../crypto/crypto
import ../upgrademngrs/upgrade
import ./memorymanager

export connection
export MemoryTransportError, MemoryTransportAcceptStopped

const MemoryAutoAddress* = "/memory/*"

logScope:
  topics = "libp2p memorytransport"

type MemoryTransport* = ref object of Transport
  rng: ref HmacDrbgContext
  connections: seq[Connection]
  listener: Opt[MemoryListener]

proc new*(
    T: typedesc[MemoryTransport],
    upgrade: Upgrade = Upgrade(),
    rng: ref HmacDrbgContext = newRng(),
): T =
  T(upgrader: upgrade, rng: rng)

proc listenAddress(self: MemoryTransport, ma: MultiAddress): MultiAddress =
  if $ma != MemoryAutoAddress:
    return ma

  # when special address is used `/memory/*` use any free address. 
  # here we assume that any random generated address will be free.
  var randomBuf: array[10, byte]
  hmacDrbgGenerate(self.rng[], randomBuf)

  return MultiAddress.init("/memory/" & toHex(randomBuf)).get()

method start*(
    self: MemoryTransport, addrs: seq[MultiAddress]
) {.async: (raises: [LPError, transport.TransportError, CancelledError]).} =
  if self.running:
    return

  trace "starting memory transport on addrs", address = $addrs

  self.addrs = addrs.mapIt(self.listenAddress(it))
  self.running = true

method stop*(self: MemoryTransport) {.async: (raises: []).} =
  if not self.running:
    return

  trace "stopping memory transport", address = $self.addrs
  self.running = false

  # closing listener will throw interruption error to caller of accept()
  let listener = self.listener
  if listener.isSome:
    listener.get().close()

  # end all connections
  await noCancel allFutures(self.connections.mapIt(it.close()))

method accept*(
    self: MemoryTransport
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  if not self.running:
    raise newException(MemoryTransportError, "Transport closed, no more connections!")

  var listener: MemoryListener
  try:
    listener = getInstance().accept($self.addrs[0])
    self.listener = Opt.some(listener)
    let conn = await listener.accept()
    self.connections.add(conn)
    self.listener = Opt.none(MemoryListener)
    return conn
  except CancelledError as e:
    listener.close()
    raise e
  except MemoryTransportError as e:
    raise e
  except CatchableError:
    raiseAssert "should never happen"

method dial*(
    self: MemoryTransport,
    hostname: string,
    ma: MultiAddress,
    peerId: Opt[PeerId] = Opt.none(PeerId),
): Future[Connection] {.async: (raises: [transport.TransportError, CancelledError]).} =
  try:
    let listener = getInstance().dial($ma)
    let conn = await listener.dial()
    self.connections.add(conn)
    return conn
  except CancelledError as e:
    raise e
  except MemoryTransportError as e:
    raise e
  except CatchableError:
    raiseAssert "should never happen"

proc dial*(
    self: MemoryTransport, ma: MultiAddress, peerId: Opt[PeerId] = Opt.none(PeerId)
): Future[Connection] {.gcsafe.} =
  self.dial("", ma)

method handles*(self: MemoryTransport, ma: MultiAddress): bool {.gcsafe, raises: [].} =
  if procCall Transport(self).handles(ma):
    if ma.protocols.isOk:
      return Memory.match(ma)
