## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[options, strformat]
import chronos, chronicles, bearssl
import ../protocol,
       ../../stream/streamseq,
       ../../stream/connection,
       ../../multiaddress,
       ../../peerinfo

export protocol

logScope:
  topics = "secure"

type
  Secure* = ref object of LPProtocol # base type for secure managers

  SecureConn* = ref object of Connection
    stream*: Connection
    buf: StreamSeq

func shortLog*(conn: SecureConn): auto =
  if conn.isNil: "SecureConn(nil)"
  elif conn.peerInfo.isNil: $conn.oid
  else: &"{shortLog(conn.peerInfo.peerId)}:{conn.oid}"
chronicles.formatIt(SecureConn): shortLog(it)

proc init*(T: type SecureConn,
           conn: Connection,
           peerInfo: PeerInfo,
           observedAddr: Multiaddress,
           timeout: Duration = DefaultConnectionTimeout): T =
  result = T(stream: conn,
             peerInfo: peerInfo,
             observedAddr: observedAddr,
             closeEvent: conn.closeEvent,
             timeout: timeout,
             dir: conn.dir)
  result.initStream()

method initStream*(s: SecureConn) =
  if s.objName.len == 0:
    s.objName = "SecureConn"

  procCall Connection(s).initStream()

method close*(s: SecureConn) {.async.} =
  trace "closing secure conn", s, dir = s.dir
  if not(isNil(s.stream)):
    await s.stream.closeWithEOF()

  await procCall Connection(s).close()

method readMessage*(c: SecureConn): Future[seq[byte]] {.async, base.} =
  doAssert(false, "Not implemented!")

method handshake(s: Secure,
                 conn: Connection,
                 initiator: bool): Future[SecureConn] {.async, base.} =
  doAssert(false, "Not implemented!")

proc handleConn*(s: Secure,
                 conn: Connection,
                 initiator: bool): Future[Connection] {.async, gcsafe.} =
  var sconn = await s.handshake(conn, initiator)

  proc cleanup() {.async.} =
    try:
      await conn.join()
      await sconn.close()
    except CatchableError as exc:
      trace "error cleaning up secure connection", err = exc.msg, sconn

  if not isNil(sconn):
    # All the errors are handled inside `cleanup()` procedure.
    asyncSpawn cleanup()

  return sconn

method init*(s: Secure) {.gcsafe.} =
  procCall LPProtocol(s).init()

  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    trace "handling connection upgrade", proto, conn
    try:
      # We don't need the result but we
      # definitely need to await the handshake
      discard await s.handleConn(conn, false)
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
               initiator: bool):
               Future[Connection] {.base, gcsafe.} =
  s.handleConn(conn, initiator)

method readOnce*(s: SecureConn,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async, gcsafe.} =
  doAssert(nbytes > 0, "nbytes must be positive integer")

  if s.buf.data().len() == 0:
    let (buf, err) = try:
        (await s.readMessage(), nil)
      except CatchableError as exc:
        (@[], exc)

    if not isNil(err):
      if not (err of LPStreamEOFError):
        warn "error while reading message from secure connection, closing.",
          error=err.name,
          message=err.msg,
          connection=s
      await s.close()
      raise err

    s.activity = true

    if buf.len == 0:
      raise newLPStreamIncompleteError()

    s.buf.add(buf)

  var p = cast[ptr UncheckedArray[byte]](pbytes)
  return s.buf.consumeTo(toOpenArray(p, 0, nbytes - 1))
