# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import locks
import tables
import std/sequtils
import stew/byteutils
import pkg/chronos
import pkg/chronicles
import ./transport
import ../multiaddress
import ../stream/connection
import ../stream/bridgestream
import ../muxers/muxer

type
  MemoryTransportError* = object of transport.TransportError
  MemoryTransportAcceptStopped* = object of MemoryTransportError

type MemoryListener* = object
  address: string
  accept: Future[Connection]
  onListenerEnd: proc(address: string) {.closure, gcsafe, raises: [].}

proc init(
    _: type[MemoryListener],
    address: string,
    onListenerEnd: proc(address: string) {.closure, gcsafe, raises: [].},
): MemoryListener =
  return MemoryListener(
    accept: newFuture[Connection]("MemoryListener.accept"),
    address: address,
    onListenerEnd: onListenerEnd,
  )

proc close*(self: MemoryListener) =
  if not (self.accept.finished):
    self.accept.fail(newException(MemoryTransportAcceptStopped, "Listener closed"))
    self.onListenerEnd(self.address)

proc accept*(
    self: MemoryListener
): Future[Connection] {.gcsafe, raises: [CatchableError].} =
  return self.accept

proc dial*(
    self: MemoryListener
): Future[Connection] {.gcsafe, raises: [CatchableError].} =
  let (connA, connB) = bridgedConnections()

  self.onListenerEnd(self.address)
  self.accept.complete(connA)

  let dFut = newFuture[Connection]("MemoryListener.dial")
  dFut.complete(connB)

  return dFut

type memoryConnManager = ref object
  listeners: Table[string, MemoryListener]
  connections: Table[string, Connection]
  lock: Lock

proc init(_: type[memoryConnManager]): memoryConnManager =
  var m = memoryConnManager()
  initLock(m.lock)
  return m

proc onListenerEnd(
    self: memoryConnManager
): proc(address: string) {.closure, gcsafe, raises: [].} =
  proc cb(address: string) {.closure, gcsafe, raises: [].} =
    acquire(self.lock)
    defer:
      release(self.lock)

    try:
      if address in self.listeners:
        self.listeners.del(address)
    except KeyError:
      raiseAssert "checked with if"

  return cb

proc accept*(
    self: memoryConnManager, address: string
): MemoryListener {.raises: [MemoryTransportError].} =
  acquire(self.lock)
  defer:
    release(self.lock)

  if address in self.listeners:
    raise newException(MemoryTransportError, "Memory address already in use")

  let listener = MemoryListener.init(address, self.onListenerEnd())
  self.listeners[address] = listener

  return listener

proc dial*(
    self: memoryConnManager, address: string
): MemoryListener {.raises: [MemoryTransportError].} =
  acquire(self.lock)
  defer:
    release(self.lock)

  if address notin self.listeners:
    raise newException(MemoryTransportError, "No memory listener found")

  try:
    return self.listeners[address]
  except KeyError:
    raiseAssert "checked with if"

let instance: memoryConnManager = memoryConnManager.init()

proc getInstance*(): memoryConnManager {.gcsafe.} =
  {.gcsafe.}:
    instance
