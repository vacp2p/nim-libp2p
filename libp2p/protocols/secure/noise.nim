## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import chronicles
import nimcrypto/[utils, sysrand]
import ../../connection
import ../../protobuf/minprotobuf
import secure,
       ../../crypto/crypto,
       ../../crypto/chacha20poly1305,
       ../../crypto/curve25519

template unimplemented: untyped =
  doAssert(false, "Not implemented")

const
  # https://godoc.org/github.com/libp2p/go-libp2p-noise#pkg-constants
  NoiseCodec = "/noise"
  
  PayloadString = "noise-libp2p-static-key:"

type
  Noise* = ref object of Secure
    localPrivateKey: PrivateKey
    localPublicKey: PublicKey
    noisePrivateKey: Curve25519Key
    noisePublicKey: Curve25519Key

  NoiseConnection* = ref object of Connection

# todo this should be exposed maybe or replaced with a more public version
proc getBytes*(key: string): seq[byte] =
  result.setLen(key.len)
  copyMem(addr result[0], unsafeaddr key[0], key.len)

proc handshakeXXOutbound(p: Noise, conn: Connection, p2pProof: ProtoBuffer): Future[void] {.async.} =
  unimplemented()

proc handshakeXXInbound(p: Noise, conn: Connection, p2pProof: ProtoBuffer) {.async.} =
  unimplemented()

proc handshake*(p: Noise, conn: Connection, initiator: bool): Future[NoiseConnection] {.async.} =
  # https://github.com/libp2p/specs/tree/master/noise#libp2p-data-in-handshake-messages
  let
    signedPayload = p.localPrivateKey.sign(PayloadString.getBytes & p.noisePublicKey.getBytes)
    
  var
    libp2pProofPb = initProtoBuffer({WithUint32BeLength})
  libp2pProofPb.write(initProtoField(1, p.localPublicKey.getBytes()))
  libp2pProofPb.write(initProtoField(2, signedPayload))
  # data field also there but not used!
  libp2pProofPb.finish()

  if initiator:
    await handshakeXXOutbound(p, conn, libp2pProofPb)
  else:
    await handshakeXXInbound(p, conn, libp2pProofPb)
  
  unimplemented()

method init*(p: Noise) {.gcsafe.} =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    trace "handling connection"
    try:
      asyncCheck p.handshake(conn, false)
      trace "connection secured"
    except CatchableError as ex:
      if not conn.closed():
        warn "securing connection failed", msg = ex.msg
        await conn.close()

    p.codec = NoiseCodec
    p.handler = handle
  
method secure*(p: Noise, conn: Connection): Future[Connection] {.async, gcsafe.} =
  try:
    result = await p.handshake(conn, true)
  except CatchableError as ex:
     warn "securing connection failed", msg = ex.msg
     if not conn.closed():
       await conn.close()
  
proc newNoise*(privateKey: PrivateKey): Noise =
  new result
  result.localPrivateKey = privateKey
  result.localPublicKey = privateKey.getKey()
  discard randomBytes(result.noisePrivateKey)
  result.noisePublicKey = result.noisePrivateKey.public()
  result.init()
