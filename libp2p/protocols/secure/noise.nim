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
       ../../crypto/[crypto, chacha20poly1305, curve25519, hkdf]

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
    initiator: bool
  
  Noise* = ref object of Secure
    localPrivateKey: PrivateKey
    localPublicKey: PublicKey
    noisePrivateKey: Curve25519Key
    noisePublicKey: Curve25519Key
    hs: HandshakeState

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

proc dh(priv: Curve25519Key, pub: Curve25519Key): Curve25519Key =
  Curve25519.mul(result, priv, pub)

# Cipherstate

proc init(cs: var CipherState; key: ChaChaPolyKey) =
  cs.k = key
  cs.n = 0

proc hasKey(cs: var CipherState): bool =
  cs.k != EmptyKey

proc encryptWithAd(state: var CipherState; ad, data: var openarray[byte]) =
  var
    tag: ChaChaPolyTag
    nonce: ChaChaPolyNonce
    np = cast[ptr uint64](addr nonce)
  np[] = state.n
  ChaChaPoly.encrypt(state.k, nonce, tag, data, ad)
  inc state.n

proc decryptWithAd(state: var CipherState, ad, data: var openarray[byte]) =
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

proc mixKey(ss: var SymmetricState, ikm: ChaChaPolyKey) =
  var
    temp_keys: array[2, ChaChaPolyKey]
    nkeys = 0
  for next in sha256.hkdf(ss.ck, ikm, []):
    if nkeys > temp_keys.high:
      break
    temp_keys[nkeys] = next.data
    inc nkeys

  ss.ck = temp_keys[0]
  init ss.cs, temp_keys[1]

proc mixHash(ss: var SymmetricState; data: openarray[byte]) =
  var s: seq[byte]
  s &= ss.h.data
  s &= data
  ss.h = sha256.digest(s)

proc mixKeyAndHash(ss: var SymmetricState; ikm: var openarray[byte]) =
  var
    temp_keys: array[3, ChaChaPolyKey]
    nkeys = 0
  for next in sha256.hkdf(ss.ck, ikm, []):
    if nkeys > temp_keys.high:
      break
    temp_keys[nkeys] = next.data
    inc nkeys

  ss.ck = temp_keys[0]
  ss.mixHash(temp_keys[1])
  init ss.cs, temp_keys[2]

proc encryptAndHash(ss: var SymmetricState, data: var openarray[byte]) =
  # according to spec if key is empty leave plaintext
  if ss.cs.hasKey:
    ss.cs.encryptWithAd(ss.h.data, data)
  ss.mixHash(data)

proc decryptAndHash(ss: var SymmetricState, data: var openarray[byte]) =
  # according to spec if key is empty leave plaintext
  if ss.cs.hasKey:
    ss.cs.decryptWithAd(ss.h.data, data)
  ss.mixHash(data)

proc mixKey(ss: var SymmetricState): tuple[cs1, cs2: CipherState] =
  var
    temp_keys: array[2, ChaChaPolyKey]
    nkeys = 0
  for next in sha256.hkdf(ss.ck, [], []):
    if nkeys > temp_keys.high:
      break
    temp_keys[nkeys] = next.data
    inc nkeys

  init result.cs1, temp_keys[0]
  init result.cs2, temp_keys[1]

proc handshakeXXOutbound(p: Noise, conn: Connection, p2pProof: ProtoBuffer): Future[void] {.async.} =
  init p.hs.ss
  p.hs.initiator = true
  p.hs.s.privateKey = p.noisePrivateKey
  p.hs.s.publicKey = p.noisePublicKey
  # the rest of keys in hs are empty/0

  # stage 0
  block stage0:
    p.hs.e = genKeyPair()
    var ne = p.hs.e.publicKey
    p.hs.ss.mixHash(ne)
    var emptyPayload = newSeq[byte]()
    p.hs.ss.encryptAndHash(emptyPayload)
    await conn.write(@ne)
  
  # stage 1
  block stage1:
    var
      s1msg = await conn.read()
      s1ns = s1msg[ChaChaPolyKey.high..<80]
      s1ciph = s1msg[80..s1msg.high]
    copyMem(addr p.hs.re[0], addr s1msg[0], Curve25519Key.len)
    p.hs.ss.mixHash(p.hs.re)
    p.hs.ss.mixKey(dh(p.hs.e.privateKey, p.hs.re))
    s1msg = s1msg[Curve25519Key.len..s1msg.high]
    p.hs.ss.decryptAndHash(s1msg)
    copyMem(addr p.hs.rs[0], addr s1msg[0], Curve25519Key.len)
    p.hs.ss.mixKey(dh(p.hs.e.privateKey, p.hs.rs))
    s1msg = s1msg[Curve25519Key.len..s1msg.high]
    p.hs.ss.decryptAndHash(s1msg)
  
  unimplemented()

proc handshakeXXInbound(p: Noise, conn: Connection, p2pProof: ProtoBuffer) {.async.} =
  init p.hs.ss
  p.hs.initiator = false
  p.hs.s.privateKey = p.noisePrivateKey
  p.hs.s.publicKey = p.noisePublicKey
  # the rest of keys in hs are empty/0

  # stage 0
  block stage0:
    var
      s0msg = await conn.read()
    copyMem(addr p.hs.re[0], addr s0msg[0], Curve25519Key.len)
    p.hs.ss.mixHash(p.hs.re)
    s0msg = s0msg[Curve25519Key.len..s0msg.high]
    p.hs.ss.decryptAndHash(s0msg)

  # stage 1
  block stage1:
    var ne = EmptyKey
    p.hs.e = genKeyPair()
    ne = p.hs.e.publicKey
    p.hs.ss.mixHash(ne)
    p.hs.ss.mixKey(dh(p.hs.e.privateKey, p.hs.re))
    var spk = @(p.hs.s.publicKey)
    p.hs.ss.encryptAndHash(spk)
    p.hs.ss.mixKey(dh(p.hs.s.privateKey, p.hs.re))
    var payload = p2pProof.buffer
    p.hs.ss.encryptAndHash(payload)
    await conn.write(@ne & spk & payload)
  
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
