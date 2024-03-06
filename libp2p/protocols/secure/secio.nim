# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[oids, strformat]
import bearssl/rand
import chronos, chronicles, stew/endians2
import nimcrypto/[hmac, sha2, sha, hash, rijndael, twofish, bcmode]
import secure,
       ../../stream/connection,
       ../../peerinfo,
       ../../crypto/crypto,
       ../../crypto/ecnist,
       ../../peerid,
       ../../utility,
       ../../errors

export hmac, sha2, sha, hash, rijndael, bcmode

logScope:
  topics = "libp2p secio"

const
  SecioCodec* = "/secio/1.0.0"
  SecioMaxMessageSize = 8 * 1024 * 1024 ## 8mb
  SecioMaxMacSize = sha512.sizeDigest
  SecioNonceSize = 16
  SecioExchanges = "P-256,P-384,P-521"
  SecioCiphers = "TwofishCTR,AES-256,AES-128"
  SecioHashes = "SHA256,SHA512"

type
  Secio* = ref object of Secure
    rng: ref HmacDrbgContext
    localPrivateKey: PrivateKey
    localPublicKey: PublicKey
    remotePublicKey: PublicKey

  SecureCipherType {.pure.} = enum
    Aes128, Aes256, Twofish

  SecureMacType {.pure.} = enum
    Sha1, Sha256, Sha512

  SecureCipher = object
    case kind: SecureCipherType
    of SecureCipherType.Aes128:
      ctxaes128: CTR[aes128]
    of SecureCipherType.Aes256:
      ctxaes256: CTR[aes256]
    of SecureCipherType.Twofish:
      ctxtwofish256: CTR[twofish256]

  SecureMac = object
    case kind: SecureMacType
    of SecureMacType.Sha256:
      ctxsha256: HMAC[sha256]
    of SecureMacType.Sha512:
      ctxsha512: HMAC[sha512]
    of SecureMacType.Sha1:
      ctxsha1: HMAC[sha1]

  SecioConn = ref object of SecureConn
    writerMac: SecureMac
    readerMac: SecureMac
    writerCoder: SecureCipher
    readerCoder: SecureCipher

  SecioError* = object of LPStreamError

func shortLog*(conn: SecioConn): auto =
  try:
    if conn == nil: "SecioConn(nil)"
    else: &"{shortLog(conn.peerId)}:{conn.oid}"
  except ValueError as exc:
    raiseAssert(exc.msg)

chronicles.formatIt(SecioConn): shortLog(it)

proc init(mac: var SecureMac, hash: string, key: openArray[byte]) =
  if hash == "SHA256":
    mac = SecureMac(kind: SecureMacType.Sha256)
    mac.ctxsha256.init(key)
  elif hash == "SHA512":
    mac = SecureMac(kind: SecureMacType.Sha512)
    mac.ctxsha512.init(key)
  elif hash == "SHA1":
    mac = SecureMac(kind: SecureMacType.Sha1)
    mac.ctxsha1.init(key)

proc update(mac: var SecureMac, data: openArray[byte]) =
  case mac.kind
  of SecureMacType.Sha256:
    update(mac.ctxsha256, data)
  of SecureMacType.Sha512:
    update(mac.ctxsha512, data)
  of SecureMacType.Sha1:
    update(mac.ctxsha1, data)

proc sizeDigest(mac: SecureMac): int {.inline.} =
  case mac.kind
  of SecureMacType.Sha256:
    int(mac.ctxsha256.sizeDigest())
  of SecureMacType.Sha512:
    int(mac.ctxsha512.sizeDigest())
  of SecureMacType.Sha1:
    int(mac.ctxsha1.sizeDigest())

proc finish(mac: var SecureMac, data: var openArray[byte]) =
  case mac.kind
  of SecureMacType.Sha256:
    discard finish(mac.ctxsha256, data)
  of SecureMacType.Sha512:
    discard finish(mac.ctxsha512, data)
  of SecureMacType.Sha1:
    discard finish(mac.ctxsha1, data)

proc reset(mac: var SecureMac) =
  case mac.kind
  of SecureMacType.Sha256:
    reset(mac.ctxsha256)
  of SecureMacType.Sha512:
    reset(mac.ctxsha512)
  of SecureMacType.Sha1:
    reset(mac.ctxsha1)

proc init(sc: var SecureCipher, cipher: string, key: openArray[byte],
          iv: openArray[byte]) {.inline.} =
  if cipher == "AES-128":
    sc = SecureCipher(kind: SecureCipherType.Aes128)
    sc.ctxaes128.init(key, iv)
  elif cipher == "AES-256":
    sc = SecureCipher(kind: SecureCipherType.Aes256)
    sc.ctxaes256.init(key, iv)
  elif cipher == "TwofishCTR":
    sc = SecureCipher(kind: SecureCipherType.Twofish)
    sc.ctxtwofish256.init(key, iv)

proc encrypt(cipher: var SecureCipher, input: openArray[byte],
             output: var openArray[byte]) {.inline.} =
  case cipher.kind
  of SecureCipherType.Aes128:
    cipher.ctxaes128.encrypt(input, output)
  of SecureCipherType.Aes256:
    cipher.ctxaes256.encrypt(input, output)
  of SecureCipherType.Twofish:
    cipher.ctxtwofish256.encrypt(input, output)

proc decrypt(cipher: var SecureCipher, input: openArray[byte],
             output: var openArray[byte]) {.inline.} =
  case cipher.kind
  of SecureCipherType.Aes128:
    cipher.ctxaes128.decrypt(input, output)
  of SecureCipherType.Aes256:
    cipher.ctxaes256.decrypt(input, output)
  of SecureCipherType.Twofish:
    cipher.ctxtwofish256.decrypt(input, output)

proc macCheckAndDecode(sconn: SecioConn, data: var seq[byte]): bool =
  ## This procedure checks MAC of recieved message ``data`` and if message is
  ## authenticated, then decrypt message.
  ##
  ## Procedure returns ``false`` if message is too short or MAC verification
  ## failed.
  var macData: array[SecioMaxMacSize, byte]
  let macsize = sconn.readerMac.sizeDigest()
  if len(data) < macsize:
    trace "Message is shorter then MAC size", message_length = len(data),
                                              mac_size = macsize
    return false
  let mark = len(data) - macsize
  sconn.readerMac.update(data.toOpenArray(0, mark - 1))
  sconn.readerMac.finish(macData)
  sconn.readerMac.reset()
  if not equalMem(addr data[mark], addr macData[0], macsize):
    trace "Invalid MAC",
          calculated = toHex(macData.toOpenArray(0, macsize - 1)),
          stored = toHex(data.toOpenArray(mark, data.high))
    return false

  sconn.readerCoder.decrypt(data.toOpenArray(0, mark - 1),
                            data.toOpenArray(0, mark - 1))
  data.setLen(mark)
  true

proc readRawMessage(
    conn: Connection
): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]).} =
  while true: # Discard 0-length payloads
    var lengthBuf: array[4, byte]
    await conn.readExactly(addr lengthBuf[0], lengthBuf.len)
    let length = uint32.fromBytesBE(lengthBuf)

    trace "Recieved message header", header = lengthBuf.shortLog, length = length

    if length > SecioMaxMessageSize: # Verify length before casting!
      trace "Received size of message exceed limits", conn, length = length
      raise newException(SecioError, "Message exceeds maximum length")

    if length > 0:
      var buf = newSeq[byte](int(length))
      await conn.readExactly(addr buf[0], buf.len)
      trace "Received message body",
        conn, length = buf.len, buff = buf.shortLog
      return buf

    trace "Discarding 0-length payload", conn

method readMessage*(
    sconn: SecioConn
): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]).} =
  ## Read message from channel secure connection ``sconn``.
  when chronicles.enabledLogLevel == LogLevel.TRACE:
    logScope:
      stream_oid = $sconn.stream.oid
  var buf = await sconn.stream.readRawMessage()
  if sconn.macCheckAndDecode(buf):
    buf
  else:
    trace "Message MAC verification failed", buf = buf.shortLog
    raise newException(SecioError, "message failed MAC verification")

method write*(
    sconn: SecioConn,
    message: seq[byte]) {.async: (raises: [CancelledError, LPStreamError]).} =
  ## Write message ``message`` to secure connection ``sconn``.
  if message.len == 0:
    return

  var
    left = message.len
    offset = 0
  while left > 0:
    let
      chunkSize = min(left, SecioMaxMessageSize - 64)
      macsize = sconn.writerMac.sizeDigest()
      length = chunkSize + macsize

    var msg = newSeq[byte](chunkSize + 4 + macsize)
    msg[0..<4] = uint32(length).toBytesBE()

    sconn.writerCoder.encrypt(
      message.toOpenArray(offset, offset + chunkSize - 1),
      msg.toOpenArray(4, 4 + chunkSize - 1))
    left = left - chunkSize
    offset = offset + chunkSize
    let mo = 4 + chunkSize
    sconn.writerMac.update(msg.toOpenArray(4, 4 + chunkSize - 1))
    sconn.writerMac.finish(msg.toOpenArray(mo, mo + macsize - 1))
    sconn.writerMac.reset()

    trace "Writing message", message = msg.shortLog, left, offset
    await sconn.stream.write(msg)
    sconn.activity = true

proc newSecioConn(
    conn: Connection,
    hash: string,
    cipher: string,
    secrets: Secret,
    order: int,
    remotePubKey: PublicKey): SecioConn =
  ## Create new secure stream/lpstream, using specified hash algorithm ``hash``,
  ## cipher algorithm ``cipher``, stretched keys ``secrets`` and order
  ## ``order``.
  result = SecioConn.new(conn, conn.peerId, conn.observedAddr)

  let i0 = if order < 0: 1 else: 0
  let i1 = if order < 0: 0 else: 1

  trace "Writer credentials", mackey = secrets.macOpenArray(i0).shortLog,
                              enckey = secrets.keyOpenArray(i0).shortLog,
                              iv = secrets.ivOpenArray(i0).shortLog
  trace "Reader credentials", mackey = secrets.macOpenArray(i1).shortLog,
                              enckey = secrets.keyOpenArray(i1).shortLog,
                              iv = secrets.ivOpenArray(i1).shortLog
  result.writerMac.init(hash, secrets.macOpenArray(i0))
  result.readerMac.init(hash, secrets.macOpenArray(i1))
  result.writerCoder.init(cipher, secrets.keyOpenArray(i0),
                          secrets.ivOpenArray(i0))
  result.readerCoder.init(cipher, secrets.keyOpenArray(i1),
                          secrets.ivOpenArray(i1))

proc transactMessage(
    conn: Connection,
    msg: seq[byte]
): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]).} =
  trace "Sending message", message = msg.shortLog, length = len(msg)
  await conn.write(msg)
  await conn.readRawMessage()

method handshake*(
    s: Secio,
    conn: Connection,
    initiator: bool,
    peerId: Opt[PeerId]
): Future[SecureConn] {.async: (raises: [CancelledError, LPStreamError]).} =
  let localBytesPubkey = s.localPublicKey.getBytes()
  if localBytesPubkey.isErr():
    raise newException(SecioError,
      "Failed to get local public key bytes: " & $localBytesPubkey.error())

  let localPeerId = PeerId.init(s.localPublicKey)
  if localPeerId.isErr():
    raise newException(SecioError,
      "Failed to initialize local peer ID: " & $localPeerId.error())

  var localNonce: array[SecioNonceSize, byte]
  hmacDrbgGenerate(s.rng[], localNonce)

  let request = createProposal(
    localNonce, localBytesPubkey.get(),
    SecioExchanges, SecioCiphers, SecioHashes)

  trace "Local proposal", schemes = SecioExchanges,
                          ciphers = SecioCiphers,
                          hashes = SecioHashes,
                          pubkey = localBytesPubkey.get().shortLog,
                          peer = localPeerId.get()

  let answer = await transactMessage(conn, request)
  if len(answer) == 0:
    trace "Proposal exchange failed", conn
    raise newException(SecioError, "Proposal exchange failed")

  var
    remoteNonce: seq[byte]
    remoteBytesPubkey: seq[byte]
    remoteExchanges: string
    remoteCiphers: string
    remoteHashes: string
  if not decodeProposal(
      answer, remoteNonce, remoteBytesPubkey, remoteExchanges,
      remoteCiphers, remoteHashes):
    trace "Remote proposal decoding failed", conn
    raise newException(SecioError, "Remote proposal decoding failed")

  var remotePubkey: PublicKey
  if not remotePubkey.init(remoteBytesPubkey):
    trace "Remote public key incorrect or corrupted",
          pubkey = remoteBytesPubkey.shortLog
    raise newException(SecioError, "Remote public key incorrect or corrupted")

  let remotePeerId = PeerId.init(remotePubkey)
  if remotePeerId.isErr():
    raise newException(SecioError,
      "Failed to initialize remote peer ID: " & $remotePeerId.error())

  peerId.withValue(targetPid):
    if not targetPid.validate():
      raise newException(SecioError, "Failed to validate expected peerId.")

    if remotePeerId.get() != targetPid:
      raise newException(SecioError, "Peer ids don't match!")
  conn.peerId = remotePeerId.get()
  let order = getOrder(
    remoteBytesPubkey, localNonce, localBytesPubkey.get(), remoteNonce)
  if order.isErr():
    raise newException(SecioError, "Failed to get order: " & $order.error())
  trace "Remote proposal", schemes = remoteExchanges, ciphers = remoteCiphers,
                           hashes = remoteHashes,
                           pubkey = remoteBytesPubkey.shortLog,
                           order = order.get(),
                           peer = remotePeerId.get()

  let
    scheme = selectBest(order.get(), SecioExchanges, remoteExchanges)
    cipher = selectBest(order.get(), SecioCiphers, remoteCiphers)
    hash = selectBest(order.get(), SecioHashes, remoteHashes)
  if len(scheme) == 0 or len(cipher) == 0 or len(hash) == 0:
    trace "No algorithms in common", peer = remotePeerId.get()
    raise newException(SecioError, "No algorithms in common")

  trace "Encryption scheme selected", scheme = scheme, cipher = cipher,
                                      hash = hash

  let ekeypair = ephemeral(scheme, s.rng[])
  if ekeypair.isErr():
    raise newException(SecioError,
      "Failed to create ephemeral keypair: " & $ekeypair.error())
  # We need EC public key in raw binary form
  let epubkey = ekeypair.get().pubkey.getRawBytes()
  if epubkey.isErr():
    raise newException(SecioError,
      "Failed to get ephemeral key bytes: " & $epubkey.error())
  let
    localCorpus = request[4..^1] & answer & epubkey.get()
    signature = s.localPrivateKey.sign(localCorpus)
  if signature.isErr():
    raise newException(SecioError,
      "Failed to sign local corpus: " & $signature.error())

  let
    localExchange = createExchange(epubkey.get(), signature.get().getBytes())
    remoteExchange = await transactMessage(conn, localExchange)
  if len(remoteExchange) == 0:
    trace "Corpus exchange failed", conn
    raise newException(SecioError, "Corpus exchange failed")

  var
    remoteEBytesPubkey: seq[byte]
    remoteEBytesSig: seq[byte]
  if not decodeExchange(remoteExchange, remoteEBytesPubkey, remoteEBytesSig):
    trace "Remote exchange decoding failed", conn
    raise newException(SecioError, "Remote exchange decoding failed")

  var remoteESignature: Signature
  if not remoteESignature.init(remoteEBytesSig):
    trace "Remote signature incorrect or corrupted",
          signature = remoteEBytesSig.shortLog
    raise newException(SecioError, "Remote signature incorrect or corrupted")

  let remoteCorpus = answer & request[4..^1] & remoteEBytesPubkey
  if not remoteESignature.verify(remoteCorpus, remotePubkey):
    trace "Signature verification failed", scheme = $remotePubkey.scheme,
                                           signature = $remoteESignature,
                                           pubkey = $remotePubkey,
                                           corpus = $remoteCorpus
    raise newException(SecioError, "Signature verification failed")

  trace "Signature verified", scheme = remotePubkey.scheme

  var remoteEPubkey: ecnist.EcPublicKey
  if not remoteEPubkey.initRaw(remoteEBytesPubkey):
    trace "Remote ephemeral public key incorrect or corrupted",
          pubkey = toHex(remoteEBytesPubkey)
    raise newException(SecioError,
      "Remote ephemeral public key incorrect or corrupted")

  let secret = getSecret(remoteEPubkey, ekeypair.get().seckey)
  if len(secret) == 0:
    trace "Shared secret could not be created"
    raise newException(SecioError, "Shared secret could not be created")

  trace "Shared secret calculated", secret = secret.shortLog

  let keys = stretchKeys(cipher, hash, secret)

  trace "Authenticated encryption parameters",
        iv0 = toHex(keys.ivOpenArray(0)),
        key0 = keys.keyOpenArray(0).shortLog,
        mac0 = keys.macOpenArray(0).shortLog,
        iv1 = keys.ivOpenArray(1).shortLog,
        key1 = keys.keyOpenArray(1).shortLog,
        mac1 = keys.macOpenArray(1).shortLog

  # Perform Nonce exchange over encrypted channel.

  let secioConn = newSecioConn(
    conn, hash, cipher, keys, order.get(), remotePubkey)
  await secioConn.write(remoteNonce)
  var res = await secioConn.readMessage()

  if res != @localNonce:
    trace "Nonce verification failed", receivedNonce = res.shortLog,
                                       localNonce = localNonce.shortLog
    raise newException(SecioError, "Nonce verification failed")
  else:
    trace "Secure handshake succeeded"
    secioConn

method init(s: Secio) {.gcsafe.} =
  procCall Secure(s).init()
  s.codec = SecioCodec

proc new*(
    T: typedesc[Secio],
    rng: ref HmacDrbgContext,
    localPrivateKey: PrivateKey): T =
  let secio = Secio(
    rng: rng,
    localPrivateKey: localPrivateKey,
    localPublicKey: localPrivateKey.getPublicKey().expect("Invalid private key")
  )
  secio.init()
  secio
