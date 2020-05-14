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
import stew/[endians2, byteutils]
import nimcrypto/[utils, sysrand, sha2, hmac]
import ../../connection
import ../../peer
import ../../peerinfo
import ../../protobuf/minprotobuf
import ../../utility
import ../../stream/lpstream
import secure,
       ../../crypto/[crypto, chacha20poly1305, curve25519, hkdf],
       ../../stream/bufferstream

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
  NoiseSize = 32
  MaxPlainSize = int(uint16.high - NoiseSize - ChaChaPolyTag.len)

type
  KeyPair = object
    privateKey: Curve25519Key
    publicKey: Curve25519Key

  # https://noiseprotocol.org/noise.html#the-cipherstate-object
  CipherState = object
    k: ChaChaPolyKey
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
    outgoing: bool

  NoiseConnection* = ref object of SecureConn
    readCs: CipherState
    writeCs: CipherState

  NoiseHandshakeError* = object of CatchableError
  NoiseDecryptTagError* = object of CatchableError
  NoiseOversizedPayloadError* = object of CatchableError
  NoiseNonceMaxError* = object of CatchableError # drop connection on purpose

# Utility

proc genKeyPair(): KeyPair =
  result.privateKey = Curve25519Key.random()
  result.publicKey = result.privateKey.public()

proc hashProtocol(name: string): MDigest[256] =
  # If protocol_name is less than or equal to HASHLEN bytes in length,
  # sets h equal to protocol_name with zero bytes appended to make HASHLEN bytes.
  # Otherwise sets h = HASH(protocol_name).

  if name.len <= 32:
    result.data[0..name.high] = name.toBytes
  else:
    result = sha256.digest(name)

proc dh(priv: Curve25519Key, pub: Curve25519Key): Curve25519Key =
  Curve25519.mul(result, pub, priv)

# Cipherstate

proc hasKey(cs: CipherState): bool =
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
  if state.n > NonceMax:
    raise newException(NoiseNonceMaxError, "Noise max nonce value reached")
  result &= tag
  trace "encryptWithAd", tag = byteutils.toHex(tag), data = result.shortLog, nonce = state.n - 1

proc decryptWithAd(state: var CipherState, ad, data: openarray[byte]): seq[byte] =
  var
    tagIn = data[^ChaChaPolyTag.len..data.high].intoChaChaPolyTag
    tagOut = tagIn
    nonce: ChaChaPolyNonce
    np = cast[ptr uint64](addr nonce[4])
  np[] = state.n
  result = data[0..(data.high - ChaChaPolyTag.len)]
  ChaChaPoly.decrypt(state.k, nonce, tagOut, result, ad)
  trace "decryptWithAd", tagIn = tagIn.shortLog, tagOut = tagOut.shortLog, nonce = state.n
  if tagIn != tagOut:
    error "decryptWithAd failed", data = byteutils.toHex(data)
    raise newException(NoiseDecryptTagError, "decryptWithAd failed tag authentication.")
  inc state.n
  if state.n > NonceMax:
    raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

# Symmetricstate

proc init(_: type[SymmetricState]): SymmetricState =
  result.h = ProtocolXXName.hashProtocol
  result.ck = result.h.data.intoChaChaPolyKey
  result.cs = CipherState(k: EmptyKey)

proc mixKey(ss: var SymmetricState, ikm: ChaChaPolyKey) =
  var
    temp_keys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, ikm, [], temp_keys)
  ss.ck = temp_keys[0]
  ss.cs = CipherState(k: temp_keys[1])
  trace "mixKey", key = ss.cs.k.shortLog

proc mixHash(ss: var SymmetricState; data: openarray[byte]) =
  var ctx: sha256
  ctx.init()
  ctx.update(ss.h.data)
  ctx.update(data)
  ss.h = ctx.finish()
  trace "mixHash", hash = ss.h.data.shortLog

# We might use this for other handshake patterns/tokens
proc mixKeyAndHash(ss: var SymmetricState; ikm: openarray[byte]) {.used.} =
  var
    temp_keys: array[3, ChaChaPolyKey]
  sha256.hkdf(ss.ck, ikm, [], temp_keys)
  ss.ck = temp_keys[0]
  ss.mixHash(temp_keys[1])
  ss.cs = CipherState(k: temp_keys[2])

proc encryptAndHash(ss: var SymmetricState, data: openarray[byte]): seq[byte] =
  # according to spec if key is empty leave plaintext
  if ss.cs.hasKey:
    result = ss.cs.encryptWithAd(ss.h.data, data)
  else:
    result = @data
  ss.mixHash(result)

proc decryptAndHash(ss: var SymmetricState, data: openarray[byte]): seq[byte] =
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
  return (CipherState(k: temp_keys[0]), CipherState(k: temp_keys[1]))

proc init(_: type[HandshakeState]): HandshakeState =
  result.ss = SymmetricState.init()

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

# might be used for other token/handshakes
template dh_ss: untyped {.used.} =
  trace "noise dh ss"
  # Calls MixKey(DH(s, rs)).
  hs.ss.mixKey(dh(hs.s.privateKey, hs.rs))

template read_e: untyped =
  trace "noise read e", size = msg.len

  if msg.len < Curve25519Key.len:
    raise newException(NoiseHandshakeError, "Noise E, expected more data")

  # Sets re (which must be empty) to the next DHLEN bytes from the message. Calls MixHash(re.public_key).
  hs.re[0..Curve25519Key.high] = msg[0..Curve25519Key.high]
  msg = msg[Curve25519Key.len..msg.high]
  hs.ss.mixHash(hs.re)

template read_s: untyped =
  trace "noise read s", size = msg.len
  # Sets temp to the next DHLEN + 16 bytes of the message if HasKey() == True, or to the next DHLEN bytes otherwise.
  # Sets rs (which must be empty) to DecryptAndHash(temp).
  let
    temp =
      if hs.ss.cs.hasKey:
        if msg.len < Curve25519Key.len + ChaChaPolyTag.len:
          raise newException(NoiseHandshakeError, "Noise S, expected more data")
        msg[0..Curve25519Key.high + ChaChaPolyTag.len]
      else:
        if msg.len < Curve25519Key.len:
          raise newException(NoiseHandshakeError, "Noise S, expected more data")
        msg[0..Curve25519Key.high]
  msg = msg[temp.len..msg.high]
  let plain = hs.ss.decryptAndHash(temp)
  hs.rs[0..Curve25519Key.high] = plain

proc receiveHSMessage(sconn: Connection): Future[seq[byte]] {.async.} =
  var besize: array[2, byte]
  await sconn.stream.readExactly(addr besize[0], besize.len)
  let size = uint16.fromBytesBE(besize).int
  trace "receiveHSMessage", size
  var buffer = newSeq[byte](size)
  if buffer.len > 0:
    await sconn.stream.readExactly(addr buffer[0], buffer.len)
  return buffer

proc sendHSMessage(sconn: Connection; buf: seq[byte]) {.async.} =
  var
    lesize = buf.len.uint16
    besize = lesize.toBytesBE
    outbuf = newSeqOfCap[byte](besize.len + buf.len)
  trace "sendHSMessage", size = lesize
  outbuf &= besize
  outbuf &= buf
  await sconn.write(outbuf)

proc packNoisePayload(payload: openarray[byte]): seq[byte] =
  var
    ns: uint32
  if randomBytes(addr ns, 4) != 4:
    raise newException(NoiseHandshakeError, "Failed to generate randomBytes")

  let
    noiselen = int((ns mod (NoiseSize - 2)) + 1)
    plen = payload.len.uint16

  var
    noise = newSeq[byte](noiselen)
  if randomBytes(noise) != noiselen:
    raise newException(NoiseHandshakeError, "Failed to generate randomBytes")

  result &= plen.toBytesBE
  result &= payload
  result &= noise

  if result.len > uint16.high.int:
    raise newException(NoiseOversizedPayloadError, "Trying to send an unsupported oversized payload over Noise")

  trace "packed noise payload", inSize = payload.len, outSize = result.len

proc unpackNoisePayload(payload: var seq[byte]) =
  let
    besize = payload[0..1]
    size = uint16.fromBytesBE(besize).int

  if size > (payload.len - 2):
    raise newException(NoiseOversizedPayloadError, "Received a wrong payload size")

  payload = payload[2..^((payload.len - size) - 1)]

  trace "unpacked noise payload", size = payload.len

proc handshakeXXOutbound(p: Noise, conn: Connection, p2pProof: ProtoBuffer): Future[HandshakeResult] {.async.} =
  const initiator = true

  var
    hs = HandshakeState.init()
    p2psecret = p2pProof.buffer

  hs.ss.mixHash(p.commonPrologue)
  hs.s.privateKey = p.noisePrivateKey
  hs.s.publicKey = p.noisePublicKey

  # -> e
  var msg: seq[byte]

  write_e()

  # IK might use this btw!
  msg &= hs.ss.encryptAndHash(@[])

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
    hs = HandshakeState.init()
    p2psecret = p2pProof.buffer

  hs.ss.mixHash(p.commonPrologue)
  hs.s.privateKey = p.noisePrivateKey
  hs.s.publicKey = p.noisePublicKey

  # -> e

  var msg = await conn.receiveHSMessage()

  read_e()

  # we might use this early data one day, keeping it here for clarity
  let earlyData {.used.} = hs.ss.decryptAndHash(msg)

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

method readMessage*(sconn: NoiseConnection): Future[seq[byte]] {.async.} =
  while true: # Discard 0-length payloads
    var besize: array[2, byte]
    await sconn.stream.readExactly(addr besize[0], besize.len)
    let size = uint16.fromBytesBE(besize).int # Cannot overflow
    trace "receiveEncryptedMessage", size, peer = $sconn.peerInfo
    if size > 0:
      var buffer = newSeq[byte](size)
      await sconn.stream.readExactly(addr buffer[0], buffer.len)
      var plain = sconn.readCs.decryptWithAd([], buffer)
      unpackNoisePayload(plain)
      return plain
    else:
      trace "Received 0-length message", conn = $sconn

method write*(sconn: NoiseConnection, message: seq[byte]): Future[void] {.async.} =
  if message.len == 0:
    return

  try:
    var
      left = message.len
      offset = 0
    while left > 0:
      let
        chunkSize = if left > MaxPlainSize: MaxPlainSize else: left
        packed = packNoisePayload(message.toOpenArray(offset, offset + chunkSize - 1))
        cipher = sconn.writeCs.encryptWithAd([], packed)
      left = left - chunkSize
      offset = offset + chunkSize
      var
        lesize = cipher.len.uint16
        besize = lesize.toBytesBE
        outbuf = newSeqOfCap[byte](cipher.len + 2)
      trace "sendEncryptedMessage", size = lesize, peer = $sconn.peerInfo, left, offset
      outbuf &= besize
      outbuf &= cipher
      await sconn.stream.write(outbuf)
  except LPStreamEOFError:
    trace "Ignoring EOF while writing"
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    # TODO these exceptions are ignored since it's likely that if writes are
    #      are failing, the underlying connection is already closed - this needs
    #      more cleanup though
    debug "Could not write to connection", msg = exc.msg

method handshake*(p: Noise, conn: Connection, initiator: bool = false): Future[SecureConn] {.async.} =
  trace "Starting Noise handshake", initiator

  # https://github.com/libp2p/specs/tree/master/noise#libp2p-data-in-handshake-messages
  let
    signedPayload = p.localPrivateKey.sign(PayloadString.toBytes & p.noisePublicKey.getBytes)

  var
    libp2pProof = initProtoBuffer()

  libp2pProof.write(initProtoField(1, p.localPublicKey))
  libp2pProof.write(initProtoField(2, signedPayload))
  # data field also there but not used!
  libp2pProof.finish()

  let handshakeRes =
    if initiator:
      await handshakeXXOutbound(p, conn, libp2pProof)
    else:
      await handshakeXXInbound(p, conn, libp2pProof)

  var
    remoteProof = initProtoBuffer(handshakeRes.remoteP2psecret)
    remotePubKey: PublicKey
    remoteSig: Signature
  if remoteProof.getValue(1, remotePubKey) <= 0:
    raise newException(NoiseHandshakeError, "Failed to deserialize remote public key.")
  if remoteProof.getValue(2, remoteSig) <= 0:
    raise newException(NoiseHandshakeError, "Failed to deserialize remote public key.")

  let verifyPayload = PayloadString.toBytes & handshakeRes.rs.getBytes
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
  inc getConnectionTracker().opened
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
  procCall Secure(p).init()
  p.codec = NoiseCodec

proc newNoise*(privateKey: PrivateKey; outgoing: bool = true; commonPrologue: seq[byte] = @[]): Noise =
  new result
  result.outgoing = outgoing
  result.localPrivateKey = privateKey
  result.localPublicKey = privateKey.getKey()
  discard randomBytes(result.noisePrivateKey)
  result.noisePublicKey = result.noisePrivateKey.public()
  result.commonPrologue = commonPrologue
  result.init()
