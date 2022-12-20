# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
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
import ../protocol,
       ../../switch,
       ../../multiaddress,
       ../../multicodec,
       ../../peerid,
       ../../utils/semaphore,
       ../../errors

logScope:
  topics = "libp2p autonat"

const
  AutonatCodec* = "/libp2p/autonat/1.0.0"
  AddressLimit = 8

type
  AutonatError* = object of LPError
  AutonatUnreachableError* = object of LPError

  MsgType* = enum
    Dial = 0
    DialResponse = 1

  ResponseStatus* = enum
    Ok = 0
    DialError = 100
    DialRefused = 101
    BadRequest = 200
    InternalError = 300

  AutonatPeerInfo* = object
    id: Option[PeerId]
    addrs: seq[MultiAddress]

  AutonatDial* = object
    peerInfo: Option[AutonatPeerInfo]

  AutonatDialResponse* = object
    status*: ResponseStatus
    text*: Option[string]
    ma*: Option[MultiAddress]

  AutonatMsg = object
    msgType: MsgType
    dial: Option[AutonatDial]
    response: Option[AutonatDialResponse]

proc encode*(msg: AutonatMsg): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, msg.msgType.uint)
  if msg.dial.isSome():
    var dial = initProtoBuffer()
    if msg.dial.get().peerInfo.isSome():
      var bufferPeerInfo = initProtoBuffer()
      let peerInfo = msg.dial.get().peerInfo.get()
      if peerInfo.id.isSome():
        bufferPeerInfo.write(1, peerInfo.id.get())
      for ma in peerInfo.addrs:
        bufferPeerInfo.write(2, ma.data.buffer)
      bufferPeerInfo.finish()
      dial.write(1, bufferPeerInfo.buffer)
    dial.finish()
    result.write(2, dial.buffer)
  if msg.response.isSome():
    var bufferResponse = initProtoBuffer()
    let response = msg.response.get()
    bufferResponse.write(1, response.status.uint)
    if response.text.isSome():
      bufferResponse.write(2, response.text.get())
    if response.ma.isSome():
      bufferResponse.write(3, response.ma.get())
    bufferResponse.finish()
    result.write(3, bufferResponse.buffer)
  result.finish()

proc encode*(d: AutonatDial): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, MsgType.Dial.uint)
  var dial = initProtoBuffer()
  if d.peerInfo.isSome():
    var bufferPeerInfo = initProtoBuffer()
    let peerInfo = d.peerInfo.get()
    if peerInfo.id.isSome():
      bufferPeerInfo.write(1, peerInfo.id.get())
    for ma in peerInfo.addrs:
      bufferPeerInfo.write(2, ma.data.buffer)
    bufferPeerInfo.finish()
    dial.write(1, bufferPeerInfo.buffer)
  dial.finish()
  result.write(2, dial.buffer)
  result.finish()

proc encode*(r: AutonatDialResponse): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, MsgType.DialResponse.uint)
  var bufferResponse = initProtoBuffer()
  bufferResponse.write(1, r.status.uint)
  if r.text.isSome():
    bufferResponse.write(2, r.text.get())
  if r.ma.isSome():
    bufferResponse.write(3, r.ma.get())
  bufferResponse.finish()
  result.write(3, bufferResponse.buffer)
  result.finish()

proc decode(_: typedesc[AutonatMsg], buf: seq[byte]): Option[AutonatMsg] =
  var
    msgTypeOrd: uint32
    pbDial: ProtoBuffer
    pbResponse: ProtoBuffer
    msg: AutonatMsg

  let
    pb = initProtoBuffer(buf)
    r1 = pb.getField(1, msgTypeOrd)
    r2 = pb.getField(2, pbDial)
    r3 = pb.getField(3, pbResponse)
  if r1.isErr() or r2.isErr() or r3.isErr(): return none(AutonatMsg)

  if r1.get() and not checkedEnumAssign(msg.msgType, msgTypeOrd):
    return none(AutonatMsg)
  if r2.get():
    var
      pbPeerInfo: ProtoBuffer
      dial: AutonatDial
    let
      r4 = pbDial.getField(1, pbPeerInfo)
    if r4.isErr(): return none(AutonatMsg)

    var peerInfo: AutonatPeerInfo
    if r4.get():
      var pid: PeerId
      let
        r5 = pbPeerInfo.getField(1, pid)
        r6 = pbPeerInfo.getRepeatedField(2, peerInfo.addrs)
      if r5.isErr() or r6.isErr(): return none(AutonatMsg)
      if r5.get(): peerInfo.id = some(pid)
      dial.peerInfo = some(peerInfo)
    msg.dial = some(dial)

  if r3.get():
    var
      statusOrd: uint
      text: string
      ma: MultiAddress
      response: AutonatDialResponse

    let
      r4 = pbResponse.getField(1, statusOrd)
      r5 = pbResponse.getField(2, text)
      r6 = pbResponse.getField(3, ma)

    if r4.isErr() or r5.isErr() or r6.isErr() or
       (r4.get() and not checkedEnumAssign(response.status, statusOrd)):
      return none(AutonatMsg)
    if r5.get(): response.text = some(text)
    if r6.get(): response.ma = some(ma)
    msg.response = some(response)

  return some(msg)

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

type
  Autonat* = ref object of LPProtocol
    sem: AsyncSemaphore
    switch*: Switch

method dialMe*(a: Autonat, pid: PeerId, addrs: seq[MultiAddress] = newSeq[MultiAddress]()):
    Future[MultiAddress] {.base, async.} =

  proc getResponseOrRaise(autonatMsg: Option[AutonatMsg]): AutonatDialResponse {.raises: [UnpackError, AutonatError].} =
    if autonatMsg.isNone() or
       autonatMsg.get().msgType != DialResponse or
       autonatMsg.get().response.isNone() or
       autonatMsg.get().response.get().ma.isNone():
      raise newException(AutonatError, "Unexpected response")
    else:
      autonatMsg.get().response.get()

  let conn =
    try:
      if addrs.len == 0:
        await a.switch.dial(pid, @[AutonatCodec])
      else:
        await a.switch.dial(pid, addrs, AutonatCodec)
    except CatchableError as err:
      raise newException(AutonatError, "Unexpected error when dialling", err)

  defer: await conn.close()
  await conn.sendDial(a.switch.peerInfo.peerId, a.switch.peerInfo.addrs)
  let response = getResponseOrRaise(AutonatMsg.decode(await conn.readLp(1024)))
  return case response.status:
    of ResponseStatus.Ok:
      response.ma.get()
    of ResponseStatus.DialError:
      raise newException(AutonatUnreachableError, "Peer could not dial us back")
    else:
      raise newException(AutonatError, "Bad status " & $response.status & " " & response.text.get(""))

proc tryDial(a: Autonat, conn: Connection, addrs: seq[MultiAddress]) {.async.} =
  try:
    await a.sem.acquire()
    let ma = await a.switch.dialer.tryDial(conn.peerId, addrs)
    if ma.isSome:
      await conn.sendResponseOk(ma.get())
    else:
      await conn.sendResponseError(DialError, "Missing observed address")
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    await conn.sendResponseError(DialError, exc.msg)
  finally:
    a.sem.release()

proc handleDial(a: Autonat, conn: Connection, msg: AutonatMsg): Future[void] =
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
  return a.tryDial(conn, toSeq(addrs))

proc new*(T: typedesc[Autonat], switch: Switch, semSize: int = 1): T =
  let autonat = T(switch: switch, sem: newAsyncSemaphore(semSize))
  autonat.init()
  autonat

method init*(a: Autonat) =
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msgOpt = AutonatMsg.decode(await conn.readLp(1024))
      if msgOpt.isNone() or msgOpt.get().msgType != MsgType.Dial:
        raise newException(AutonatError, "Received malformed message")
      let msg = msgOpt.get()
      await a.handleDial(conn, msg)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in autonat handler", exc = exc.msg, conn
    finally:
      trace "exiting autonat handler", conn
      await conn.close()

  a.handler = handleStream
  a.codec = AutonatCodec
