## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import chronos
import chronicles
import ../protocol,
       ../../stream/bufferstream,
       ../../crypto/crypto,
       ../../connection,
       ../../peerinfo,
       ../../utility

type
  Secure* = ref object of LPProtocol # base type for secure managers
  SecureConn* = ref object of Connection

method readMessage*(c: SecureConn): Future[seq[byte]] {.async, base.} =
  doAssert(false, "Not implemented!")

method writeMessage*(c: SecureConn, data: seq[byte]) {.async, base.} =
  doAssert(false, "Not implemented!")

method handshake(s: Secure,
                 conn: Connection,
                 initiator: bool = false): Future[SecureConn] {.async, base.} =
  doAssert(false, "Not implemented!")

proc readLoop(sconn: SecureConn, stream: BufferStream) {.async.} =
  try:
    while not sconn.closed:
      let msg = await sconn.readMessage()
      if msg.len == 0:
        trace "stream EOF"
        return

      await stream.pushTo(msg)
  except CatchableError as exc:
    trace "exception occurred SecioConn.readLoop", exc = exc.msg
  finally:
    if not sconn.closed:
      await sconn.close()
    trace "ending secio readLoop", isclosed = sconn.closed()

proc handleConn*(s: Secure, conn: Connection, initiator: bool = false): Future[Connection] {.async, gcsafe.} =
  var sconn = await s.handshake(conn, initiator)
  proc writeHandler(data: seq[byte]) {.async, gcsafe.} =
    trace "sending encrypted bytes", bytes = data.shortLog
    await sconn.writeMessage(data)

  var stream = newBufferStream(writeHandler)
  asyncCheck readLoop(sconn, stream)
  result = newConnection(stream)
  result.closeEvent.wait()
    .addCallback do (udata: pointer):
      trace "wrapped connection closed, closing upstream"
      if not isNil(sconn) and not sconn.closed:
        asyncCheck sconn.close()

  result.peerInfo = PeerInfo.init(sconn.peerInfo.publicKey.get())

method init*(s: Secure) {.gcsafe.} =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    trace "handling connection"
    try:
      asyncCheck s.handleConn(conn, false)
      trace "connection secured"
    except CatchableError as exc:
      if not conn.closed():
        warn "securing connection failed", msg = exc.msg
        await conn.close()

  s.handler = handle

method secure*(s: Secure, conn: Connection): Future[Connection] {.async, base, gcsafe.} =
  try:
    result = await s.handleConn(conn, true)
  except CatchableError as exc:
    warn "securing connection failed", msg = exc.msg
    if not conn.closed():
      await conn.close()
