# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options, sets, sequtils]
import stew/results
import chronos, chronicles, stew/objects
import ../../protocol,
       ../../../switch,
       ../../../multiaddress,
       ../../../multicodec,
       ../../../peerid,
       ../../../utils/semaphore,
       ../../../errors
import core

export core

logScope:
  topics = "libp2p autonat"

type
  Autonat* = ref object of LPProtocol
    sem: AsyncSemaphore
    switch*: Switch
    dialTimeout: Duration

proc sendDial(conn: Connection, pid: PeerId, addrs: seq[MultiAddress]) {.async.} =
  let pb = AutonatDial(peerInfo: some(AutonatPeerInfo(
                         id: some(pid),
                         addrs: addrs
                       ))).encode()
  await conn.writeLp(pb.buffer)

proc sendResponseError(conn: Connection, status: ResponseStatus, text: string = "") {.async.} =
  let pb = AutonatDialResponse(
             status: status,
             text: if text == "": none(string) else: some(text),
             ma: none(MultiAddress)
           ).encode()
  await conn.writeLp(pb.buffer)

proc sendResponseOk(conn: Connection, ma: MultiAddress) {.async.} =
  let pb = AutonatDialResponse(
             status: ResponseStatus.Ok,
             text: some("Ok"),
             ma: some(ma)
           ).encode()
  await conn.writeLp(pb.buffer)

proc tryDial(autonat: Autonat, conn: Connection, addrs: seq[MultiAddress]) {.async.} =
  await autonat.sem.acquire()
  try:
    let outgoingConnection = autonat.switch.connManager.expectConnection(conn.peerId)
    defer: outgoingConnection.cancel()
    let ma = await autonat.switch.dialer.tryDial(conn.peerId, addrs).wait(autonat.dialTimeout)
    if ma.isSome:
      await conn.sendResponseOk(ma.get())
    else:
      await conn.sendResponseError(DialError, "Missing observed address")
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    await conn.sendResponseError(DialError, exc.msg)
  finally:
    autonat.sem.release()

proc handleDial(autonat: Autonat, conn: Connection, msg: AutonatMsg): Future[void] =
  if msg.dial.isNone() or msg.dial.get().peerInfo.isNone():
    return conn.sendResponseError(BadRequest, "Missing Peer Info")
  let peerInfo = msg.dial.get().peerInfo.get()
  if peerInfo.id.isSome() and peerInfo.id.get() != conn.peerId:
    return conn.sendResponseError(BadRequest, "PeerId mismatch")

  if conn.observedAddr.isNone:
    return conn.sendResponseError(BadRequest, "Missing observed address")
  let observedAddr = conn.observedAddr.get()

  var isRelayed = observedAddr.contains(multiCodec("p2p-circuit"))
  if isRelayed.isErr() or isRelayed.get():
    return conn.sendResponseError(DialRefused, "Refused to dial a relayed observed address")
  let hostIp = observedAddr[0]
  if hostIp.isErr() or not IP.match(hostIp.get()):
    trace "wrong observed address", address=observedAddr
    return conn.sendResponseError(InternalError, "Expected an IP address")
  var addrs = initHashSet[MultiAddress]()
  addrs.incl(observedAddr)
  for ma in peerInfo.addrs:
    isRelayed = ma.contains(multiCodec("p2p-circuit"))
    if isRelayed.isErr() or isRelayed.get():
      continue
    let maFirst = ma[0]
    if maFirst.isErr() or not IP.match(maFirst.get()):
      continue

    try:
      addrs.incl(
        if maFirst.get() == hostIp.get():
          ma
        else:
          let maEnd = ma[1..^1]
          if maEnd.isErr(): continue
          hostIp.get() & maEnd.get()
      )
    except LPError as exc:
      continue
    if len(addrs) >= AddressLimit:
      break

  if len(addrs) == 0:
    return conn.sendResponseError(DialRefused, "No dialable address")
  return autonat.tryDial(conn, toSeq(addrs))

proc new*(T: typedesc[Autonat], switch: Switch, semSize: int = 1, dialTimeout = 15.seconds): T =
  let autonat = T(switch: switch, sem: newAsyncSemaphore(semSize), dialTimeout: dialTimeout)
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msgOpt = AutonatMsg.decode(await conn.readLp(1024))
      if msgOpt.isNone() or msgOpt.get().msgType != MsgType.Dial:
        raise newException(AutonatError, "Received malformed message")
      let msg = msgOpt.get()
      await autonat.handleDial(conn, msg)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in autonat handler", exc = exc.msg, conn
    finally:
      trace "exiting autonat handler", conn
      await conn.close()

  autonat.handler = handleStream
  autonat.codec = AutonatCodec
  autonat
