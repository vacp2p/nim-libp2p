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
    cs1: CipherState
    cs2: CipherState
    initiator: bool # remove probably

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

proc encryptWithAd(state: var CipherState; ad, data: var openarray[byte]): seq[byte] =
  var
    tag: ChaChaPolyTag
    nonce: ChaChaPolyNonce
    np = cast[ptr uint64](addr nonce[4])
  np[] = state.n
  result = @data
  ChaChaPoly.encrypt(state.k, nonce, tag, result, ad)
  inc state.n
  result &= @tag

proc decryptWithAd(state: var CipherState, ad, data: var openarray[byte]): seq[byte] =
  var
    tag = cast[ChaChaPolyTag](data[(data.len - ChaChaPolyTag.len)..data.high])
    nonce: ChaChaPolyNonce
    np = cast[ptr uint64](addr nonce[4])
  np[] = state.n
  result = newSeq[byte](data.len - ChaChaPolyTag.len)
  ChaChaPoly.decrypt(state.k, nonce, tag, result, ad)
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

# proc mixKeyAndHash(ss: var SymmetricState; ikm: var openarray[byte]) =
#   var
#     temp_keys: array[3, ChaChaPolyKey]
#     nkeys = 0
#   for next in sha256.hkdf(ss.ck, ikm, []):
#     if nkeys > temp_keys.high:
#       break
#     temp_keys[nkeys] = next.data
#     inc nkeys

#   ss.ck = temp_keys[0]
#   ss.mixHash(temp_keys[1])
#   init ss.cs, temp_keys[2]

proc encryptAndHash(ss: var SymmetricState, data: var openarray[byte]): seq[byte] =
  # according to spec if key is empty leave plaintext
  if ss.cs.hasKey:
    result = ss.cs.encryptWithAd(ss.h.data, data)
  else:
    result = @data
  ss.mixHash(result)

proc decryptAndHash(ss: var SymmetricState, data: var openarray[byte]): seq[byte] =
  # according to spec if key is empty leave plaintext
  if ss.cs.hasKey:
    result = ss.cs.decryptWithAd(ss.h.data, data)
  else:
    result = @data
  ss.mixHash(result)

proc split(ss: var SymmetricState): tuple[cs1, cs2: CipherState] =
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
  
template write_e: untyped =
  echo "write_e"
  # Sets e (which must be empty) to GENERATE_KEYPAIR(). Appends e.public_key to the buffer. Calls MixHash(e.public_key).

  when defined(noise_test_vectors):
    when initiator:
      hs.e.privateKey = "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a".fromHex.intoCurve25519Key
    else:
      hs.e.privateKey = "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b".fromHex.intoCurve25519Key
    hs.e.publicKey = hs.e.privateKey.public()
  else:
    hs.e = genKeyPair()

  var ne = hs.e.publicKey
  msg &= @ne
  hs.ss.mixHash(ne)

template write_s: untyped =
  echo "write_s"
  # Appends EncryptAndHash(s.public_key) to the buffer.
  var spk = @(hs.s.publicKey)
  msg &= hs.ss.encryptAndHash(spk)

template dh_ee: untyped =
  echo "dh_ee"
  # Calls MixKey(DH(e, re)).
  hs.ss.mixKey(dh(hs.e.privateKey, hs.re))

template dh_es: untyped =
  echo "dh_es"
  # Calls MixKey(DH(e, rs)) if initiator, MixKey(DH(s, re)) if responder.
  when initiator:
    hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))
  else:
    hs.ss.mixKey(dh(hs.s.privateKey, hs.re))

template dh_se: untyped =
  echo "dh_se"
  # Calls MixKey(DH(s, re)) if initiator, MixKey(DH(e, rs)) if responder.
  when initiator:
    hs.ss.mixKey(dh(hs.s.privateKey, hs.re))
  else:
    hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))

template dh_ss: untyped =
  echo "dh_ss"
  # Calls MixKey(DH(s, rs)).
  hs.ss.mixKey(dh(hs.s.privateKey, hs.rs))

template read_e: untyped =
  echo "read_e"
  # Sets re (which must be empty) to the next DHLEN bytes from the message. Calls MixHash(re.public_key).
  copyMem(addr hs.re[0], addr msg[0], Curve25519Key.len)
  msg = msg[Curve25519Key.len..msg.high]
  hs.ss.mixHash(hs.re)

template read_s: untyped =
  echo "read_s"
  # Sets temp to the next DHLEN + 16 bytes of the message if HasKey() == True, or to the next DHLEN bytes otherwise.
  # Sets rs (which must be empty) to DecryptAndHash(temp).
  var temp: seq[byte]
  if hs.ss.cs.hasKey:
    temp.setLen(Curve25519Key.len + 16)
    copyMem(addr temp[0], addr msg[0], Curve25519Key.len + 16)
    msg = msg[Curve25519Key.len + 16..msg.high]
  else:
    temp.setLen(Curve25519Key.len)
    copyMem(addr temp[0], addr msg[0], Curve25519Key.len)
    msg = msg[Curve25519Key.len..msg.high]
  var plain = hs.ss.decryptAndHash(temp)
  copyMem(addr hs.rs[0], addr plain[0], Curve25519Key.len)
  
proc handshakeXXOutbound(p: Noise, conn: Connection, p2pProof: ProtoBuffer): Future[tuple[cs1, cs2: CipherState]] {.async.} =
  var hs: HandshakeState
  
  init hs.ss
  const initiator = true
  when not defined(noise_test_vectors):
    hs.s.privateKey = p.noisePrivateKey
    hs.s.publicKey = p.noisePublicKey
  else:
    hs.s.privateKey = "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1".fromHex.intoCurve25519Key
    hs.s.publicKey = hs.s.privateKey.public()
  # the rest of keys in hs are empty/0

  # -> e
  var msg: seq[byte]

  write_e()

  when defined(noise_test_vectors):
    var testload = "4c756477696720766f6e204d69736573".fromHex
    msg &= hs.ss.encryptAndHash(testload)

  await conn.writeLp(msg)

  when defined(noise_test_vectors):
    doAssert msg.toHex(true) == "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573"

  # <- e, ee, s, es

  msg = await conn.readLp()

  read_e()
  dh_ee()
  read_s()
  dh_es()

  when defined(noise_test_vectors):
    var testloadstr = hs.ss.decryptAndHash(msg).toHex(true)
    doAssert testloadstr == "4d757272617920526f746862617264", testloadstr
 
  # var s1payload = hs.ss.decryptAndHash(msg)
  # echo s1payload, " len: ", s1payload.len
  
  # -> s, se

  msg.setLen(0)

  write_s()
  dh_se()

  var payload = p2pProof.buffer
  echo payload, " len: ", payload.len
  payload = hs.ss.encryptAndHash(payload)

  await conn.writeLp(msg & payload)
  
  return hs.ss.split()

proc handshakeXXInbound(p: Noise, conn: Connection, p2pProof: ProtoBuffer): Future[tuple[cs1, cs2: CipherState]] {.async.} =
  var hs: HandshakeState
   
  init hs.ss
  const initiator = false
  when not defined(noise_test_vectors):
    hs.s.privateKey = p.noisePrivateKey
    hs.s.publicKey = p.noisePublicKey
  else:
    hs.s.privateKey = "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893".fromHex.intoCurve25519Key
    hs.s.publicKey = hs.s.privateKey.public()
  # the rest of keys in hs are empty/0

  # -> e

  var msg = await conn.readLp()

  read_e()

  when defined(noise_test_vectors):
    doAssert msg.toHex(true) == "4c756477696720766f6e204d69736573"

  # <- e, ee, s, es

  msg.setLen(0)

  write_e()
  dh_ee()
  write_s()
  dh_es()

  when defined(noise_test_vectors):
    var testload = "4d757272617920526f746862617264".fromHex
    msg &= hs.ss.encryptAndHash(testload)

  # var payload = p2pProof.buffer
  # echo payload, " len: ", payload.len
  # payload = hs.ss.encryptAndHash(payload)

  await conn.writeLp(msg)

  when defined(noise_test_vectors):
    doAssert msg.toHex(true) == "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884381cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9bd5269c2f1e4f488ed8831161f19b7815528f8982ffe09be9b5c412f8a0db50f8814c7194e83f23dbd8d162c9326ad"

  # -> s, se

  msg = await conn.readLp()

  read_s()
  dh_se()

  msg = hs.ss.decryptAndHash(msg)

  echo msg, " len: ", msg.len

  return hs.ss.split()

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
    (p.cs1, p.cs2) = await handshakeXXOutbound(p, conn, libp2pProofPb)
  else:
    (p.cs1, p.cs2) = await handshakeXXInbound(p, conn, libp2pProofPb)
  
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
    result = await p.handshake(conn, p.initiator)
  except CatchableError as ex:
     warn "securing connection failed", msg = ex.msg
     if not conn.closed():
       await conn.close()
  
proc newNoise*(privateKey: PrivateKey; initiator: bool): Noise =
  new result
  result.initiator = initiator
  result.localPrivateKey = privateKey
  result.localPublicKey = privateKey.getKey()
  discard randomBytes(result.noisePrivateKey)
  result.noisePublicKey = result.noisePrivateKey.public()
  result.init()
