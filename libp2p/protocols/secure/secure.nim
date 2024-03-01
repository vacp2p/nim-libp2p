# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push gcsafe.}
{.push raises: [].}

import std/[strformat]
import stew/results
import chronos, chronicles
import ../protocol,
       ../../stream/streamseq,
       ../../stream/connection,
       ../../multiaddress,
       ../../peerinfo,
       ../../errors

export protocol, results

logScope:
  topics = "libp2p secure"

const
  SecureConnTrackerName* = "SecureConn"

type
  Secure* = ref object of LPProtocol # base type for secure managers

  SecureConn* = ref object of Connection
    stream*: Connection
    buf: StreamSeq

func shortLog*(conn: SecureConn): auto =
  try:
    if conn.isNil: "SecureConn(nil)"
    else: &"{shortLog(conn.peerId)}:{conn.oid}"
  except ValueError as exc:
    raise newException(Defect, exc.msg)

chronicles.formatIt(SecureConn): shortLog(it)

proc new*(T: type SecureConn,
           conn: Connection,
           peerId: PeerId,
           observedAddr: Opt[MultiAddress],
           timeout: Duration = DefaultConnectionTimeout): T =
  result = T(stream: conn,
             peerId: peerId,
             observedAddr: observedAddr,
             closeEvent: conn.closeEvent,
             timeout: timeout,
             dir: conn.dir)
  result.initStream()

method initStream*(s: SecureConn) =
  if s.objName.len == 0:
    s.objName = SecureConnTrackerName

  procCall Connection(s).initStream()

method closeImpl*(s: SecureConn) {.async.} =
  trace "Closing secure conn", s, dir = s.dir
  if not(isNil(s.stream)):
    await s.stream.close()

  await procCall Connection(s).closeImpl()

method readMessage*(c: SecureConn): Future[seq[byte]] {.async, base.} =
  doAssert(false, "Not implemented!")

method getWrapped*(s: SecureConn): Connection = s.stream

method handshake*(s: Secure,
                  conn: Connection,
                  initiator: bool,
                  peerId: Opt[PeerId]): Future[SecureConn] {.async, base.} =
  doAssert(false, "Not implemented!")

proc handleConn(s: Secure,
                 conn: Connection,
                 initiator: bool,
                 peerId: Opt[PeerId]): Future[Connection] {.async.} =
  var sconn = await s.handshake(conn, initiator, peerId)
  # mark connection bottom level transport direction
  # this is the safest place to do this
  # we require this information in for example gossipsub
  sconn.transportDir = if initiator: Direction.Out else: Direction.In

  proc cleanup() {.async: (raises: []).} =
    try:
      block:
        let
          fut1 = conn.join()
          fut2 = sconn.join()
        await fut1 or fut2  # one join() completes, cancel outstanding join()
        if not fut1.finished: await fut1.cancelAndWait()
        if not fut2.finished: await fut2.cancelAndWait()
      block:
        let
          fut1 = sconn.close()
          fut2 = conn.close()
        await allFutures(fut1, fut2)
        if fut1.failed:
          let err = fut1.error()
          if not (err of CancelledError):
            debug "error cleaning up secure connection", err = err.msg, sconn
        if fut2.failed:
          let err = fut2.error()
          if not (err of CancelledError):
            debug "error cleaning up secure connection", err = err.msg, sconn

    except CancelledError:
      # This is top-level procedure which will work as separate task, so it
      # do not need to propagate CancelledError.
      discard

  if not isNil(sconn):
    # All the errors are handled inside `cleanup()` procedure.
    asyncSpawn cleanup()

  return sconn

method init*(s: Secure) =
  procCall LPProtocol(s).init()

  proc handle(conn: Connection, proto: string) {.async.} =
    trace "handling connection upgrade", proto, conn
    try:
      # We don't need the result but we
      # definitely need to await the handshake
      discard await s.handleConn(conn, false, Opt.none(PeerId))
      trace "connection secured", conn
    except CancelledError as exc:
      warn "securing connection canceled", conn
      await conn.close()
      raise exc
    except CatchableError as exc:
      warn "securing connection failed", err = exc.msg, conn
      await conn.close()

  s.handler = handle

method secure*(s: Secure,
               conn: Connection,
               peerId: Opt[PeerId]):
               Future[Connection] {.base.} =
  s.handleConn(conn, conn.dir == Direction.Out, peerId)

method readOnce*(s: SecureConn,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async.} =
  doAssert(nbytes > 0, "nbytes must be positive integer")

  if s.isEof:
    raise newLPStreamEOFError()

  if s.buf.data().len() == 0:
    try:
      let buf = await s.readMessage() # Always returns >0 bytes or raises
      s.activity = true
      s.buf.add(buf)
    except LPStreamEOFError as err:
      s.isEof = true
      await s.close()
      raise err
    except CancelledError as exc:
      raise exc
    except CatchableError as err:
      debug "Error while reading message from secure connection, closing.",
        error = err.name,
        message = err.msg,
        connection = s
      await s.close()
      raise err

  var p = cast[ptr UncheckedArray[byte]](pbytes)
  return s.buf.consumeTo(toOpenArray(p, 0, nbytes - 1))
