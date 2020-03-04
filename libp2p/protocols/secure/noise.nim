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
import random
import stew/endians2
import nimcrypto/[utils, sysrand, sha2, hmac]
import ../../connection
import ../../peer
import ../../peerinfo
import ../../protobuf/minprotobuf
import secure,
       ../../crypto/[crypto, chacha20poly1305, curve25519, hkdf],
       ../../stream/bufferstream

template unimplemented: untyped =
  doAssert(false, "Not implemented")

logScope:
  topic = "Noise"

const
  # https://godoc.org/github.com/libp2p/go-libp2p-noise#pkg-constants
  NoiseCodec* = "/noise"
  
  PayloadString = "noise-libp2p-static-key:"

  ProtocolXXName = "Noise_XX_25519_ChaChaPoly_SHA256"

  # Empty is a special value which indicates k has not yet been initialized.
  EmptyKey: ChaChaPolyKey = [0.byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  NonceMax = uint64.high - 1 # max is reserved
                             #
  NoiseMessageMax = 65535

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

  HandshakeResult = object
    cs1: CipherState
    cs2: CipherState
    remoteP2psecret: seq[byte]
    rs: Curve25519Key
  
  Noise* = ref object of Secure
    localPrivateKey: PrivateKey
    localPublicKey: PublicKey
    noisePrivateKey: Curve25519Key
    noisePublicKey: Curve25519Key
    commonPrologue: seq[byte]

  NoiseConnection* = ref object of SecureConnection
    readCs: CipherState
    writeCs: CipherState

  NoiseHandshakeError* = object of CatchableError
  NoiseDecryptTagError* = object of CatchableError
  NoiseOversizedPayloadError* = object of CatchableError

# Utility

proc genKeyPair(): KeyPair =
  result.privateKey = Curve25519Key.random()
  result.publicKey = result.privateKey.public()
    
# todo this should be exposed maybe or replaced with a more public version
proc getBytes*(key: string): seq[byte] =
  result.setLen(key.len)
  copyMem(addr result[0], unsafeaddr key[0], key.len)

proc hashProtocol(name: string): MDigest[256] =
  # If protocol_name is less than or equal to HASHLEN bytes in length,
  # sets h equal to protocol_name with zero bytes appended to make HASHLEN bytes.
  # Otherwise sets h = HASH(protocol_name).

  if name.len <= 32:
    copyMem(addr result.data[0], unsafeAddr name[0], name.len)
  else:
    result = sha256.digest(name)

proc dh(priv: Curve25519Key, pub: Curve25519Key): Curve25519Key =
  Curve25519.mul(result, pub, priv)

# Cipherstate

proc init(cs: var CipherState; key: ChaChaPolyKey) =
  cs.k = key
  cs.n = 0

proc hasKey(cs: var CipherState): bool =
  cs.k != EmptyKey

proc encryptWithAd(state: var CipherState, ad, data: openarray[byte]): seq[byte] =
  var
    tag: ChaChaPolyTag
    nonce: ChaChaPolyNonce
    np = cast[ptr uint64](addr nonce[4])
  np[] = state.n
  result = @data
  ChaChaPoly.encrypt(state.k, nonce, tag, result, ad)
  inc state.n
  result &= tag
  trace "encryptWithAd", tag = tag.toHex

proc decryptWithAd(state: var CipherState, ad, data: openarray[byte]): seq[byte] =
  var
    tagIn = data[^ChaChaPolyTag.len..data.high].intoChaChaPolyTag
    tagOut = tagIn
    nonce: ChaChaPolyNonce
    np = cast[ptr uint64](addr nonce[4])
  np[] = state.n
  result = data[0..(data.high - ChaChaPolyTag.len)]
  ChaChaPoly.decrypt(state.k, nonce, tagOut, result, ad)
  trace "decryptWithAd", tagIn = tagIn.toHex, tagOut=tagOut.toHex
  if tagIn != tagOut:
    raise newException(NoiseDecryptTagError, "decryptWithAd failed tag authentication.")
  inc state.n

# Symmetricstate

proc init(ss: var SymmetricState) =
  ss.h = ProtocolXXName.hashProtocol
  ss.ck = ss.h.data.intoChaChaPolyKey
  init ss.cs, EmptyKey

proc mixKey(ss: var SymmetricState, ikm: ChaChaPolyKey) =
  var
    temp_keys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, ikm, [], temp_keys)
  ss.ck = temp_keys[0]
  init ss.cs, temp_keys[1]
  trace "mixKey", key = ss.cs.k

proc mixHash(ss: var SymmetricState; data: openarray[byte]) =
  var ctx: sha256
  ctx.init()
  ctx.update(ss.h.data)
  ctx.update(data)
  ss.h = ctx.finish()
  trace "mixHash", hash = ss.h.data

proc mixKeyAndHash(ss: var SymmetricState; ikm: var openarray[byte]) =
  var
    temp_keys: array[3, ChaChaPolyKey]
  sha256.hkdf(ss.ck, ikm, [], temp_keys)
  ss.ck = temp_keys[0]
  ss.mixHash(temp_keys[1])
  init ss.cs, temp_keys[2]

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
  ss.mixHash(data)

proc split(ss: var SymmetricState): tuple[cs1, cs2: CipherState] =
  var
    temp_keys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, [], [], temp_keys)
  init result.cs1, temp_keys[0]
  init result.cs2, temp_keys[1]
  
template write_e: untyped =
  trace "noise write e"
  # Sets e (which must be empty) to GENERATE_KEYPAIR(). Appends e.public_key to the buffer. Calls MixHash(e.public_key).
  hs.e = genKeyPair()
  msg &= hs.e.publicKey
  hs.ss.mixHash(hs.e.publicKey)

template write_s: untyped =
  trace "noise write s"
  # Appends EncryptAndHash(s.public_key) to the buffer.
  msg &= hs.ss.encryptAndHash(hs.s.publicKey)

template dh_ee: untyped =
  trace "noise dh ee"
  # Calls MixKey(DH(e, re)).
  hs.ss.mixKey(dh(hs.e.privateKey, hs.re))

template dh_es: untyped =
  trace "noise dh es"
  # Calls MixKey(DH(e, rs)) if initiator, MixKey(DH(s, re)) if responder.
  when initiator:
    hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))
  else:
    hs.ss.mixKey(dh(hs.s.privateKey, hs.re))

template dh_se: untyped =
  trace "noise dh se"
  # Calls MixKey(DH(s, re)) if initiator, MixKey(DH(e, rs)) if responder.
  when initiator:
    hs.ss.mixKey(dh(hs.s.privateKey, hs.re))
  else:
    hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))

template dh_ss: untyped =
  trace "noise dh ss"
  # Calls MixKey(DH(s, rs)).
  hs.ss.mixKey(dh(hs.s.privateKey, hs.rs))

template read_e: untyped =
  trace "noise read e", size = msg.len

  if msg.len < Curve25519Key.len:
    raise newException(NoiseHandshakeError, "Noise E, expected more data")

  # Sets re (which must be empty) to the next DHLEN bytes from the message. Calls MixHash(re.public_key).
  copyMem(addr hs.re[0], addr msg[0], Curve25519Key.len)
  msg = msg[Curve25519Key.len..msg.high]
  hs.ss.mixHash(hs.re)

template read_s: untyped =
  trace "noise read s", size = msg.len
  # Sets temp to the next DHLEN + 16 bytes of the message if HasKey() == True, or to the next DHLEN bytes otherwise.
  # Sets rs (which must be empty) to DecryptAndHash(temp).
  var temp: seq[byte]
  if hs.ss.cs.hasKey:
    if msg.len < Curve25519Key.len + ChaChaPolyTag.len:
      raise newException(NoiseHandshakeError, "Noise S, expected more data")
   
    temp.setLen(Curve25519Key.len + 16)
    copyMem(addr temp[0], addr msg[0], Curve25519Key.len + 16)
    msg = msg[Curve25519Key.len + 16..msg.high]
  else:
    if msg.len < Curve25519Key.len:
      raise newException(NoiseHandshakeError, "Noise S, expected more data")

    temp.setLen(Curve25519Key.len)
    copyMem(addr temp[0], addr msg[0], Curve25519Key.len)
    msg = msg[Curve25519Key.len..msg.high]
  var plain = hs.ss.decryptAndHash(temp)
  copyMem(addr hs.rs[0], addr plain[0], Curve25519Key.len)

proc receiveHSMessage(sconn: Connection): Future[seq[byte]] {.async.} =
  var besize: array[2, byte]
  await sconn.readExactly(addr besize[0], 2)
  let size = uint16.fromBytesBE(besize).int
  trace "receiveHSMessage", size
  return await sconn.read(size)

proc sendHSMessage(sconn: Connection; buf: seq[byte]) {.async.} =
  var
    lesize = buf.len.uint16
    besize = lesize.toBytesBE
  trace "sendHSMessage", size = lesize
  await sconn.write(besize[0].addr, besize.len)
  await sconn.write(buf)

proc packNoisePayload(payload: openarray[byte]): seq[byte] {.inline.} =
  if payload.len > uint16.high.int:
    raise newException(NoiseOversizedPayloadError, "Trying to send an unsupported oversized payload over Noise")

  let
    noiselen = rand(2..31)

  var
    plen = payload.len.uint16
    noise = newSeq[byte](noiselen)

  if randomBytes(noise) != noiselen:
    raise newException(NoiseHandshakeError, "Failed to generate randomBytes")

  result &= plen.toBytesBE
  result &= payload
  result &= noise

  trace "packed noise payload", inSize = payload.len, outSize = result.len

proc unpackNoisePayload(payload: var seq[byte]) {.inline.} =
  var
    besize = payload[0..1]
    size = uint16.fromBytesBE(besize).int
  payload = payload[2..^((payload.len - size) - 1)]

  trace "unpacked noise payload", size = payload.len

proc receiveEncryptedMessage(sconn: NoiseConnection): Future[seq[byte]] {.async.} =
  var besize: array[2, byte]
  await sconn.readExactly(addr besize[0], 2)
  let size = uint16.fromBytesBE(besize).int
  trace "receiveEncryptedMessage", size, peer = $sconn.peerInfo
  if size == 0:
    return @[]
  let
    cipher = await sconn.read(size)
  var plain = sconn.readCs.decryptWithAd([], cipher)
  unpackNoisePayload(plain)
  return plain

proc sendEncryptedMessage(sconn: NoiseConnection; buf: seq[byte]) {.async.} =
  let
    packed = packNoisePayload(buf)
    cipher = sconn.writeCs.encryptWithAd([], packed)
  var
    lesize = cipher.len.uint16
    besize = lesize.toBytesBE
  trace "sendEncryptedMessage", size = lesize, peer = $sconn.peerInfo
  await sconn.write(addr besize[0], 2)
  await sconn.write(cipher)
  
proc handshakeXXOutbound(p: Noise, conn: Connection, p2pProof: ProtoBuffer): Future[HandshakeResult] {.async.} =
  const initiator = true

  var
    hs: HandshakeState
    empty: seq[byte]
  init hs.ss

  var p2psecret = p2pProof.buffer

  hs.ss.mixHash(p.commonPrologue)
  hs.s.privateKey = p.noisePrivateKey
  hs.s.publicKey = p.noisePublicKey

  # -> e
  var msg: seq[byte]

  write_e()

  # IK might use this btw!
  msg &= hs.ss.encryptAndHash(empty)

  await conn.sendHSMessage(msg)

  # <- e, ee, s, es

  msg = await conn.receiveHSMessage()

  read_e()
  dh_ee()
  read_s()
  dh_es()

  var remoteP2psecret = hs.ss.decryptAndHash(msg)
  unpackNoisePayload(remoteP2psecret)

  # -> s, se

  msg.setLen(0)

  write_s()
  dh_se()

  # last payload must follow the ecrypted way of sending
  var packed = packNoisePayload(p2psecret)
  msg &= hs.ss.encryptAndHash(packed)

  await conn.sendHSMessage(msg)
  
  let (cs1, cs2) = hs.ss.split()
  return HandshakeResult(cs1: cs1, cs2: cs2, remoteP2psecret: remoteP2psecret, rs: hs.rs)

proc handshakeXXInbound(p: Noise, conn: Connection, p2pProof: ProtoBuffer): Future[HandshakeResult] {.async.} =
  const initiator = false

  var
    hs: HandshakeState
    empty: seq[byte]
  init hs.ss

  var p2psecret = p2pProof.buffer

  hs.ss.mixHash(p.commonPrologue)
  hs.s.privateKey = p.noisePrivateKey
  hs.s.publicKey = p.noisePublicKey

  # -> e

  var msg = await conn.receiveHSMessage()

  read_e()

  let earlyData = hs.ss.decryptAndHash(msg)

  # <- e, ee, s, es

  msg.setLen(0)

  write_e()
  dh_ee()
  write_s()
  dh_es()

  var packedSecret = packNoisePayload(p2psecret)
  msg &= hs.ss.encryptAndHash(packedSecret)

  await conn.sendHSMessage(msg)

  # -> s, se

  msg = await conn.receiveHSMessage()

  read_s()
  dh_se()

  var remoteP2psecret = hs.ss.decryptAndHash(msg)
  unpackNoisePayload(remoteP2psecret)

  let (cs1, cs2) = hs.ss.split()
  return HandshakeResult(cs1: cs1, cs2: cs2, remoteP2psecret: remoteP2psecret, rs: hs.rs)

proc readMessage(sconn: NoiseConnection): Future[seq[byte]] =
  try:
    return sconn.receiveEncryptedMessage()
  except AsyncStreamIncompleteError:
    trace "Connection dropped while reading"
  except AsyncStreamReadError:
    trace "Error reading from connection"

proc writeMessage(sconn: NoiseConnection, message: seq[byte]): Future[void] =
  try:
    return sconn.sendEncryptedMessage(message)
  except AsyncStreamWriteError:
    trace "Could not write to connection"

proc startLifetime*(sconn: NoiseConnection): Future[Connection] {.async.} =
  proc writeHandler(data: seq[byte]) {.async, gcsafe.} =
    trace "sending encrypted bytes", bytes = data.toHex()
    await sconn.writeMessage(data)

  var stream = newBufferStream(writeHandler)
  asyncCheck readLoop(sconn, stream)
  result = newConnection(stream)
  result.closeEvent.wait().addCallback do (udata: pointer):
    trace "wrapped connection closed, closing upstream"
    if not isNil(sconn) and not sconn.closed:
      asyncCheck sconn.close()

proc handshake*(p: Noise, conn: Connection, initiator: bool): Future[NoiseConnection] {.async.} =
  trace "Starting Noise handshake", initiator

  # https://github.com/libp2p/specs/tree/master/noise#libp2p-data-in-handshake-messages
  let
    signedPayload = p.localPrivateKey.sign(PayloadString.getBytes & p.noisePublicKey.getBytes)
    
  var
    libp2pProof = initProtoBuffer()
    handshakeRes: HandshakeResult

  libp2pProof.write(initProtoField(1, p.localPublicKey))
  libp2pProof.write(initProtoField(2, signedPayload))
  # data field also there but not used!
  libp2pProof.finish()

  if initiator:
    handshakeRes = await handshakeXXOutbound(p, conn, libp2pProof)
  else:
    handshakeRes = await handshakeXXInbound(p, conn, libp2pProof)

  var
    remoteProof = initProtoBuffer(handshakeRes.remoteP2psecret)
    remotePubKey: PublicKey
    remoteSig: Signature
  if remoteProof.getValue(1, remotePubKey) <= 0:
    raise newException(NoiseHandshakeError, "Failed to deserialize remote public key.")
  if remoteProof.getValue(2, remoteSig) <= 0:
    raise newException(NoiseHandshakeError, "Failed to deserialize remote public key.")

  let verifyPayload = PayloadString.getBytes & handshakeRes.rs.getBytes
  if not remoteSig.verify(verifyPayload, remotePubKey):
    raise newException(NoiseHandshakeError, "Noise handshake signature verify failed.")
  else:
    trace "Remote signature verified"
 
  if initiator and not isNil(conn.peerInfo):
    let pid = PeerID.init(remotePubKey)
    if not conn.peerInfo.peerId.validate():
      raise newException(NoiseHandshakeError, "Failed to validate peerId.")
    if pid != conn.peerInfo.peerId:
      raise newException(NoiseHandshakeError, "Noise handshake, peer infos don't match! " & $pid & " != " & $conn.peerInfo.peerId)

  var secure = new NoiseConnection
  secure.stream = conn
  secure.closeEvent = newAsyncEvent()
  secure.peerInfo = PeerInfo.init(remotePubKey)
  if initiator:
    secure.readCs = handshakeRes.cs2
    secure.writeCs = handshakeRes.cs1
  else:
    secure.readCs = handshakeRes.cs1
    secure.writeCs = handshakeRes.cs2

  trace "Noise handshake completed!"

  return secure
 
method init*(p: Noise) {.gcsafe.} =
  trace "Noise init called"
 
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    trace "handling connection", proto
    try:
      let
        sconn = await p.handshake(conn, false)
      asyncCheck sconn.startLifetime()
      trace "connection secured"
    except CatchableError as ex:
      if not conn.closed():
        warn "securing connection failed", msg = ex.msg
        await conn.close()

  p.codec = NoiseCodec
  p.handler = handle
  
method secure*(p: Noise, conn: Connection, outgoing: bool): Future[Connection] {.async, gcsafe.} =
  try:
    let
      sconn = await p.handshake(conn, outgoing)
      securedStream = await sconn.startLifetime()
    securedStream.peerInfo = sconn.peerInfo
    return securedStream
  except CatchableError as ex:
     warn "securing connection failed", msg = ex.msg
     if not conn.closed():
       await conn.close()
  
proc newNoise*(privateKey: PrivateKey; commonPrologue: seq[byte] = @[]): Noise =
  new result
  result.localPrivateKey = privateKey
  result.localPublicKey = privateKey.getKey()
  discard randomBytes(result.noisePrivateKey)
  result.noisePublicKey = result.noisePrivateKey.public()
  result.commonPrologue = commonPrologue
  result.init()
