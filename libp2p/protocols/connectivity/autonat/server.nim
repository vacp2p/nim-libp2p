# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[sets, sequtils]
import results
import chronos, chronicles
import
  ../../protocol,
  ../../../switch,
  ../../../multiaddress,
  ../../../multicodec,
  ../../../peerid,
  ../../../utils/[semaphore, future],
  ../../../errors
import core

export core

logScope:
  topics = "libp2p autonat"

type Autonat* = ref object of LPProtocol
  sem: AsyncSemaphore
  switch*: Switch
  dialTimeout: Duration

proc sendDial(
    conn: Connection, pid: PeerId, addrs: seq[MultiAddress]
) {.async: (raises: [LPStreamError, CancelledError]).} =
  let pb = AutonatDial(
    peerInfo: Opt.some(AutonatPeerInfo(id: Opt.some(pid), addrs: addrs))
  ).encode()
  await conn.writeLp(pb.buffer)

proc sendResponseError(
    conn: Connection, status: ResponseStatus, text: string = ""
) {.async: (raises: [CancelledError]).} =
  let pb = AutonatDialResponse(
    status: status,
    text:
      if text == "":
        Opt.none(string)
      else:
        Opt.some(text),
    ma: Opt.none(MultiAddress),
  ).encode()
  try:
    await conn.writeLp(pb.buffer)
  except LPStreamError as exc:
    trace "autonat failed to send response error", description = exc.msg, conn

proc sendResponseOk(
    conn: Connection, ma: MultiAddress
) {.async: (raises: [CancelledError]).} =
  let pb = AutonatDialResponse(
    status: ResponseStatus.Ok, text: Opt.some("Ok"), ma: Opt.some(ma)
  ).encode()
  try:
    await conn.writeLp(pb.buffer)
  except LPStreamError as exc:
    trace "autonat failed to send response ok", description = exc.msg, conn

proc tryDial(
    autonat: Autonat, conn: Connection, addrs: seq[MultiAddress]
) {.async: (raises: [DialFailedError, CancelledError]).} =
  await autonat.sem.acquire()
  var futs: seq[Future[Opt[MultiAddress]].Raising([DialFailedError, CancelledError])]
  try:
    # This is to bypass the per peer max connections limit
    let outgoingConnection =
      autonat.switch.connManager.expectConnection(conn.peerId, Out)
    if outgoingConnection.failed() and
        outgoingConnection.error of AlreadyExpectingConnectionError:
      await conn.sendResponseError(DialRefused, outgoingConnection.error.msg)
      return
    # Safer to always try to cancel cause we aren't sure if the connection was established
    defer:
      outgoingConnection.cancelSoon()

    # tryDial is to bypass the global max connections limit
    futs = addrs.mapIt(autonat.switch.dialer.tryDial(conn.peerId, @[it]))
    let fut = await anyCompleted(futs).wait(autonat.dialTimeout)
    let ma = await fut
    ma.withValue(maddr):
      await conn.sendResponseOk(maddr)
    else:
      await conn.sendResponseError(DialError, "Missing observed address")
  except CancelledError as exc:
    raise newException(CancelledError, "cancelled in tryDial: " & exc.msg, exc)
  except AllFuturesFailedError as exc:
    debug "All dial attempts failed", addrs, description = exc.msg
    await conn.sendResponseError(DialError, "All dial attempts failed")
  except AsyncTimeoutError as exc:
    debug "Dial timeout", addrs, description = exc.msg
    await conn.sendResponseError(DialError, "Dial timeout: " & exc.msg)
  finally:
    autonat.sem.release()
    for f in futs:
      if not f.finished():
        f.cancel()

proc handleDial(autonat: Autonat, conn: Connection, msg: AutonatMsg): Future[void] =
  let dial = msg.dial.valueOr:
    return conn.sendResponseError(BadRequest, "Missing Dial")
  let peerInfo = dial.peerInfo.valueOr:
    return conn.sendResponseError(BadRequest, "Missing Peer Info")
  peerInfo.id.withValue(id):
    if id != conn.peerId:
      return conn.sendResponseError(BadRequest, "PeerId mismatch")

  let observedAddr = conn.observedAddr.valueOr:
    return conn.sendResponseError(BadRequest, "Missing observed address")

  var isRelayed = observedAddr.contains(multiCodec("p2p-circuit")).valueOr:
    return conn.sendResponseError(DialRefused, "Invalid observed address")
  if isRelayed:
    return
      conn.sendResponseError(DialRefused, "Refused to dial a relayed observed address")
  let hostIp = observedAddr[0].valueOr:
    return conn.sendResponseError(InternalError, "Wrong observed address")
  if not IP.match(hostIp):
    return conn.sendResponseError(InternalError, "Expected an IP address")
  var addrs = initHashSet[MultiAddress]()
  addrs.incl(observedAddr)
  trace "addrs received", addrs = peerInfo.addrs
  for ma in peerInfo.addrs:
    isRelayed = ma.contains(multiCodec("p2p-circuit")).valueOr:
      continue
    let maFirst = ma[0].valueOr:
      continue
    if not DNS_OR_IP.match(maFirst):
      continue

    try:
      addrs.incl(
        if maFirst == hostIp:
          ma
        else:
          let maEnd = ma[1 ..^ 1].valueOr:
            continue
          hostIp & maEnd
      )
    except LPError as exc:
      continue
    if len(addrs) >= AddressLimit:
      break

  if len(addrs) == 0:
    return conn.sendResponseError(DialRefused, "No dialable address")
  let addrsSeq = toSeq(addrs)
  trace "trying to dial", addrs = addrsSeq
  return autonat.tryDial(conn, addrsSeq)

proc new*(
    T: typedesc[Autonat], switch: Switch, semSize: int = 1, dialTimeout = 15.seconds
): T =
  let autonat =
    T(switch: switch, sem: newAsyncSemaphore(semSize), dialTimeout: dialTimeout)
  proc handleStream(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      let msg = AutonatMsg.decode(await conn.readLp(1024)).valueOr:
        raise newException(AutonatError, "Received malformed message")
      if msg.msgType != MsgType.Dial:
        raise newException(AutonatError, "Message type should be dial")
      await autonat.handleDial(conn, msg)
    except CancelledError as exc:
      trace "cancelled autonat handler"
      raise
        newException(CancelledError, "Autonat handler was cancelled: " & exc.msg, exc)
    except CatchableError as exc:
      debug "exception in autonat handler", description = exc.msg, conn
    finally:
      trace "exiting autonat handler", conn
      await conn.close()

  autonat.handler = handleStream
  autonat.codec = AutonatCodec
  autonat
