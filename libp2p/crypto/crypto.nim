## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements Public Key and Private Key interface for libp2p.
import rsa, ecnist
import ed25519/ed25519
import ../protobuf/minprotobuf
import nimcrypto/[rijndael, blowfish, sha, sha2, hash, hmac, utils]

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
      discard
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
      discard
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

  P2pKeyError* = object of Exception

const
  SupportedSchemes* = {RSA, Ed25519, ECDSA}
  SupportedSchemesInt* = {int8(RSA), int8(Ed25519), int8(ECDSA)}

proc random*(t: typedesc[PrivateKey], scheme: PKScheme,
             bits = DefaultKeySize): PrivateKey =
  ## Generate random private key for scheme ``scheme``.
  ##
  ## ``bits`` is number of bits for RSA key, ``bits`` value must be in
  ## [512, 4096], default value is 2048 bits.
  assert(scheme in SupportedSchemes)
  result = PrivateKey(scheme: scheme)
  if scheme == RSA:
    result.rsakey = RsaPrivateKey.random(bits)
  elif scheme == Ed25519:
    result.edkey = EdPrivateKey.random()
  elif scheme == ECDSA:
    result.eckey = EcPrivateKey.random(Secp256r1)

proc random*(t: typedesc[KeyPair], scheme: PKScheme,
             bits = DefaultKeySize): KeyPair =
  ## Generate random key pair for scheme ``scheme``.
  ##
  ## ``bits`` is number of bits for RSA key, ``bits`` value must be in
  ## [512, 4096], default value is 2048 bits.
  assert(scheme in SupportedSchemes)
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

proc getKey*(key: PrivateKey): PublicKey =
  ## Get public key from corresponding private key ``key``.
  result = PublicKey(scheme: key.scheme)
  if key.scheme == RSA:
    result.rsakey = key.rsakey.getKey()
  elif key.scheme == Ed25519:
    result.edkey = key.edkey.getKey()
  elif key.scheme == ECDSA:
    result.eckey = key.eckey.getKey()

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

proc getRawBytes*(key: PrivateKey): seq[byte] =
  ## Return private key ``key`` in binary form (using scheme's own
  ## serialization).
  if key.scheme == RSA:
    result = key.rsakey.getBytes()
  elif key.scheme == Ed25519:
    result = key.edkey.getBytes()
  elif key.scheme == ECDSA:
    result = key.eckey.getBytes()

proc getRawBytes*(key: PublicKey): seq[byte] =
  ## Return public key ``key`` in binary form (using scheme's own
  ## serialization).
  if key.scheme == RSA:
    result = key.rsakey.getBytes()
  elif key.scheme == Ed25519:
    result = key.edkey.getBytes()
  elif key.scheme == ECDSA:
    result = key.eckey.getBytes()

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

proc init*(t: typedesc[PrivateKey], data: openarray[byte]): PrivateKey =
  ## Create new private key from libp2p's protobuf serialized binary form.
  if not result.init(data):
    raise newException(P2pKeyError, "Incorrect binary form")

proc init*(t: typedesc[PublicKey], data: openarray[byte]): PublicKey =
  ## Create new public key from libp2p's protobuf serialized binary form.
  if not result.init(data):
    raise newException(P2pKeyError, "Incorrect binary form")

proc init*(t: typedesc[PrivateKey], data: string): PrivateKey =
  ## Create new private key from libp2p's protobuf serialized hexadecimal string
  ## form.
  result = t.init(fromHex(data))

proc init*(t: typedesc[PublicKey], data: string): PublicKey =
  ## Create new public key from libp2p's protobuf serialized hexadecimal string
  ## form.
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

proc sign*(key: PrivateKey, data: openarray[byte]): seq[byte] =
  ## Sign message ``data`` using private key ``key`` and return generated
  ## signature in raw binary form.
  if key.scheme == RSA:
    var sig = key.rsakey.sign(data)
    result = sig.getBytes()
  elif key.scheme == Ed25519:
    var sig = key.edkey.sign(data)
    result = sig.getBytes()
  elif key.scheme == ECDSA:
    var sig = key.eckey.sign(data)
    result = sig.getBytes()

proc verify*(sig: openarray[byte], message: openarray[byte],
             key: PublicKey): bool =
  ## Verify signature ``sig`` using message ``message`` and public key ``key``.
  ## Return ``true`` if message signature is valid.
  if key.scheme == RSA:
    var signature: RsaSignature
    if signature.init(sig) == Asn1Status.Success:
      result = signature.verify(message, key.rsakey)
  elif key.scheme == Ed25519:
    var signature: EdSignature
    if signature.init(sig):
      result = signature.verify(message, key.edkey)
  elif key.scheme == ECDSA:
    var signature: EcSignature
    if signature.init(sig) == Asn1Status.Success:
      result = signature.verify(message, key.eckey)

template makeSecret(buffer, hmactype, secret, seed) =
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

proc stretchKeys*(cipherScheme: CipherScheme, hashScheme: DigestSheme,
                  secret: openarray[byte]): Secret =
  ## Expand shared secret to cryptographic keys.
  if cipherScheme == Aes128:
    result.ivsize = aes128.sizeBlock
    result.keysize = aes128.sizeKey
  elif cipherScheme == Aes256:
    result.ivsize = aes256.sizeBlock
    result.keysize = aes256.sizeKey
  elif cipherScheme == Blowfish:
    result.ivsize = 8
    result.keysize = 32

  var seed = "key expansion"
  result.macsize = 20
  let length = result.ivsize + result.keysize + result.macsize
  result.data = newSeq[byte](2 * length)

  if hashScheme == Sha256:
    makeSecret(result.data, HMAC[sha256], secret, seed)
  elif hashScheme == Sha512:
    makeSecret(result.data, HMAC[sha512], secret, seed)
  elif hashScheme == Sha1:
    makeSecret(result.data, HMAC[sha1], secret, seed)

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

proc makeSecret*(remoteEPublic: PublicKey, localEPrivate: PrivateKey,
                 data: var openarray[byte]): int =
  ## Calculate shared secret using remote ephemeral public key
  ## ``remoteEPublic`` and local ephemeral private key ``localEPrivate`` and
  ## store shared secret to ``data``
  ##
  ## Returns number of bytes (octets) used to store shared secret data, or
  ## ``0`` on error.
  if remoteEPublic.scheme == ECDSA:
    if localEPrivate.scheme == remoteEPublic.scheme:
      result = toSecret(remoteEPublic.eckey, localEPrivate.eckey, data)
