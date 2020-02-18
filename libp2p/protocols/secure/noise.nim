## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import chronos
import chronicles
import nimcrypto/[utils, sysrand, sha2, hmac]
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

  ProtocolXXName = "Noise_XX_25519_ChaChaPoly_SHA256"

let
  # Empty is a special value which indicates k has not yet been initialized.
  EmptyKey: ChaChaPolyKey = [0.byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  NonceMax = uint64.high - 1 # max is reserved

type
  NoiseSeq = array[32, byte]
  
  KeyPair = object
    privateKey: Curve25519Key
    publicKey: Curve25519Key
  
  # https://noiseprotocol.org/noise.html#the-cipherstate-object
  CipherState = object
    k: ChaChaPolyKey
    # noise spec says uint64
    # go implementation has uint32 tho I noticed!!
    n: uint64

  # https://noiseprotocol.org/noise.html#the-symmetricstate-object
  SymmetricState = object
    cs: CipherState
    ck: ChaChaPolyKey
    h: MDigest[256]

  # https://noiseprotocol.org/noise.html#the-handshakestate-object
  HandshakeState = object
    ss: SymmetricState
    s: KeyPair
    e: KeyPair
    rs: Curve25519Key
    re: Curve25519Key
  
  Noise* = ref object of Secure
    localPrivateKey: PrivateKey
    localPublicKey: PublicKey
    noisePrivateKey: Curve25519Key
    noisePublicKey: Curve25519Key
    hstate: HandshakeState

  NoiseConnection* = ref object of Connection

# Utility

proc genKeyPair: KeyPair =
  result.privateKey = Curve25519Key.random()
  result.publicKey = result.privateKey.public()
    
# todo this should be exposed maybe or replaced with a more public version
proc getBytes*(key: string): seq[byte] =
  result.setLen(key.len)
  copyMem(addr result[0], unsafeaddr key[0], key.len)

proc hashProtocol(name: string): MDigest[256] =
  #[
     If protocol_name is less than or equal to HASHLEN bytes in length, 
     sets h equal to protocol_name with zero bytes appended to make HASHLEN bytes. 
     Otherwise sets h = HASH(protocol_name).
  ]#
  
  if name.len <= 32:
    copyMem(addr result.data[0], unsafeAddr name[0], name.len)
  else:
    result = sha256.digest(name)

proc hkdf(salt: NoiseSeq, ikm: NoiseSeq): tuple[a,b,c: NoiseSeq] =
  let prk = sha256.hmac(salt, ikm)
  
  unimplemented()

# Cipherstate

proc init(cs: var CipherState; key: ChaChaPolyKey) =
  cs.k = key
  cs.n = 0

proc hasKey(cs: var CipherState): bool =
  cs.k != EmptyKey

proc encryptWithAd(state: var CipherState; ad, data: var seq[byte]) =
  var
    tag: ChaChaPolyTag
    nonce: ChaChaPolyNonce
    np = cast[ptr uint64](addr nonce)
  np[] = state.n
  ChaChaPoly.encrypt(state.k, nonce, tag, data, ad)
  inc state.n

proc decryptWithAd(state: var CipherState, ad, data: var seq[byte]) =
  var
    tag: ChaChaPolyTag
    nonce: ChaChaPolyNonce
    np = cast[ptr uint64](addr nonce)
  np[] = state.n
  ChaChaPoly.decrypt(state.k, nonce, tag, data, ad)
  inc state.n

# Symmetricstate

proc init(ss: var SymmetricState) =
  ss.h = ProtocolXXName.hashProtocol
  ss.ck = ss.h.data.intoChaChaPolyKey
  init ss.cs, EmptyKey

proc mixKey(ss: var SymmetricState) =
  unimplemented()

proc mixHash(ss: var SymmetricState; data: var openarray[byte]) =
  var s: seq[byte]
  s &= ss.h.data
  s &= data
  ss.h = sha256.digest(s)

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
