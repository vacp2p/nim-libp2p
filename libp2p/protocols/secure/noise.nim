# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/strformat
import chronos
import chronicles
import bearssl/[rand, hash]
import stew/[endians2, byteutils]
import nimcrypto/[utils, sha2, hmac]
import ../../stream/[connection]
import ../../peerid
import ../../peerinfo
import ../../protobuf/minprotobuf
import ../../utility
import ../../utils/[bytesview, sequninit]

import secure, ../../crypto/[crypto, chacha20poly1305, curve25519, hkdf]

when defined(libp2p_dump):
  import ../../debugutils

logScope:
  topics = "libp2p noise"

const
  # https://godoc.org/github.com/libp2p/go-libp2p-noise#pkg-constants
  NoiseCodec* = "/noise"

  PayloadString = toBytes("noise-libp2p-static-key:")

  ProtocolXXName = "Noise_XX_25519_ChaChaPoly_SHA256"

  # Empty is a special value which indicates k has not yet been initialized.
  EmptyKey = default(ChaChaPolyKey)
  NonceMax = uint64.high - 1 # max is reserved
  NoiseSize = 32
  MaxPlainSize = int(uint16.high - NoiseSize - ChaChaPolyTag.len)

  HandshakeTimeout = 1.minutes

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
    rng: ref HmacDrbgContext
    localPrivateKey: PrivateKey
    localPublicKey: seq[byte]
    noiseKeys: KeyPair
    commonPrologue: seq[byte]
    outgoing: bool

  NoiseConnection* = ref object of SecureConn
    readCs: CipherState
    writeCs: CipherState

  NoiseError* = object of LPStreamError
  NoiseHandshakeError* = object of NoiseError
  NoiseDecryptTagError* = object of NoiseError
  NoiseOversizedPayloadError* = object of NoiseError
  NoiseNonceMaxError* = object of NoiseError # drop connection on purpose

# Utility

func shortLog*(conn: NoiseConnection): auto =
  try:
    if conn == nil:
      "NoiseConnection(nil)"
    else:
      &"{shortLog(conn.peerId)}:{conn.oid}"
  except ValueError as exc:
    raiseAssert(exc.msg)

chronicles.formatIt(NoiseConnection):
  shortLog(it)

proc genKeyPair(rng: var HmacDrbgContext): KeyPair =
  result.privateKey = Curve25519Key.random(rng)
  result.publicKey = result.privateKey.public()

proc hashProtocol(name: string): MDigest[256] =
  # If protocol_name is less than or equal to HASHLEN bytes in length,
  # sets h to protocol_name with zero bytes appended to make HASHLEN bytes.
  # Otherwise sets h = HASH(protocol_name).

  if name.len <= 32:
    result.data[0 .. name.high] = name.toBytes
  else:
    result = sha256.digest(name)

proc dh(priv: Curve25519Key, pub: Curve25519Key): Curve25519Key =
  result = pub
  Curve25519.mul(result, priv)

# Cipherstate

proc hasKey(cs: CipherState): bool =
  cs.k != EmptyKey

proc encrypt(
    state: var CipherState, data: var openArray[byte], ad: openArray[byte]
): ChaChaPolyTag {.noinit, raises: [NoiseNonceMaxError].} =
  var nonce: ChaChaPolyNonce
  nonce[4 ..< 12] = toBytesLE(state.n)

  ChaChaPoly.encrypt(state.k, nonce, result, data, ad)

  inc state.n
  if state.n > NonceMax:
    raise (ref NoiseNonceMaxError)(msg: "Noise max nonce value reached")

proc encryptWithAd(
    state: var CipherState, ad, data: openArray[byte]
): seq[byte] {.raises: [NoiseNonceMaxError].} =
  result = newSeqOfCap[byte](data.len + sizeof(ChaChaPolyTag))
  result.add(data)

  let tag = encrypt(state, result, ad)

  result.add(tag)

  trace "encryptWithAd",
    tag = byteutils.toHex(tag), data = result.shortLog, nonce = state.n - 1

proc decryptWithAd(
    state: var CipherState, ad, data: openArray[byte]
): seq[byte] {.raises: [NoiseDecryptTagError, NoiseNonceMaxError].} =
  var
    tagIn = data.toOpenArray(data.len - ChaChaPolyTag.len, data.high).intoChaChaPolyTag
    tagOut: ChaChaPolyTag
    nonce: ChaChaPolyNonce
  nonce[4 ..< 12] = toBytesLE(state.n)
  result = data[0 .. (data.high - ChaChaPolyTag.len)]
  ChaChaPoly.decrypt(state.k, nonce, tagOut, result, ad)
  trace "decryptWithAd",
    tagIn = tagIn.shortLog, tagOut = tagOut.shortLog, nonce = state.n
  if tagIn != tagOut:
    debug "decryptWithAd failed", data = shortLog(data)
    raise (ref NoiseDecryptTagError)(msg: "decryptWithAd failed tag authentication.")
  inc state.n
  if state.n > NonceMax:
    raise (ref NoiseNonceMaxError)(msg: "Noise max nonce value reached")

# Symmetricstate

proc init(_: type[SymmetricState]): SymmetricState =
  result.h = ProtocolXXName.hashProtocol
  result.ck = result.h.data.intoChaChaPolyKey
  result.cs = CipherState(k: EmptyKey)

proc mixKey(ss: var SymmetricState, ikm: ChaChaPolyKey) =
  var temp_keys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, ikm, [], temp_keys)
  ss.ck = temp_keys[0]
  ss.cs = CipherState(k: temp_keys[1])
  trace "mixKey", key = ss.cs.k.shortLog

proc mixHash(ss: var SymmetricState, data: openArray[byte]) =
  var ctx: sha256
  ctx.init()
  ctx.update(ss.h.data)
  ctx.update(data)
  ss.h = ctx.finish()
  trace "mixHash", hash = ss.h.data.shortLog

# We might use this for other handshake patterns/tokens
proc mixKeyAndHash(ss: var SymmetricState, ikm: openArray[byte]) {.used.} =
  var temp_keys: array[3, ChaChaPolyKey]
  sha256.hkdf(ss.ck, ikm, [], temp_keys)
  ss.ck = temp_keys[0]
  ss.mixHash(temp_keys[1])
  ss.cs = CipherState(k: temp_keys[2])

proc encryptAndHash(
    ss: var SymmetricState, data: openArray[byte]
): seq[byte] {.raises: [NoiseNonceMaxError].} =
  # according to spec if key is empty leave plaintext
  if ss.cs.hasKey:
    result = ss.cs.encryptWithAd(ss.h.data, data)
  else:
    result = @data
  ss.mixHash(result)

proc decryptAndHash(
    ss: var SymmetricState, data: openArray[byte]
): seq[byte] {.raises: [NoiseDecryptTagError, NoiseNonceMaxError].} =
  # according to spec if key is empty leave plaintext
  if ss.cs.hasKey and data.len > ChaChaPolyTag.len:
    result = ss.cs.decryptWithAd(ss.h.data, data)
  else:
    result = @data
  ss.mixHash(data)

proc split(ss: var SymmetricState): tuple[cs1, cs2: CipherState] =
  var temp_keys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, [], [], temp_keys)
  return (CipherState(k: temp_keys[0]), CipherState(k: temp_keys[1]))

proc init(_: type[HandshakeState]): HandshakeState =
  result.ss = SymmetricState.init()

template write_e(): untyped =
  trace "noise write e"
  # Sets e (which must be empty) to GENERATE_KEYPAIR().
  # Appends e.public_key to the buffer. Calls MixHash(e.public_key).
  hs.e = genKeyPair(p.rng[])
  hs.ss.mixHash(hs.e.publicKey)

  hs.e.publicKey.getBytes

template write_s(): untyped =
  trace "noise write s"
  # Appends EncryptAndHash(s.public_key) to the buffer.
  hs.ss.encryptAndHash(hs.s.publicKey)

template dh_ee(): untyped =
  trace "noise dh ee"
  # Calls MixKey(DH(e, re)).
  hs.ss.mixKey(dh(hs.e.privateKey, hs.re))

template dh_es(): untyped =
  trace "noise dh es"
  # Calls MixKey(DH(e, rs)) if initiator, MixKey(DH(s, re)) if responder.
  when initiator:
    hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))
  else:
    hs.ss.mixKey(dh(hs.s.privateKey, hs.re))

template dh_se(): untyped =
  trace "noise dh se"
  # Calls MixKey(DH(s, re)) if initiator, MixKey(DH(e, rs)) if responder.
  when initiator:
    hs.ss.mixKey(dh(hs.s.privateKey, hs.re))
  else:
    hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))

# might be used for other token/handshakes
template dh_ss(): untyped {.used.} =
  trace "noise dh ss"
  # Calls MixKey(DH(s, rs)).
  hs.ss.mixKey(dh(hs.s.privateKey, hs.rs))

template read_e(): untyped =
  trace "noise read e", size = msg.len

  if msg.len < Curve25519Key.len:
    raise (ref NoiseHandshakeError)(msg: "Noise E, expected more data")

  # Sets re (which must be empty) to the next DHLEN bytes from the message.
  # Calls MixHash(re.public_key).
  hs.re[0 .. Curve25519Key.high] = msg.toOpenArray(0, Curve25519Key.high)
  hs.ss.mixHash(hs.re)

  Curve25519Key.len

template read_s(): untyped =
  trace "noise read s", size = msg.len
  # Sets temp to the next DHLEN + 16 bytes of the message if HasKey() == True,
  # or to the next DHLEN bytes otherwise.
  # Sets rs (which must be empty) to DecryptAndHash(temp).
  let rsLen =
    if hs.ss.cs.hasKey:
      if msg.len < Curve25519Key.len + ChaChaPolyTag.len:
        raise (ref NoiseHandshakeError)(msg: "Noise S, expected more data")
      Curve25519Key.len + ChaChaPolyTag.len
    else:
      if msg.len < Curve25519Key.len:
        raise (ref NoiseHandshakeError)(msg: "Noise S, expected more data")
      Curve25519Key.len
  hs.rs[0 .. Curve25519Key.high] = hs.ss.decryptAndHash(msg.toOpenArray(0, rsLen - 1))

  rsLen

proc readFrame(
    sconn: Connection
): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]).} =
  var besize {.noinit.}: array[2, byte]
  await sconn.readExactly(addr besize[0], besize.len)
  let size = uint16.fromBytesBE(besize).int
  trace "readFrame", sconn, size
  if size == 0:
    return

  var buffer = newSeqUninit[byte](size)
  await sconn.readExactly(addr buffer[0], buffer.len)
  return buffer

proc receiveHSMessage(
    sconn: Connection
): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  readFrame(sconn)

template sendHSMessage(sconn: Connection, parts: varargs[seq[byte]]): untyped =
  # sends message (message frame) using multiple seq[byte] that 
  # concatenated represent entire mesage.

  var msgSize: int
  for p in parts:
    msgSize += p.len

  trace "sendHSMessage", sconn, size = msgSize
  doAssert msgSize <= uint16.high.int

  await sconn.write(@(msgSize.uint16.toBytesBE))
  for p in parts:
    await sconn.write(p)

proc handshakeXXOutbound(
    p: Noise, conn: Connection, p2pSecret: seq[byte]
): Future[HandshakeResult] {.async: (raises: [CancelledError, LPStreamError]).} =
  const initiator = true
  var hs = HandshakeState.init()

  try:
    hs.ss.mixHash(p.commonPrologue)
    hs.s = p.noiseKeys
    var remoteP2psecret: seq[byte]

    block: # -> e
      let ebytes = write_e()
      # IK might use this btw!
      let hbytes = hs.ss.encryptAndHash([])

      conn.sendHSMessage(ebytes, hbytes)

    block: # <- e, ee, s, es
      var msg = BytesView.init(await conn.receiveHSMessage())
      msg.consume(read_e())
      dh_ee()
      msg.consume(read_s())
      dh_es()
      remoteP2psecret = hs.ss.decryptAndHash(msg.data())

    block: # -> s, se
      let sbytes = write_s()
      dh_se()
      # last payload must follow the encrypted way of sending
      let hbytes = hs.ss.encryptAndHash(p2pSecret)

      conn.sendHSMessage(sbytes, hbytes)

    let (cs1, cs2) = hs.ss.split()
    return
      HandshakeResult(cs1: cs1, cs2: cs2, remoteP2psecret: remoteP2psecret, rs: hs.rs)
  finally:
    burnMem(hs)

proc handshakeXXInbound(
    p: Noise, conn: Connection, p2pSecret: seq[byte]
): Future[HandshakeResult] {.async: (raises: [CancelledError, LPStreamError]).} =
  const initiator = false

  var hs = HandshakeState.init()

  try:
    hs.ss.mixHash(p.commonPrologue)
    hs.s = p.noiseKeys
    var remoteP2psecret: seq[byte]

    block: # <- e
      var msg = BytesView.init(await conn.receiveHSMessage())
      msg.consume(read_e())
      # we might use this early data one day, keeping it here for clarity
      let earlyData {.used.} = hs.ss.decryptAndHash(msg.data())

    block: # -> e, ee, s, es
      let ebytes = write_e()
      dh_ee()
      let sbytes = write_s()
      dh_es()
      let hbytes = hs.ss.encryptAndHash(p2pSecret)

      conn.sendHSMessage(ebytes, sbytes, hbytes)

    block: # <- s, se
      var msg = BytesView.init(await conn.receiveHSMessage())
      msg.consume(read_s())
      dh_se()
      remoteP2psecret = hs.ss.decryptAndHash(msg.data())

    let (cs1, cs2) = hs.ss.split()
    return
      HandshakeResult(cs1: cs1, cs2: cs2, remoteP2psecret: remoteP2psecret, rs: hs.rs)
  finally:
    burnMem(hs)

method readMessage*(
    sconn: NoiseConnection
): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]).} =
  while true: # Discard 0-length payloads
    let frame = await sconn.stream.readFrame()
    sconn.activity = true
    if frame.len > ChaChaPolyTag.len:
      let res = sconn.readCs.decryptWithAd([], frame)
      if res.len > 0:
        when defined(libp2p_dump):
          dumpMessage(sconn, FlowDirection.Incoming, res)
        return res

    when defined(libp2p_dump):
      dumpMessage(sconn, FlowDirection.Incoming, [])
    trace "Received 0-length message", sconn

proc encryptFrame(
    sconn: NoiseConnection, cipherFrame: var openArray[byte], src: openArray[byte]
) {.raises: [NoiseNonceMaxError].} =
  # Frame consists of length + cipher data + tag
  doAssert src.len <= MaxPlainSize
  doAssert cipherFrame.len == 2 + src.len + sizeof(ChaChaPolyTag)

  cipherFrame[0 ..< 2] = toBytesBE(uint16(src.len + sizeof(ChaChaPolyTag)))
  cipherFrame[2 ..< 2 + src.len()] = src

  let tag = encrypt(sconn.writeCs, cipherFrame.toOpenArray(2, 2 + src.len() - 1), [])

  cipherFrame[2 + src.len() ..< cipherFrame.len] = tag

method write*(
    sconn: NoiseConnection, message: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  # Fast path: `{.async.}` would introduce a copy of `message`
  const FramingSize = 2 + sizeof(ChaChaPolyTag)

  let frames = (message.len + MaxPlainSize - 1) div MaxPlainSize

  var
    cipherFrames = newSeqUninit[byte](message.len + frames * FramingSize)
    left = message.len
    offset = 0
    woffset = 0

  while left > 0:
    let chunkSize = min(MaxPlainSize, left)

    try:
      encryptFrame(
        sconn,
        cipherFrames.toOpenArray(woffset, woffset + chunkSize + FramingSize - 1),
        message.toOpenArray(offset, offset + chunkSize - 1),
      )
    except NoiseNonceMaxError as exc:
      debug "Noise nonce exceeded"
      let fut = newFuture[void]("noise.write.nonce")
      fut.fail(exc)
      return fut

    when defined(libp2p_dump):
      dumpMessage(
        sconn,
        FlowDirection.Outgoing,
        message.toOpenArray(offset, offset + chunkSize - 1),
      )

    left = left - chunkSize
    offset += chunkSize
    woffset += chunkSize + FramingSize

  sconn.activity = true

  # Write all `cipherFrames` in a single write, to avoid interleaving /
  # sequencing issues
  sconn.stream.write(cipherFrames)

method handshake*(
    p: Noise, conn: Connection, initiator: bool, peerId: Opt[PeerId]
): Future[SecureConn] {.async: (raises: [CancelledError, LPStreamError]).} =
  trace "Starting Noise handshake", conn, initiator

  let timeout = conn.timeout
  conn.timeout = HandshakeTimeout

  # https://github.com/libp2p/specs/tree/master/noise#libp2p-data-in-handshake-messages
  let signedPayload =
    p.localPrivateKey.sign(PayloadString & p.noiseKeys.publicKey.getBytes)
  if signedPayload.isErr():
    raise (ref NoiseHandshakeError)(
      msg: "Failed to sign public key: " & $signedPayload.error()
    )

  var libp2pProof = initProtoBuffer()
  libp2pProof.write(1, p.localPublicKey)
  libp2pProof.write(2, signedPayload.get().getBytes())
  # data field also there but not used!
  libp2pProof.finish()

  var handshakeRes =
    if initiator:
      await handshakeXXOutbound(p, conn, libp2pProof.buffer)
    else:
      await handshakeXXInbound(p, conn, libp2pProof.buffer)

  var secure =
    try:
      var
        remoteProof = initProtoBuffer(handshakeRes.remoteP2psecret)
        remotePubKey: PublicKey
        remotePubKeyBytes: seq[byte]
        remoteSig: Signature
        remoteSigBytes: seq[byte]

      if not remoteProof.getField(1, remotePubKeyBytes).valueOr(false):
        raise (ref NoiseHandshakeError)(
          msg:
            "Failed to deserialize remote public key bytes. (initiator: " & $initiator &
            ")"
        )
      if not remoteProof.getField(2, remoteSigBytes).valueOr(false):
        raise (ref NoiseHandshakeError)(
          msg:
            "Failed to deserialize remote signature bytes. (initiator: " & $initiator &
            ")"
        )

      if not remotePubKey.init(remotePubKeyBytes):
        raise (ref NoiseHandshakeError)(
          msg: "Failed to decode remote public key. (initiator: " & $initiator & ")"
        )
      if not remoteSig.init(remoteSigBytes):
        raise (ref NoiseHandshakeError)(
          msg: "Failed to decode remote signature. (initiator: " & $initiator & ")"
        )

      let verifyPayload = PayloadString & handshakeRes.rs.getBytes
      if not remoteSig.verify(verifyPayload, remotePubKey):
        raise (ref NoiseHandshakeError)(msg: "Noise handshake signature verify failed.")
      else:
        trace "Remote signature verified", conn

      let pid = PeerId.init(remotePubKey).valueOr:
        raise (ref NoiseHandshakeError)(msg: "Invalid remote peer id: " & $error)

      trace "Remote peer id", pid = $pid

      peerId.withValue(targetPid):
        if not targetPid.validate():
          raise (ref NoiseHandshakeError)(msg: "Failed to validate expected peerId.")

        if pid != targetPid:
          var failedKey: PublicKey
          discard extractPublicKey(targetPid, failedKey)
          debug "Noise handshake, peer id doesn't match!",
            initiator,
            dealt_peer = conn,
            dealt_key = $failedKey,
            received_peer = $pid,
            received_key = $remotePubKey
          raise (ref NoiseHandshakeError)(
            msg: "Noise handshake, peer id don't match! " & $pid & " != " & $targetPid
          )
      conn.peerId = pid

      var tmp = NoiseConnection.new(conn, conn.peerId, conn.observedAddr)
      if initiator:
        tmp.readCs = handshakeRes.cs2
        tmp.writeCs = handshakeRes.cs1
      else:
        tmp.readCs = handshakeRes.cs1
        tmp.writeCs = handshakeRes.cs2
      tmp
    finally:
      burnMem(handshakeRes)

  trace "Noise handshake completed!", initiator, peer = shortLog(secure.peerId)

  conn.timeout = timeout

  return secure

method closeImpl*(s: NoiseConnection) {.async: (raises: []).} =
  await procCall SecureConn(s).closeImpl()

  burnMem(s.readCs)
  burnMem(s.writeCs)

method init*(p: Noise) {.gcsafe.} =
  procCall Secure(p).init()
  p.codec = NoiseCodec

proc new*(
    T: typedesc[Noise],
    rng: ref HmacDrbgContext,
    privateKey: PrivateKey,
    outgoing: bool = true,
    commonPrologue: seq[byte] = @[],
): T =
  let pkBytes = privateKey
    .getPublicKey()
    .expect("Expected valid Private Key")
    .getBytes()
    .expect("Couldn't get public Key bytes")

  var noise = Noise(
    rng: rng,
    outgoing: outgoing,
    localPrivateKey: privateKey,
    localPublicKey: pkBytes,
    noiseKeys: genKeyPair(rng[]),
    commonPrologue: commonPrologue,
  )

  noise.init()
  noise
