## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles, nimcrypto/sysrand
import secure, ../../connection, ../../crypto/crypto

logScope:
  topic = "secio"

const
  SecioCodec* = "/secio/1.0.0"
  SecioMaxMessageSize = 8 * 1024 * 1024 ## 8mb
  SecioNonceSize = 16
  SecioExchanges = "P-256,P-384,P-521"
  SecioCiphers = "AES-256,AES-128"
  SecioHashes = "SHA-256,SHA-512"

type
  Secio = ref object of Secure
    localPublicKey: PublicKey

proc transactMessage(conn: Connection,
                     msg: seq[byte]): Future[seq[byte]] {.async.} =
  var buf = newSeq[byte](4)
  try:
    debug "Sending proposal", message = toHex(msg)
    await conn.write(msg)
    await conn.readExactly(addr buf[0], 4)
    let length = (int(buf[0]) shl 24) or (int(buf[1]) shl 16) or
                 (int(buf[2]) shl 8) or (int(buf[3]))
    debug "Recieved message header", header = toHex(buf), length = length
    if length <= SecioMaxMessageSize:
      buf.setLen(length)
      await conn.readExactly(addr buf[0], length)
      debug "Received message body", conn = conn, length = length
      result = buf
    else:
      debug "Received size of message exceed limits", conn = conn,
                                                      length = length
  except AsyncStreamIncompleteError:
    debug "Connection dropped while reading", conn = conn
  except AsyncStreamReadError:
    debug "Error reading from connection", conn = conn
  except AsyncStreamWriteError:
    debug "Could not write to connection", conn = conn

proc handshake*(p: Secio, conn: Connection) {.async.} =
  var nonce: array[SecioNonceSize, byte]
  var pk = p.localPublicKey.getBytes()
  echo toHex(pk)
  if randomBytes(nonce) != SecioNonceSize:
    raise newException(CatchableError, "Could not generate random data")
  
  debug "Local proposal", schemes = SecioExchanges, ciphers = SecioCiphers,
                          hashes = SecioHashes, nonce = toHex(nonce),
                          pubkey = toHex(pk)
  
  echo "local proposal"

  var answer = await transactMessage(conn,
    createProposal(nonce, pk, SecioExchanges, SecioCiphers, SecioHashes)
  )

  echo toHex(answer)

  if len(answer) == 0:
    debug "Proposal exchange failed", conn = conn
    return

method init(p: Secio) {.gcsafe.} =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} = 
    echo "HERE"

  p.codec = SecioCodec
  p.handler = handle

method secure*(p: Secio, conn: Connection): Future[Connection] {.async, gcsafe.} =
  echo "handshaking"
  await p.handshake(conn)

proc newSecio*(localPublicKey: PublicKey): Secio =
  new result
  result.localPublicKey = localPublicKey
  result.init()

