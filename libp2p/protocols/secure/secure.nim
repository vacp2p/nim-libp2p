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
    cleanupFut: Future[void]

  SecureConn* = ref object of Connection

method readMessage*(c: SecureConn): Future[seq[byte]] {.async, base.} =
  doAssert(false, "Not implemented!")

method writeMessage*(c: SecureConn, data: seq[byte]) {.async, base.} =
  doAssert(false, "Not implemented!")

method handshake(s: Secure,
                 conn: Connection,
                 initiator: bool = false): Future[SecureConn] {.async, base.} =
  doAssert(false, "Not implemented!")

proc readLoop(sconn: SecureConn, conn: Connection) {.async.} =
  try:
    let stream = BufferStream(conn.stream)
    while not sconn.closed:
      let msg = await sconn.readMessage()
      if msg.len == 0:
        trace "stream EOF"
        return

      await stream.pushTo(msg)
  except CatchableError as exc:
    trace "Exception occurred Secure.readLoop", exc = exc.msg
  finally:
    trace "closing conn", closed = conn.closed()
    if not conn.closed:
      await conn.close()

    trace "closing sconn", closed = sconn.closed()
    if not sconn.closed:
      await sconn.close()
    trace "ending Secure readLoop"

proc handleConn*(s: Secure, conn: Connection, initiator: bool = false): Future[Connection] {.async, gcsafe.} =
  var sconn = await s.handshake(conn, initiator)
  proc writeHandler(data: seq[byte]) {.async, gcsafe.} =
    trace "sending encrypted bytes", bytes = data.shortLog
    await sconn.writeMessage(data)

  result = newConnection(newBufferStream(writeHandler))
  asyncCheck readLoop(sconn, result)

  if not isNil(sconn.peerInfo) and sconn.peerInfo.publicKey.isSome:
    result.peerInfo = PeerInfo.init(sconn.peerInfo.publicKey.get())

method init*(s: Secure) {.gcsafe.} =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    trace "handling connection"
    try:
      # We don't need the result but we definitely need to await the handshake
      discard await s.handleConn(conn, false)
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
