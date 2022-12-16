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

import chronos
import secure, ../../stream/connection

const PlainTextCodec* = "/plaintext/2.0.0"

type
  PlainText* = ref object of Secure
    localPublicKey: PublicKey

  PlainTextError* = object of LPError

  PlainTextConnection* = ref object of SecureConn

method readMessage*(sconn: PlainTextConnection): Future[seq[byte]] {.async.} =
  var buffer: array[32768, byte]
  let length = await sconn.stream.readOnce(addr buffer[0], buffer.len)
  return @(buffer[0..length])

method write*(sconn: PlainTextConnection, message: seq[byte]): Future[void] =
  sconn.stream.write(message)

method handshake*(p: PlainText, conn: Connection, initiator: bool, peerId: Opt[PeerId]): Future[SecureConn] {.async.} =
  var exchange = initProtoBuffer()
  exchange.write(2, p.localPublicKey)

  await conn.writeLp(exchange.buffer)
  let
    remoteData = await conn.readLp(1024)
    remotePb = initProtoBuffer(remoteData)
  var remotePk: PublicKey
  remotePb.getRequiredField(2, remotePk).tryGet()

  let remotePeerId = PeerId.init(remotePk).valueOr:
    raise newException(PlainTextError, "Invalid remote peer id: " & $error)

  if peerId.isSome:
    if peerId.get() != remotePeerId:
      raise newException(PlainTextError, "Plain text handshake, peer id don't match! " & $remotePeerId & " != " & $peerId)

  var res = PlainTextConnection.new(conn, conn.peerId, conn.observedAddr)
  return res

method init*(p: PlainText) {.gcsafe.} =
  procCall Secure(p).init()
  p.codec = PlainTextCodec

proc new*(
    T: typedesc[PlainText],
    privateKey: PrivateKey
    ): T =

  let pk = privateKey.getPublicKey()
  .expect("Expected valid Private Key")

  let plainText = T(localPublicKey: pk)
  plainText.init()
  plainText
