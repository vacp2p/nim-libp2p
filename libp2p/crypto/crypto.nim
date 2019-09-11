## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements Public Key and Private Key interface for libp2p.
import rsa, ecnist, ed25519/ed25519, secp
import ../protobuf/minprotobuf, ../vbuffer, ../multihash, ../multicodec
import nimcrypto/[rijndael, blowfish, sha, sha2, hash, hmac, utils]

# This is workaround for Nim's `import` bug
export rijndael, blowfish, sha, sha2, hash, hmac, utils

from strutils import split

type
  PKScheme* = enum
    RSA = 0,
    Ed25519,
    Secp256k1,
    ECDSA,
    NoSupport

  CipherScheme* = enum
    Aes128 = 0,
    Aes256,
    Blowfish

  DigestSheme* = enum
    Sha1,
    Sha256,
    Sha512

  ECDHEScheme* = EcCurveKind

  PublicKey* = object
    case scheme*: PKScheme
    of RSA:
      rsakey*: RsaPublicKey
    of Ed25519:
      edkey*: EdPublicKey
    of Secp256k1:
      skkey*: SkPublicKey
    of ECDSA:
      eckey*: EcPublicKey
    of NoSupport:
      discard

  PrivateKey* = object
    case scheme*: PKScheme
    of RSA:
      rsakey*: RsaPrivateKey
    of Ed25519:
      edkey*: EdPrivateKey
    of Secp256k1:
      skkey*: SkPrivateKey
    of ECDSA:
      eckey*: EcPrivateKey
    of NoSupport:
      discard

  KeyPair* = object
    seckey*: PrivateKey
    pubkey*: PublicKey

  Secret* = object
    ivsize*: int
    keysize*: int
    macsize*: int
    data*: seq[byte]

  Signature* = object
    data*: seq[byte]

  P2pKeyError* = object of CatchableError
  P2pSigError* = object of CatchableError

const
  SupportedSchemes* = {RSA, Ed25519, Secp256k1, ECDSA}
  SupportedSchemesInt* = {int8(RSA), int8(Ed25519), int8(Secp256k1),
                          int8(ECDSA)}

proc random*(t: typedesc[PrivateKey], scheme: PKScheme,
             bits = DefaultKeySize): PrivateKey =
  ## Generate random private key for scheme ``scheme``.
  ##
  ## ``bits`` is number of bits for RSA key, ``bits`` value must be in
  ## [512, 4096], default value is 2048 bits.
  doAssert(scheme in SupportedSchemes)
  result = PrivateKey(scheme: scheme)
  if scheme == RSA:
    result.rsakey = RsaPrivateKey.random(bits)
  elif scheme == Ed25519:
    result.edkey = EdPrivateKey.random()
  elif scheme == ECDSA:
    result.eckey = EcPrivateKey.random(Secp256r1)
  elif scheme == Secp256k1:
    result.skkey = SkPrivateKey.random()

proc random*(t: typedesc[KeyPair], scheme: PKScheme,
             bits = DefaultKeySize): KeyPair =
  ## Generate random key pair for scheme ``scheme``.
  ##
  ## ``bits`` is number of bits for RSA key, ``bits`` value must be in
  ## [512, 4096], default value is 2048 bits.
  doAssert(scheme in SupportedSchemes)
  result.seckey = PrivateKey(scheme: scheme)
  result.pubkey = PublicKey(scheme: scheme)
  if scheme == RSA:
    var pair = RsaKeyPair.random(bits)
    result.seckey.rsakey = pair.seckey
    result.pubkey.rsakey = pair.pubkey
  elif scheme == Ed25519:
    var pair = EdKeyPair.random()
    result.seckey.edkey = pair.seckey
    result.pubkey.edkey = pair.pubkey
  elif scheme == ECDSA:
    var pair = EcKeyPair.random(Secp256r1)
    result.seckey.eckey = pair.seckey
    result.pubkey.eckey = pair.pubkey
  elif scheme == Secp256k1:
    var pair = SkKeyPair.random()
    result.seckey.skkey = pair.seckey
    result.pubkey.skkey = pair.pubkey

proc getKey*(key: PrivateKey): PublicKey =
  ## Get public key from corresponding private key ``key``.
  result = PublicKey(scheme: key.scheme)
  if key.scheme == RSA:
    result.rsakey = key.rsakey.getKey()
  elif key.scheme == Ed25519:
    result.edkey = key.edkey.getKey()
  elif key.scheme == ECDSA:
    result.eckey = key.eckey.getKey()
  elif key.scheme == Secp256k1:
    result.skkey = key.skkey.getKey()

proc toRawBytes*(key: PrivateKey, data: var openarray[byte]): int =
  ## Serialize private key ``key`` (using scheme's own serialization) and store
  ## it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store private key ``key``.
  if key.scheme == RSA:
    result = key.rsakey.toBytes(data)
  elif key.scheme == Ed25519:
    result = key.edkey.toBytes(data)
  elif key.scheme == ECDSA:
    result = key.eckey.toBytes(data)
  elif key.scheme == Secp256k1:
    result = key.skkey.toBytes(data)

proc toRawBytes*(key: PublicKey, data: var openarray[byte]): int =
  ## Serialize public key ``key`` (using scheme's own serialization) and store
  ## it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store public key ``key``.
  if key.scheme == RSA:
    result = key.rsakey.toBytes(data)
  elif key.scheme == Ed25519:
    result = key.edkey.toBytes(data)
  elif key.scheme == ECDSA:
    result = key.eckey.toBytes(data)
  elif key.scheme == Secp256k1:
    result = key.skkey.toBytes(data)

proc getRawBytes*(key: PrivateKey): seq[byte] =
  ## Return private key ``key`` in binary form (using scheme's own
  ## serialization).
  if key.scheme == RSA:
    result = key.rsakey.getBytes()
  elif key.scheme == Ed25519:
    result = key.edkey.getBytes()
  elif key.scheme == ECDSA:
    result = key.eckey.getBytes()
  elif key.scheme == Secp256k1:
    result = key.skkey.getBytes()

proc getRawBytes*(key: PublicKey): seq[byte] =
  ## Return public key ``key`` in binary form (using scheme's own
  ## serialization).
  if key.scheme == RSA:
    result = key.rsakey.getBytes()
  elif key.scheme == Ed25519:
    result = key.edkey.getBytes()
  elif key.scheme == ECDSA:
    result = key.eckey.getBytes()
  elif key.scheme == Secp256k1:
    result = key.skkey.getBytes()

proc toBytes*(key: PrivateKey, data: var openarray[byte]): int =
  ## Serialize private key ``key`` (using libp2p protobuf scheme) and store
  ## it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store private key ``key``.
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, cast[uint64](key.scheme)))
  msg.write(initProtoField(2, key.getRawBytes()))
  msg.finish()
  result = len(msg.buffer)
  if len(data) >= result:
    copyMem(addr data[0], addr msg.buffer[0], len(msg.buffer))

proc toBytes*(key: PublicKey, data: var openarray[byte]): int =
  ## Serialize public key ``key`` (using libp2p protobuf scheme) and store
  ## it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store public key ``key``.
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, cast[uint64](key.scheme)))
  msg.write(initProtoField(2, key.getRawBytes()))
  msg.finish()
  result = len(msg.buffer)
  if len(data) >= result:
    copyMem(addr data[0], addr msg.buffer[0], len(msg.buffer))

proc toBytes*(sig: Signature, data: var openarray[byte]): int =
  ## Serialize signature ``sig`` and store it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store signature ``sig``.
  result = len(sig.data)
  if len(data) >= result:
    copyMem(addr data[0], unsafeAddr sig.data[0], len(sig.data))

proc getBytes*(key: PrivateKey): seq[byte] =
  ## Return private key ``key`` in binary form (using libp2p's protobuf
  ## serialization).
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, cast[uint64](key.scheme)))
  msg.write(initProtoField(2, key.getRawBytes()))
  msg.finish()
  result = msg.buffer

proc getBytes*(key: PublicKey): seq[byte] =
  ## Return public key ``key`` in binary form (using libp2p's protobuf
  ## serialization).
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, cast[uint64](key.scheme)))
  msg.write(initProtoField(2, key.getRawBytes()))
  msg.finish()
  result = msg.buffer

proc getBytes*(sig: Signature): seq[byte] =
  ## Return signature ``sig`` in binary form.
  result = sig.data

proc init*(key: var PrivateKey, data: openarray[byte]): bool =
  ## Initialize private key ``key`` from libp2p's protobuf serialized raw
  ## binary form.
  ##
  ## Returns ``true`` on success.
  var id: uint64
  var buffer: seq[byte]
  if len(data) > 0:
    var pb = initProtoBuffer(@data)
    if pb.getVarintValue(1, id) != 0:
      if pb.getBytes(2, buffer) != 0:
        if cast[int8](id) in SupportedSchemesInt:
          var scheme = cast[PKScheme](cast[int8](id))
          var nkey = PrivateKey(scheme: scheme)
          if scheme == RSA:
            if init(nkey.rsakey, buffer) == Asn1Status.Success:
              key = nkey
              result = true
          elif scheme == Ed25519:
            if init(nkey.edkey, buffer):
              key = nkey
              result = true
          elif scheme == ECDSA:
            if init(nkey.eckey, buffer) == Asn1Status.Success:
              key = nkey
              result = true
          elif scheme == Secp256k1:
            if init(nkey.skkey, buffer):
              key = nkey
              result = true

proc init*(key: var PublicKey, data: openarray[byte]): bool =
  ## Initialize public key ``key`` from libp2p's protobuf serialized raw
  ## binary form.
  ##
  ## Returns ``true`` on success.
  var id: uint64
  var buffer: seq[byte]
  if len(data) > 0:
    var pb = initProtoBuffer(@data)
    if pb.getVarintValue(1, id) != 0:
      if pb.getBytes(2, buffer) != 0:
        if cast[int8](id) in SupportedSchemesInt:
          var scheme = cast[PKScheme](cast[int8](id))
          var nkey = PublicKey(scheme: scheme)
          if scheme == RSA:
            if init(nkey.rsakey, buffer) == Asn1Status.Success:
              key = nkey
              result = true
          elif scheme == Ed25519:
            if init(nkey.edkey, buffer):
              key = nkey
              result = true
          elif scheme == ECDSA:
            if init(nkey.eckey, buffer) == Asn1Status.Success:
              key = nkey
              result = true
          elif scheme == Secp256k1:
            if init(nkey.skkey, buffer):
              key = nkey
              result = true

proc init*(sig: var Signature, data: openarray[byte]): bool =
  ## Initialize signature ``sig`` from raw binary form.
  ##
  ## Returns ``true`` on success.
  if len(data) > 0:
    sig.data = @data
    result = true

proc init*(key: var PrivateKey, data: string): bool =
  ## Initialize private key ``key`` from libp2p's protobuf serialized
  ## hexadecimal string representation.
  ##
  ## Returns ``true`` on success.
  result = key.init(fromHex(data))

proc init*(key: var PublicKey, data: string): bool =
  ## Initialize public key ``key`` from libp2p's protobuf serialized
  ## hexadecimal string representation.
  ##
  ## Returns ``true`` on success.
  result = key.init(fromHex(data))

proc init*(sig: var Signature, data: string): bool =
  ## Initialize signature ``sig`` from serialized hexadecimal string
  ## representation.
  ##
  ## Returns ``true`` on success.
  result = sig.init(fromHex(data))

proc init*(t: typedesc[PrivateKey], data: openarray[byte]): PrivateKey =
  ## Create new private key from libp2p's protobuf serialized binary form.
  if not result.init(data):
    raise newException(P2pKeyError, "Incorrect binary form")

proc init*(t: typedesc[PublicKey], data: openarray[byte]): PublicKey =
  ## Create new public key from libp2p's protobuf serialized binary form.
  if not result.init(data):
    raise newException(P2pKeyError, "Incorrect binary form")

proc init*(t: typedesc[Signature], data: openarray[byte]): Signature =
  ## Create new public key from libp2p's protobuf serialized binary form.
  if not result.init(data):
    raise newException(P2pSigError, "Incorrect binary form")

proc init*(t: typedesc[PrivateKey], data: string): PrivateKey =
  ## Create new private key from libp2p's protobuf serialized hexadecimal string
  ## form.
  result = t.init(fromHex(data))

proc init*(t: typedesc[PublicKey], data: string): PublicKey =
  ## Create new public key from libp2p's protobuf serialized hexadecimal string
  ## form.
  result = t.init(fromHex(data))

proc init*(t: typedesc[Signature], data: string): Signature =
  ## Create new signature from serialized hexadecimal string form.
  result = t.init(fromHex(data))

proc `==`*(key1, key2: PublicKey): bool =
  ## Return ``true`` if two public keys ``key1`` and ``key2`` of the same
  ## scheme and equal.
  if key1.scheme == key2.scheme:
    if key1.scheme == RSA:
      result = (key1.rsakey == key2.rsakey)
    elif key1.scheme == Ed25519:
      result = (key1.edkey == key2.edkey)
    elif key1.scheme == ECDSA:
      result = (key1.eckey == key2.eckey)

proc `==`*(key1, key2: PrivateKey): bool =
  ## Return ``true`` if two private keys ``key1`` and ``key2`` of the same
  ## scheme and equal.
  if key1.scheme == key2.scheme:
    if key1.scheme == RSA:
      result = (key1.rsakey == key2.rsakey)
    elif key1.scheme == Ed25519:
      result = (key1.edkey == key2.edkey)
    elif key1.scheme == ECDSA:
      result = (key1.eckey == key2.eckey)

proc `$`*(key: PrivateKey): string =
  ## Get string representation of private key ``key``.
  if key.scheme == RSA:
    result = $(key.rsakey)
  elif key.scheme == Ed25519:
    result = "Ed25519 key ("
    result.add($(key.edkey))
    result.add(")")
  elif key.scheme == ECDSA:
    result = "Secp256r1 key ("
    result.add($(key.eckey))
    result.add(")")
  elif key.scheme == Secp256k1:
    result = "Secp256k1 key ("
    result.add($(key.skkey))
    result.add(")")

proc `$`*(key: PublicKey): string =
  ## Get string representation of public key ``key``.
  if key.scheme == RSA:
    result = $(key.rsakey)
  elif key.scheme == Ed25519:
    result = "Ed25519 key ("
    result.add($(key.edkey))
    result.add(")")
  elif key.scheme == ECDSA:
    result = "Secp256r1 key ("
    result.add($(key.eckey))
    result.add(")")
  elif key.scheme == Secp256k1:
    result = "Secp256k1 key ("
    result.add($(key.skkey))
    result.add(")")

proc `$`*(sig: Signature): string =
  ## Get string representation of signature ``sig``.
  result = toHex(sig.data)

proc sign*(key: PrivateKey, data: openarray[byte]): Signature =
  ## Sign message ``data`` using private key ``key`` and return generated
  ## signature in raw binary form.
  if key.scheme == RSA:
    var sig = key.rsakey.sign(data)
    result.data = sig.getBytes()
  elif key.scheme == Ed25519:
    var sig = key.edkey.sign(data)
    result.data = sig.getBytes()
  elif key.scheme == ECDSA:
    var sig = key.eckey.sign(data)
    result.data = sig.getBytes()
  elif key.scheme == Secp256k1:
    var sig = key.skkey.sign(data)
    result.data = sig.getBytes()

proc verify*(sig: Signature, message: openarray[byte],
             key: PublicKey): bool =
  ## Verify signature ``sig`` using message ``message`` and public key ``key``.
  ## Return ``true`` if message signature is valid.
  if key.scheme == RSA:
    var signature: RsaSignature
    if signature.init(sig.data) == Asn1Status.Success:
      result = signature.verify(message, key.rsakey)
  elif key.scheme == Ed25519:
    var signature: EdSignature
    if signature.init(sig.data):
      result = signature.verify(message, key.edkey)
  elif key.scheme == ECDSA:
    var signature: EcSignature
    if signature.init(sig.data) == Asn1Status.Success:
      result = signature.verify(message, key.eckey)
  elif key.scheme == Secp256k1:
    var signature: SkSignature
    if signature.init(sig.data):
      result = signature.verify(message, key.skkey)

template makeSecret(buffer, hmactype, secret, seed: untyped) {.dirty.}=
  var ctx: hmactype
  var j = 0
  # We need to strip leading zeros, because Go bigint serialization do it.
  var offset = 0
  for i in 0..<len(secret):
    if secret[i] != 0x00'u8:
      break
    inc(offset)
  ctx.init(secret.toOpenArray(offset, len(secret) - 1))
  ctx.update(seed)
  var a = ctx.finish()
  while j < len(buffer):
    ctx.init(secret.toOpenArray(offset, len(secret) - 1))
    ctx.update(a.data)
    ctx.update(seed)
    var b = ctx.finish()
    var todo = len(b.data)
    if j + todo > len(buffer):
      todo = len(buffer) - j
    copyMem(addr buffer[j], addr b.data[0], todo)
    j += todo
    ctx.init(secret.toOpenArray(offset, len(secret) - 1))
    ctx.update(a.data)
    a = ctx.finish()

proc stretchKeys*(cipherType: string, hashType: string,
                  sharedSecret: seq[byte]): Secret =
  ## Expand shared secret to cryptographic keys.
  if cipherType == "AES-128":
    result.ivsize = aes128.sizeBlock
    result.keysize = aes128.sizeKey
  elif cipherType == "AES-256":
    result.ivsize = aes256.sizeBlock
    result.keysize = aes256.sizeKey
  elif cipherType == "BLOWFISH":
    result.ivsize = 8
    result.keysize = 32

  var seed = "key expansion"
  result.macsize = 20
  let length = result.ivsize + result.keysize + result.macsize
  result.data = newSeq[byte](2 * length)

  if hashType == "SHA256":
    makeSecret(result.data, HMAC[sha256], sharedSecret, seed)
  elif hashType == "SHA512":
    makeSecret(result.data, HMAC[sha512], sharedSecret, seed)
  elif hashType == "SHA1":
    makeSecret(result.data, HMAC[sha1], sharedSecret, seed)

template goffset*(secret, id, o: untyped): untyped =
  id * (len(secret.data) shr 1) + o

template ivOpenArray*(secret: Secret, id: int): untyped =
  toOpenArray(secret.data, goffset(secret, id, 0),
              goffset(secret, id, secret.ivsize - 1))

template keyOpenArray*(secret: Secret, id: int): untyped =
  toOpenArray(secret.data, goffset(secret, id, secret.ivsize),
              goffset(secret, id, secret.ivsize + secret.keysize - 1))

template macOpenArray*(secret: Secret, id: int): untyped =
  toOpenArray(secret.data, goffset(secret, id, secret.ivsize + secret.keysize),
       goffset(secret, id, secret.ivsize + secret.keysize + secret.macsize - 1))

proc iv*(secret: Secret, id: int): seq[byte] {.inline.} =
  ## Get array of bytes with with initial vector.
  result = newSeq[byte](secret.ivsize)
  var offset = if id == 0: 0 else: (len(secret.data) div 2)
  copyMem(addr result[0], unsafeAddr secret.data[offset], secret.ivsize)

proc key*(secret: Secret, id: int): seq[byte] {.inline.} =
  result = newSeq[byte](secret.keysize)
  var offset = if id == 0: 0 else: (len(secret.data) div 2)
  offset += secret.ivsize
  copyMem(addr result[0], unsafeAddr secret.data[offset], secret.keysize)

proc mac*(secret: Secret, id: int): seq[byte] {.inline.} =
  result = newSeq[byte](secret.macsize)
  var offset = if id == 0: 0 else: (len(secret.data) div 2)
  offset += secret.ivsize + secret.keysize
  copyMem(addr result[0], unsafeAddr secret.data[offset], secret.macsize)

proc ephemeral*(scheme: ECDHEScheme): KeyPair =
  ## Generate ephemeral keys used to perform ECDHE.
  var keypair: EcKeyPair
  if scheme == Secp256r1:
    keypair = EcKeyPair.random(Secp256r1)
  elif scheme == Secp384r1:
    keypair = EcKeyPair.random(Secp384r1)
  elif scheme == Secp521r1:
    keypair = EcKeyPair.random(Secp521r1)
  result.seckey = PrivateKey(scheme: ECDSA)
  result.pubkey = PublicKey(scheme: ECDSA)
  result.seckey.eckey = keypair.seckey
  result.pubkey.eckey = keypair.pubkey

proc ephemeral*(scheme: string): KeyPair {.inline.} =
  ## Generate ephemeral keys used to perform ECDHE using string encoding.
  ##
  ## Currently supported encoding strings are P-256, P-384, P-521, if encoding
  ## string is not supported P-521 key will be generated.
  if scheme == "P-256":
    result = ephemeral(Secp256r1)
  elif scheme == "P-384":
    result = ephemeral(Secp384r1)
  elif scheme == "P-521":
    result = ephemeral(Secp521r1)
  else:
    result = ephemeral(Secp521r1)

proc makeSecret*(remoteEPublic: PublicKey, localEPrivate: PrivateKey,
                 data: var openarray[byte]): int =
  ## Calculate shared secret using remote ephemeral public key
  ## ``remoteEPublic`` and local ephemeral private key ``localEPrivate`` and
  ## store shared secret to ``data``.
  ##
  ## Note this procedure supports only ECDSA keys.
  ##
  ## Returns number of bytes (octets) used to store shared secret data, or
  ## ``0`` on error.
  if remoteEPublic.scheme == ECDSA:
    if localEPrivate.scheme == remoteEPublic.scheme:
      result = toSecret(remoteEPublic.eckey, localEPrivate.eckey, data)

proc getSecret*(remoteEPublic: PublicKey,
                localEPrivate: PrivateKey): seq[byte] =
  ## Calculate shared secret using remote ephemeral public key
  ## ``remoteEPublic`` and local ephemeral private key ``localEPrivate`` and
  ## store shared secret to ``data``.
  ##
  ## Note this procedure supports only ECDSA keys.
  ##
  ## Returns shared secret on success.
  if remoteEPublic.scheme == ECDSA:
    if localEPrivate.scheme == remoteEPublic.scheme:
      result = getSecret(remoteEPublic.eckey, localEPrivate.eckey)

proc getOrder*(remotePubkey, localNonce: openarray[byte],
               localPubkey, remoteNonce: openarray[byte]): int =
  ## Compare values and calculate `order` parameter.
  var ctx: sha256
  ctx.init()
  ctx.update(remotePubkey)
  ctx.update(localNonce)
  var digest1 = ctx.finish()
  ctx.init()
  ctx.update(localPubkey)
  ctx.update(remoteNonce)
  var digest2 = ctx.finish()
  var mh1 = MultiHash.init(multiCodec("sha2-256"), digest1)
  var mh2 = MultiHash.init(multiCodec("sha2-256"), digest2)
  for i in 0 ..< len(mh1.data.buffer):
    result = int(mh1.data.buffer[i]) - int(mh2.data.buffer[i])
    if result != 0:
      if result > 0:
        result = -1
      elif result > 0:
        result = 1
      break

proc selectBest*(order: int, p1, p2: string): string =
  ## Determines which algorithm to use from list `p1` and `p2`.
  ##
  ## Returns empty string if there no algorithms in common.
  var f, s: seq[string]
  if order < 0:
    f = strutils.split(p2, ",")
    s = strutils.split(p1, ",")
  elif order > 0:
    f = strutils.split(p1, ",")
    s = strutils.split(p2, ",")
  else:
    var p = strutils.split(p1, ",")
    result = p[0]
    return

  for felement in f:
    for selement in s:
      if felement == selement:
        result = felement
        return

proc createProposal*(nonce, pubkey: openarray[byte],
                     exchanges, ciphers, hashes: string): seq[byte] =
  ## Create SecIO proposal message using random ``nonce``, local public key
  ## ``pubkey``, comma-delimieted list of supported exchange schemes
  ## ``exchanges``, comma-delimeted list of supported ciphers ``ciphers`` and
  ## comma-delimeted list of supported hashes ``hashes``.
  var msg = initProtoBuffer({WithUint32BeLength})
  msg.write(initProtoField(1, nonce))
  msg.write(initProtoField(2, pubkey))
  msg.write(initProtoField(3, exchanges))
  msg.write(initProtoField(4, ciphers))
  msg.write(initProtoField(5, hashes))
  msg.finish()
  shallowCopy(result, msg.buffer)

proc decodeProposal*(message: seq[byte], nonce, pubkey: var seq[byte],
                     exchanges, ciphers, hashes: var string): bool =
  ## Parse incoming proposal message and decode remote random nonce ``nonce``,
  ## remote public key ``pubkey``, comma-delimieted list of supported exchange
  ## schemes ``exchanges``, comma-delimeted list of supported ciphers
  ## ``ciphers`` and comma-delimeted list of supported hashes ``hashes``.
  ##
  ## Procedure returns ``true`` on success and ``false`` on error.
  var pb = initProtoBuffer(message)
  if pb.getLengthValue(1, nonce) != -1 and
     pb.getLengthValue(2, pubkey) != -1 and
     pb.getLengthValue(3, exchanges) != -1 and
     pb.getLengthValue(4, ciphers) != -1 and
     pb.getLengthValue(5, hashes) != -1:
    result = true

proc createExchange*(epubkey, signature: openarray[byte]): seq[byte] =
  ## Create SecIO exchange message using ephemeral public key ``epubkey`` and
  ## signature of proposal blocks ``signature``.
  var msg = initProtoBuffer({WithUint32BeLength})
  msg.write(initProtoField(1, epubkey))
  msg.write(initProtoField(2, signature))
  msg.finish()
  shallowCopy(result, msg.buffer)

proc decodeExchange*(message: seq[byte],
                     pubkey, signature: var seq[byte]): bool =
  ## Parse incoming exchange message and decode remote ephemeral public key
  ## ``pubkey`` and signature ``signature``.
  ##
  ## Procedure returns ``true`` on success and ``false`` on error.
  var pb = initProtoBuffer(message)
  if pb.getLengthValue(1, pubkey) != -1 and
     pb.getLengthValue(2, signature) != -1:
    result = true

## Serialization/Deserialization helpers

proc write*(vb: var VBuffer, pubkey: PublicKey) {.inline.} =
  ## Write PublicKey value ``pubkey`` to buffer ``vb``.
  vb.writeSeq(pubkey.getBytes())

proc write*(vb: var VBuffer, seckey: PrivateKey) {.inline.} =
  ## Write PrivateKey value ``seckey`` to buffer ``vb``.
  vb.writeSeq(seckey.getBytes())

proc write*(vb: var VBuffer, sig: PrivateKey) {.inline.} =
  ## Write Signature value ``sig`` to buffer ``vb``.
  vb.writeSeq(sig.getBytes())

proc initProtoField*(index: int, pubkey: PublicKey): ProtoField =
  ## Initialize ProtoField with PublicKey ``pubkey``.
  result = initProtoField(index, pubkey.getBytes())

proc initProtoField*(index: int, seckey: PrivateKey): ProtoField =
  ## Initialize ProtoField with PrivateKey ``seckey``.
  result = initProtoField(index, seckey.getBytes())

proc initProtoField*(index: int, sig: Signature): ProtoField =
  ## Initialize ProtoField with Signature ``sig``.
  result = initProtoField(index, sig.getBytes())

proc getValue*(data: var ProtoBuffer, field: int, value: var PublicKey): int =
  ## Read ``PublicKey`` from ProtoBuf's message and validate it.
  var buf: seq[byte]
  var key: PublicKey
  result = getLengthValue(data, field, buf)
  if result > 0:
    if not key.init(buf):
      result = -1
    else:
      value = key

proc getValue*(data: var ProtoBuffer, field: int, value: var PrivateKey): int =
  ## Read ``PrivateKey`` from ProtoBuf's message and validate it.
  var buf: seq[byte]
  var key: PrivateKey
  result = getLengthValue(data, field, buf)
  if result > 0:
    if not key.init(buf):
      result = -1
    else:
      value = key

proc getValue*(data: var ProtoBuffer, field: int, value: var Signature): int =
  ## Read ``Signature`` from ProtoBuf's message and validate it.
  var buf: seq[byte]
  var sig: Signature
  result = getLengthValue(data, field, buf)
  if result > 0:
    if not sig.init(buf):
      result = -1
    else:
      value = sig
