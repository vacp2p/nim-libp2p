## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import chronos, chronicles
import ../protocol,
       ../../stream/streamseq,
       ../../connection,
       ../../peerinfo

type
  Secure* = ref object of LPProtocol # base type for secure managers

  SecureConn* = ref object of Connection
    buf: StreamSeq

method readMessage*(c: SecureConn): Future[seq[byte]] {.async, base.} =
  doAssert(false, "Not implemented!")

method handshake(s: Secure,
                 conn: Connection,
                 initiator: bool): Future[SecureConn] {.async, base.} =
  doAssert(false, "Not implemented!")

proc handleConn*(s: Secure, conn: Connection, initiator: bool): Future[Connection] {.async, gcsafe.} =
  var sconn = await s.handshake(conn, initiator)

  result = sconn

  if not isNil(sconn.peerInfo) and sconn.peerInfo.publicKey.isSome:
    result.peerInfo = PeerInfo.init(sconn.peerInfo.publicKey.get())

method init*(s: Secure) {.gcsafe.} =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    trace "handling connection upgrade", proto
    try:
      # We don't need the result but we definitely need to await the handshake
      discard await s.handleConn(conn, false)
      trace "connection secured"
    except CatchableError as exc:
      if not conn.closed():
        warn "securing connection failed", msg = exc.msg
        await conn.close()

  s.handler = handle

method secure*(s: Secure, conn: Connection, initiator: bool): Future[Connection] {.async, base, gcsafe.} =
  try:
    result = await s.handleConn(conn, initiator)
  except CatchableError as exc:
    warn "securing connection failed", msg = exc.msg
    await conn.close()

method readExactly*(s: SecureConn,
                    pbytes: pointer,
                    nbytes: int):
                    Future[void] {.async, gcsafe.} =
  if nbytes == 0:
    return

  while s.buf.data().len < nbytes:
    # TODO write decrypted content straight into buf using `prepare`
    let buf = await s.readMessage()
    if buf.len == 0:
      raise newLPStreamIncompleteError()
    s.buf.add(buf)

  var p = cast[ptr UncheckedArray[byte]](pbytes)
  let consumed = s.buf.consumeTo(toOpenArray(p, 0, nbytes - 1))
  doAssert consumed == nbytes, "checked above"

method readOnce*(s: SecureConn,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async, gcsafe.} =
  if nbytes == 0:
    return 0

  if s.buf.data().len() == 0:
    let buf = await s.readMessage()
    if buf.len == 0:
      raise newLPStreamIncompleteError()
    s.buf.add(buf)

  var p = cast[ptr UncheckedArray[byte]](pbytes)
  return s.buf.consumeTo(toOpenArray(p, 0, nbytes - 1))
