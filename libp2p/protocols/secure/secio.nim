
## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
import chronos, chronicles
import nimcrypto/[sysrand, hmac, sha2, sha, hash, rijndael, twofish, bcmode]
import secure, 
       ../../connection, 
       ../../crypto/crypto, 
       ../../crypto/ecnist,
       ../../protobuf/minprotobuf, 
       ../../peer, 
       ../../stream/bufferstream
export hmac, sha2, sha, hash, rijndael, bcmode

logScope:
  topic = "secio"

const
  SecioCodec* = "/secio/1.0.0"
  SecioMaxMessageSize = 8 * 1024 * 1024 ## 8mb
  SecioMaxMacSize = sha512.sizeDigest
  SecioNonceSize = 16
  SecioExchanges = "P-256,P-384,P-521"
  SecioCiphers = "TwofishCTR,AES-256,AES-128"
  SecioHashes = "SHA256,SHA512"

type
  Secio = ref object of Secure
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

  SecureConnection* = ref object of Connection
    conn*: Connection
    writerMac: SecureMac
    readerMac: SecureMac
    writerCoder: SecureCipher
    readerCoder: SecureCipher

proc init(mac: var SecureMac, hash: string, key: openarray[byte]) =
  if hash == "SHA256":
    mac = SecureMac(kind: SecureMacType.Sha256)
    mac.ctxsha256.init(key)
  elif hash == "SHA512":
    mac = SecureMac(kind: SecureMacType.Sha512)
    mac.ctxsha512.init(key)
  elif hash == "SHA1":
    mac = SecureMac(kind: SecureMacType.Sha1)
    mac.ctxsha1.init(key)

proc update(mac: var SecureMac, data: openarray[byte]) =
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
    result = int(mac.ctxsha256.sizeDigest())
  of SecureMacType.Sha512:
    result = int(mac.ctxsha512.sizeDigest())
  of SecureMacType.Sha1:
    result = int(mac.ctxsha1.sizeDigest())

proc finish(mac: var SecureMac, data: var openarray[byte]) =
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

proc init(sc: var SecureCipher, cipher: string, key: openarray[byte],
          iv: openarray[byte]) {.inline.} =
  if cipher == "AES-128":
    sc = SecureCipher(kind: SecureCipherType.Aes128)
    sc.ctxaes128.init(key, iv)
  elif cipher == "AES-256":
    sc = SecureCipher(kind: SecureCipherType.Aes256)
    sc.ctxaes256.init(key, iv)
  elif cipher == "TwofishCTR":
    sc = SecureCipher(kind: SecureCipherType.Twofish)
    sc.ctxtwofish256.init(key, iv)

proc encrypt(cipher: var SecureCipher, input: openarray[byte],
             output: var openarray[byte]) {.inline.} =
  case cipher.kind
  of SecureCipherType.Aes128:
    cipher.ctxaes128.encrypt(input, output)
  of SecureCipherType.Aes256:
    cipher.ctxaes256.encrypt(input, output)
  of SecureCipherType.Twofish:
    cipher.ctxtwofish256.encrypt(input, output)

proc decrypt(cipher: var SecureCipher, input: openarray[byte],
             output: var openarray[byte]) {.inline.} =
  case cipher.kind
  of SecureCipherType.Aes128:
    cipher.ctxaes128.decrypt(input, output)
  of SecureCipherType.Aes256:
    cipher.ctxaes256.decrypt(input, output)
  of SecureCipherType.Twofish:
    cipher.ctxtwofish256.decrypt(input, output)

proc macCheckAndDecode(sconn: SecureConnection, data: var seq[byte]): bool =
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
          stored = toHex(data.toOpenArray(mark, len(data) - 1))
    return false

  sconn.readerCoder.decrypt(data.toOpenArray(0, mark - 1),
                            data.toOpenArray(0, mark - 1))
  data.setLen(mark)
  result = true

proc readMessage*(sconn: SecureConnection): Future[seq[byte]] {.async.} =
  ## Read message from channel secure connection ``sconn``.
  try:
    var buf = newSeq[byte](4)
    await sconn.conn.readExactly(addr buf[0], 4)
    let length = (int(buf[0]) shl 24) or (int(buf[1]) shl 16) or
                 (int(buf[2]) shl 8) or (int(buf[3]))
    trace "Recieved message header", header = toHex(buf), length = length
    if length <= SecioMaxMessageSize:
      buf.setLen(length)
      await sconn.conn.readExactly(addr buf[0], length)
      trace "Received message body", length = length,
                                     buffer = toHex(buf)
      if sconn.macCheckAndDecode(buf):
        result = buf
      else:
        debug "Message MAC verification failed", buf = toHex(buf)
    else:
      debug "Received message header size is more then allowed",
            length = length, allowed_length = SecioMaxMessageSize
  except AsyncStreamIncompleteError:
    debug "Connection dropped while reading"
  except AsyncStreamReadError:
    debug "Error reading from connection"

proc writeMessage*(sconn: SecureConnection, message: seq[byte]) {.async.} =
  ## Write message ``message`` to secure connection ``sconn``.
  let macsize = sconn.writerMac.sizeDigest()
  var msg = newSeq[byte](len(message) + 4 + macsize)
  sconn.writerCoder.encrypt(message, msg.toOpenArray(4, 4 + len(message) - 1))
  let mo = 4 + len(message)
  sconn.writerMac.update(msg.toOpenArray(4, 4 + len(message) - 1))
  sconn.writerMac.finish(msg.toOpenArray(mo, mo + macsize - 1))
  sconn.writerMac.reset()
  let length = len(message) + macsize
  msg[0] = byte(length shr 24)
  msg[1] = byte(length shr 16)
  msg[2] = byte(length shr 8)
  msg[3] = byte(length and 0xFF)
  trace "Writing message", message = toHex(msg)
  try:
    await sconn.conn.write(msg)
  except AsyncStreamWriteError:
    debug "Could not write to connection"

proc newSecureConnection*(conn: Connection, hash: string, cipher: string,
                          secrets: Secret,
                          order: int): SecureConnection =
  ## Create new secure connection, using specified hash algorithm ``hash``,
  ## cipher algorithm ``cipher``, stretched keys ``secrets`` and order
  ## ``order``.
  new result
  let i0 = if order < 0: 1 else: 0
  let i1 = if order < 0: 0 else: 1

  result.conn = conn
  trace "Writer credentials", mackey = toHex(secrets.macOpenArray(i0)),
                              enckey = toHex(secrets.keyOpenArray(i0)),
                              iv = toHex(secrets.ivOpenArray(i0))
  trace "Reader credentials", mackey = toHex(secrets.macOpenArray(i1)),
                              enckey = toHex(secrets.keyOpenArray(i1)),
                              iv = toHex(secrets.ivOpenArray(i1))
  result.writerMac.init(hash, secrets.macOpenArray(i0))
  result.readerMac.init(hash, secrets.macOpenArray(i1))
  result.writerCoder.init(cipher, secrets.keyOpenArray(i0),
                          secrets.ivOpenArray(i0))
  result.readerCoder.init(cipher, secrets.keyOpenArray(i1),
                          secrets.ivOpenArray(i1))

proc transactMessage(conn: Connection,
                     msg: seq[byte]): Future[seq[byte]] {.async.} =
  var buf = newSeq[byte](4)
  try:
    trace "Sending message", message = toHex(msg), length = len(msg)
    await conn.write(msg)
    await conn.readExactly(addr buf[0], 4)
    let length = (int(buf[0]) shl 24) or (int(buf[1]) shl 16) or
                 (int(buf[2]) shl 8) or (int(buf[3]))
    trace "Recieved message header", header = toHex(buf), length = length
    if length <= SecioMaxMessageSize:
      buf.setLen(length)
      await conn.readExactly(addr buf[0], length)
      trace "Received message body", conn = conn, length = length
      result = buf
    else:
      trace "Received size of message exceed limits", conn = conn,
                                                      length = length
  except AsyncStreamIncompleteError:
    trace "Connection dropped while reading", conn = conn
  except AsyncStreamReadError:
    trace "Error reading from connection", conn = conn
  except AsyncStreamWriteError:
    trace "Could not write to connection", conn = conn

proc handshake*(s: Secio, conn: Connection): Future[SecureConnection] {.async.} =
  var
    localNonce: array[SecioNonceSize, byte]
    remoteNonce: seq[byte]
    remoteBytesPubkey: seq[byte]
    remoteEBytesPubkey: seq[byte]
    remoteEBytesSig: seq[byte]
    remotePubkey: PublicKey
    remoteEPubkey: PublicKey = PublicKey(scheme: ECDSA)
    remoteESignature: Signature
    remoteExchanges: string
    remoteCiphers: string
    remoteHashes: string
    remotePeerId: PeerID
    localPeerId: PeerID
    ekey: PrivateKey
    localBytesPubkey = s.localPublicKey.getBytes()

  if randomBytes(localNonce) != SecioNonceSize:
    raise newException(CatchableError, "Could not generate random data")

  var request = createProposal(localNonce, localBytesPubkey, SecioExchanges,
                               SecioCiphers, SecioHashes)

  localPeerId = PeerID.init(s.localPublicKey)

  debug "Local proposal", schemes = SecioExchanges, ciphers = SecioCiphers,
                          hashes = SecioHashes,
                          pubkey = toHex(localBytesPubkey),
                          peer = localPeerId

  var answer = await transactMessage(conn, request)

  if len(answer) == 0:
    trace "Proposal exchange failed", conn = conn
    return

  if not decodeProposal(answer, remoteNonce, remoteBytesPubkey, remoteExchanges,
                        remoteCiphers, remoteHashes):
    trace "Remote proposal decoding failed", conn = conn
    return

  if not remotePubkey.init(remoteBytesPubkey):
    trace "Remote public key incorrect or corrupted", pubkey = remoteBytesPubkey
    return

  remotePeerId = PeerID.init(remotePubkey)

  # TODO: PeerID check against supplied PeerID

  let order = getOrder(remoteBytesPubkey, localNonce, localBytesPubkey,
                       remoteNonce)
  debug "Remote proposal", schemes = remoteExchanges, ciphers = remoteCiphers,
                           hashes = remoteHashes,
                           pubkey = toHex(remoteBytesPubkey), order = order,
                           peer = remotePeerId

  let scheme = selectBest(order, SecioExchanges, remoteExchanges)
  let cipher = selectBest(order, SecioCiphers, remoteCiphers)
  let hash = selectBest(order, SecioHashes, remoteHashes)
  if len(scheme) == 0 or len(cipher) == 0 or len(hash) == 0:
    debug "No algorithms in common", peer = remotePeerId
    return

  debug "Encryption scheme selected", scheme = scheme, cipher = cipher,
                                      hash = hash

  var ekeypair = ephemeral(scheme)
  # We need EC public key in raw binary form
  var epubkey = ekeypair.pubkey.eckey.getRawBytes()
  var localCorpus = request[4..^1] & answer & epubkey
  var signature = s.localPrivateKey.sign(localCorpus)

  var localExchange = createExchange(epubkey, signature.getBytes())

  var remoteExchange = await transactMessage(conn, localExchange)
  if len(remoteExchange) == 0:
    trace "Corpus exchange failed", conn = conn
    return

  if not decodeExchange(remoteExchange, remoteEBytesPubkey, remoteEBytesSig):
    trace "Remote exchange decoding failed", conn = conn
    return

  if not remoteESignature.init(remoteEBytesSig):
    trace "Remote signature incorrect or corrupted",
          signature = toHex(remoteEBytesSig)
    return

  var remoteCorpus = answer & request[4..^1] & remoteEBytesPubkey
  if not remoteESignature.verify(remoteCorpus, remotePubkey):
    debug "Signature verification failed", scheme = remotePubkey.scheme,
          signature = remoteESignature, pubkey = remotePubkey,
          corpus = remoteCorpus
    return

  debug "Signature verified", scheme = remotePubkey.scheme

  if not remoteEPubkey.eckey.initRaw(remoteEBytesPubkey):
    debug "Remote ephemeral public key incorrect or corrupted",
          pubkey = toHex(remoteEBytesPubkey)
    return

  var secret = getSecret(remoteEPubkey, ekeypair.seckey)
  if len(secret) == 0:
    trace "Shared secret could not be created",
          pubkeyScheme = remoteEPubkey.scheme,
          seckeyScheme = ekeypair.seckey.scheme
    return

  trace "Shared secret calculated", secret = toHex(secret)

  var keys = stretchKeys(cipher, hash, secret)

  trace "Authenticated encryption parameters",
        iv0 = toHex(keys.ivOpenArray(0)), key0 = toHex(keys.keyOpenArray(0)),
        mac0 = toHex(keys.macOpenArray(0)),
        iv1 = toHex(keys.ivOpenArray(1)), key1 = toHex(keys.keyOpenArray(1)),
        mac1 = toHex(keys.macOpenArray(1))

  # Perform Nonce exchange over encrypted channel.

  result = newSecureConnection(conn, hash, cipher, keys, order)
  await result.writeMessage(remoteNonce)
  var res = await result.readMessage()

  if res != @localNonce:
    debug "Nonce verification failed", receivedNonce = toHex(res),
                                       localNonce = toHex(localNonce)
    raise newException(CatchableError, "Nonce verification failed")
  else:
    debug "Secure handshake succeeded"

proc handleConn(s: Secio, conn: Connection): Future[Connection] {.async.} =
  var sconn = await s.handshake(conn)
  proc writeHandler(data: seq[byte]) {.async, gcsafe.} =
    await sconn.writeMessage(data)
  
  var stream = newBufferStream(writeHandler)
  result = newConnection(stream)
  while not conn.closed:
    let msg = await sconn.readMessage()
    await stream.pushTo(msg)

method init(s: Secio) {.gcsafe.} =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    asyncCheck s.handleConn(conn)

  s.codec = SecioCodec
  s.handler = handle

method secure*(s: Secio, conn: Connection): Future[Connection] {.gcsafe.} =
  result = s.handleConn(conn)

proc newSecio*(localPrivateKey: PrivateKey): Secio =
  new result
  result.localPrivateKey = localPrivateKey
  result.localPublicKey = localPrivateKey.getKey()
  result.init()
