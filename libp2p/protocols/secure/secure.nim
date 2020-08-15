## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import chronos, chronicles, bearssl
import ../protocol,
       ../../stream/streamseq,
       ../../stream/connection,
       ../../multiaddress,
       ../../peerinfo

logScope:
  topics = "secure"

type
  Secure* = ref object of LPProtocol # base type for secure managers

  SecureConn* = ref object of Connection
    stream*: Connection
    buf: StreamSeq

proc init*[T: SecureConn](C: type T,
                          conn: Connection,
                          peerInfo: PeerInfo,
                          observedAddr: Multiaddress,
                          timeout: Duration = DefaultConnectionTimeout): T =
  result = C(stream: conn,
             peerInfo: peerInfo,
             observedAddr: observedAddr,
             closeEvent: conn.closeEvent,
             timeout: timeout)
  result.initStream()

method initStream*(s: SecureConn) =
  if s.objName.len == 0:
    s.objName = "SecureConn"

  procCall Connection(s).initStream()

method close*(s: SecureConn) {.async.} =
  if not(isNil(s.stream)):
    await s.stream.close()

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
  if not isNil(sconn):
    conn.join()
      .addCallback do(udata: pointer = nil):
        asyncCheck sconn.close()

  return sconn

method init*(s: Secure) {.gcsafe.} =
  procCall LPProtocol(s).init()

  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    trace "handling connection upgrade", proto
    try:
      # We don't need the result but we
      # definitely need to await the handshake
      discard await s.handleConn(conn, false)
      trace "connection secured"
    except CancelledError as exc:
      warn "securing connection canceled"
      await conn.close()
      raise exc
    except CatchableError as exc:
      warn "securing connection failed", msg = exc.msg
      await conn.close()

  s.handler = handle

method secure*(s: Secure,
               conn: Connection,
               initiator: bool):
               Future[Connection] {.async, base, gcsafe.} =
  result = await s.handleConn(conn, initiator)

method readOnce*(s: SecureConn,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async, gcsafe.} =
  if nbytes == 0:
    return 0

  if s.buf.data().len() == 0:
    let buf = await s.readMessage()
    s.activity = true
    if buf.len == 0:
      raise newLPStreamIncompleteError()
    s.buf.add(buf)

  var p = cast[ptr UncheckedArray[byte]](pbytes)
  return s.buf.consumeTo(toOpenArray(p, 0, nbytes - 1))
