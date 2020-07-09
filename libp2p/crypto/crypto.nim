## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements Public Key and Private Key interface for libp2p.

{.push raises: [Defect].}

import rsa, ecnist, ed25519/ed25519, secp, bearssl
import ../protobuf/minprotobuf, ../vbuffer, ../multihash, ../multicodec
import nimcrypto/[rijndael, blowfish, twofish, sha2, hash, hmac, utils]
import ../utility
import stew/results
export results

# This is workaround for Nim's `import` bug
export rijndael, blowfish, twofish, sha2, hash, hmac, utils

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
    Sha256,
    Sha512

  ECDHEScheme* = EcCurveKind

  PublicKey* = object
    case scheme*: PKScheme
    of RSA:
      rsakey*: rsa.RsaPublicKey
    of Ed25519:
      edkey*: EdPublicKey
    of Secp256k1:
      skkey*: SkPublicKey
    of ECDSA:
      eckey*: ecnist.EcPublicKey
    of NoSupport:
      discard

  PrivateKey* = object
    case scheme*: PKScheme
    of RSA:
      rsakey*: rsa.RsaPrivateKey
    of Ed25519:
      edkey*: EdPrivateKey
    of Secp256k1:
      skkey*: SkPrivateKey
    of ECDSA:
      eckey*: ecnist.EcPrivateKey
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

  CryptoError* = enum
    KeyError,
    SigError,
    HashError,
    SchemeError

  CryptoResult*[T] = Result[T, CryptoError]

const
  SupportedSchemes* = {RSA, Ed25519, Secp256k1, ECDSA}
  SupportedSchemesInt* = {int8(RSA), int8(Ed25519), int8(Secp256k1),
                          int8(ECDSA)}

template orError*(exp: untyped, err: untyped): untyped =
  (exp.mapErr do (_: auto) -> auto: err)

proc newRng*(): ref BrHmacDrbgContext =
  # You should only create one instance of the RNG per application / library
  # Ref is used so that it can be shared between components
  # TODO consider moving to bearssl
  var seeder = brPrngSeederSystem(nil)
  if seeder == nil:
    return nil

  var rng = (ref BrHmacDrbgContext)()
  brHmacDrbgInit(addr rng[], addr sha256Vtable, nil, 0)
  if seeder(addr rng.vtable) == 0:
    return nil
  rng

proc random*(
    T: typedesc[PrivateKey], scheme: PKScheme,
    rng: var BrHmacDrbgContext, bits = DefaultKeySize): CryptoResult[PrivateKey] =
  ## Generate random private key for scheme ``scheme``.
  ##
  ## ``bits`` is number of bits for RSA key, ``bits`` value must be in
  ## [512, 4096], default value is 2048 bits.
  case scheme
  of RSA:
    let rsakey = ? RsaPrivateKey.random(rng, bits).orError(KeyError)
    ok(PrivateKey(scheme: scheme, rsakey: rsakey))
  of Ed25519:
    let edkey = EdPrivateKey.random(rng)
    ok(PrivateKey(scheme: scheme, edkey: edkey))
  of ECDSA:
    let eckey = ? ecnist.EcPrivateKey.random(Secp256r1, rng).orError(KeyError)
    ok(PrivateKey(scheme: scheme, eckey: eckey))
  of Secp256k1:
    let skkey = SkPrivateKey.random(rng)
    ok(PrivateKey(scheme: scheme, skkey: skkey))
  else:
    err(SchemeError)

proc random*(
    T: typedesc[KeyPair], scheme: PKScheme,
    rng: var BrHmacDrbgContext, bits = DefaultKeySize): CryptoResult[KeyPair] =
  ## Generate random key pair for scheme ``scheme``.
  ##
  ## ``bits`` is number of bits for RSA key, ``bits`` value must be in
  ## [512, 4096], default value is 2048 bits.
  case scheme
  of RSA:
    let pair = ? RsaKeyPair.random(rng, bits).orError(KeyError)
    ok(KeyPair(
      seckey: PrivateKey(scheme: scheme, rsakey: pair.seckey),
      pubkey: PublicKey(scheme: scheme, rsakey: pair.pubkey)))
  of Ed25519:
    let pair = EdKeyPair.random(rng)
    ok(KeyPair(
      seckey: PrivateKey(scheme: scheme, edkey: pair.seckey),
      pubkey: PublicKey(scheme: scheme, edkey: pair.pubkey)))
  of ECDSA:
    let pair = ? EcKeyPair.random(Secp256r1, rng).orError(KeyError)
    ok(KeyPair(
      seckey: PrivateKey(scheme: scheme, eckey: pair.seckey),
      pubkey: PublicKey(scheme: scheme, eckey: pair.pubkey)))
  of Secp256k1:
    let pair = SkKeyPair.random(rng)
    ok(KeyPair(
      seckey: PrivateKey(scheme: scheme, skkey: pair.seckey),
      pubkey: PublicKey(scheme: scheme, skkey: pair.pubkey)))
  else:
    err(SchemeError)

proc getKey*(key: PrivateKey): CryptoResult[PublicKey] =
  ## Get public key from corresponding private key ``key``.
  case key.scheme
  of RSA:
    let rsakey = key.rsakey.getKey()
    ok(PublicKey(scheme: RSA, rsakey: rsakey))
  of Ed25519:
    let edkey = key.edkey.getKey()
    ok(PublicKey(scheme: Ed25519, edkey: edkey))
  of ECDSA:
    let eckey = ? key.eckey.getKey().orError(KeyError)
    ok(PublicKey(scheme: ECDSA, eckey: eckey))
  of Secp256k1:
    let skkey = key.skkey.getKey()
    ok(PublicKey(scheme: Secp256k1, skkey: skkey))
  else:
    err(KeyError)

proc toRawBytes*(key: PrivateKey | PublicKey,
                 data: var openarray[byte]): CryptoResult[int] =
  ## Serialize private key ``key`` (using scheme's own serialization) and store
  ## it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store private key ``key``.
  case key.scheme
  of RSA:
    key.rsakey.toBytes(data).orError(KeyError)
  of Ed25519:
    ok(key.edkey.toBytes(data))
  of ECDSA:
    key.eckey.toBytes(data).orError(KeyError)
  of Secp256k1:
    key.skkey.toBytes(data).orError(KeyError)
  else:
    err(KeyError)

proc getRawBytes*(key: PrivateKey | PublicKey): CryptoResult[seq[byte]] =
  ## Return private key ``key`` in binary form (using scheme's own
  ## serialization).
  case key.scheme
  of RSA:
    key.rsakey.getBytes().orError(KeyError)
  of Ed25519:
    ok(key.edkey.getBytes())
  of ECDSA:
    key.eckey.getBytes().orError(KeyError)
  of Secp256k1:
    ok(key.skkey.getBytes())
  else:
    err(KeyError)

proc toBytes*(key: PrivateKey, data: var openarray[byte]): CryptoResult[int] =
  ## Serialize private key ``key`` (using libp2p protobuf scheme) and store
  ## it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store private key ``key``.
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, cast[uint64](key.scheme)))
  msg.write(initProtoField(2, ? key.getRawBytes()))
  msg.finish()
  var blen = len(msg.buffer)
  if len(data) >= blen:
    copyMem(addr data[0], addr msg.buffer[0], blen)
  ok(blen)

proc toBytes*(key: PublicKey, data: var openarray[byte]): CryptoResult[int] =
  ## Serialize public key ``key`` (using libp2p protobuf scheme) and store
  ## it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store public key ``key``.
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, cast[uint64](key.scheme)))
  msg.write(initProtoField(2, ? key.getRawBytes()))
  msg.finish()
  var blen = len(msg.buffer)
  if len(data) >= blen and blen > 0:
    copyMem(addr data[0], addr msg.buffer[0], blen)
  ok(blen)

proc toBytes*(sig: Signature, data: var openarray[byte]): int =
  ## Serialize signature ``sig`` and store it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store signature ``sig``.
  result = len(sig.data)
  if len(data) >= result and result > 0:
    copyMem(addr data[0], unsafeAddr sig.data[0], len(sig.data))

proc getBytes*(key: PrivateKey): CryptoResult[seq[byte]] =
  ## Return private key ``key`` in binary form (using libp2p's protobuf
  ## serialization).
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, cast[uint64](key.scheme)))
  msg.write(initProtoField(2, ? key.getRawBytes()))
  msg.finish()
  ok(msg.buffer)

proc getBytes*(key: PublicKey): CryptoResult[seq[byte]] =
  ## Return public key ``key`` in binary form (using libp2p's protobuf
  ## serialization).
  var msg = initProtoBuffer()
  msg.write(initProtoField(1, cast[uint64](key.scheme)))
  msg.write(initProtoField(2, ? key.getRawBytes()))
  msg.finish()
  ok(msg.buffer)

proc getBytes*(sig: Signature): seq[byte] =
  ## Return signature ``sig`` in binary form.
  result = sig.data

proc init*[T: PrivateKey|PublicKey](key: var T, data: openarray[byte]): bool =
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
          when key is PrivateKey:
            var nkey = PrivateKey(scheme: scheme)
          else:
            var nkey = PublicKey(scheme: scheme)
          case scheme:
          of PKScheme.RSA:
            if init(nkey.rsakey, buffer).isOk:
              key = nkey
              return true
          of PKScheme.Ed25519:
            if init(nkey.edkey, buffer):
              key = nkey
              return true
          of PKScheme.ECDSA:
            if init(nkey.eckey, buffer).isOk:
              key = nkey
              return true
          of PKScheme.Secp256k1:
            if init(nkey.skkey, buffer).isOk:
              key = nkey
              return true
          else:
            return false

proc init*(sig: var Signature, data: openarray[byte]): bool =
  ## Initialize signature ``sig`` from raw binary form.
  ##
  ## Returns ``true`` on success.
  if len(data) > 0:
    sig.data = @data
    result = true

proc init*[T: PrivateKey|PublicKey](key: var T, data: string): bool =
  ## Initialize private/public key ``key`` from libp2p's protobuf serialized
  ## hexadecimal string representation.
  ##
  ## Returns ``true`` on success.
  try:
    key.init(fromHex(data))
  except ValueError:
    false

proc init*(sig: var Signature, data: string): bool =
  ## Initialize signature ``sig`` from serialized hexadecimal string
  ## representation.
  ##
  ## Returns ``true`` on success.
  try:
    sig.init(fromHex(data))
  except ValueError:
    false

proc init*(t: typedesc[PrivateKey],
           data: openarray[byte]): CryptoResult[PrivateKey] =
  ## Create new private key from libp2p's protobuf serialized binary form.
  var res: t
  if not res.init(data):
    err(KeyError)
  else:
    ok(res)

proc init*(t: typedesc[PublicKey],
           data: openarray[byte]): CryptoResult[PublicKey] =
  ## Create new public key from libp2p's protobuf serialized binary form.
  var res: t
  if not res.init(data):
    err(KeyError)
  else:
    ok(res)

proc init*(t: typedesc[Signature],
           data: openarray[byte]): CryptoResult[Signature] =
  ## Create new public key from libp2p's protobuf serialized binary form.
  var res: t
  if not res.init(data):
    err(SigError)
  else:
    ok(res)

proc init*(t: typedesc[PrivateKey], data: string): CryptoResult[PrivateKey] =
  ## Create new private key from libp2p's protobuf serialized hexadecimal string
  ## form.
  try:
    t.init(fromHex(data))
  except ValueError:
    err(KeyError)

proc init*(t: typedesc[PrivateKey], key: rsa.RsaPrivateKey): PrivateKey =
  PrivateKey(scheme: RSA, rsakey: key)
proc init*(t: typedesc[PrivateKey], key: EdPrivateKey): PrivateKey =
  PrivateKey(scheme: Ed25519, edkey: key)
proc init*(t: typedesc[PrivateKey], key: SkPrivateKey): PrivateKey =
  PrivateKey(scheme: Secp256k1, skkey: key)
proc init*(t: typedesc[PrivateKey], key: ecnist.EcPrivateKey): PrivateKey =
  PrivateKey(scheme: ECDSA, eckey: key)

proc init*(t: typedesc[PublicKey], key: rsa.RsaPublicKey): PublicKey =
  PublicKey(scheme: RSA, rsakey: key)
proc init*(t: typedesc[PublicKey], key: EdPublicKey): PublicKey =
  PublicKey(scheme: Ed25519, edkey: key)
proc init*(t: typedesc[PublicKey], key: SkPublicKey): PublicKey =
  PublicKey(scheme: Secp256k1, skkey: key)
proc init*(t: typedesc[PublicKey], key: ecnist.EcPublicKey): PublicKey =
  PublicKey(scheme: ECDSA, eckey: key)

proc init*(t: typedesc[PublicKey], data: string): CryptoResult[PublicKey] =
  ## Create new public key from libp2p's protobuf serialized hexadecimal string
  ## form.
  try:
    t.init(fromHex(data))
  except ValueError:
    err(KeyError)

proc init*(t: typedesc[Signature], data: string): CryptoResult[Signature] =
  ## Create new signature from serialized hexadecimal string form.
  try:
    t.init(fromHex(data))
  except ValueError:
    err(SigError)

proc `==`*(key1, key2: PublicKey): bool {.inline.} =
  ## Return ``true`` if two public keys ``key1`` and ``key2`` of the same
  ## scheme and equal.
  if key1.scheme == key2.scheme:
    case key1.scheme
    of PKScheme.RSA:
      (key1.rsakey == key2.rsakey)
    of PKScheme.Ed25519:
      (key1.edkey == key2.edkey)
    of PKScheme.ECDSA:
      (key1.eckey == key2.eckey)
    of PKScheme.Secp256k1:
      (key1.skkey == key2.skkey)
    of PKScheme.NoSupport:
      false
  else:
    false

proc `==`*(key1, key2: PrivateKey): bool =
  ## Return ``true`` if two private keys ``key1`` and ``key2`` of the same
  ## scheme and equal.
  if key1.scheme == key2.scheme:
    case key1.scheme
    of PKScheme.RSA:
      (key1.rsakey == key2.rsakey)
    of PKScheme.Ed25519:
      (key1.edkey == key2.edkey)
    of PKScheme.ECDSA:
      (key1.eckey == key2.eckey)
    of PKScheme.Secp256k1:
      (key1.skkey == key2.skkey)
    of PKScheme.NoSupport:
      false
  else:
    false

proc `$`*(key: PrivateKey|PublicKey): string =
  ## Get string representation of private/public key ``key``.
  case key.scheme:
  of PKScheme.RSA:
    $(key.rsakey)
  of PKScheme.Ed25519:
    "ed25519 key (" & $key.edkey & ")"
  of PKScheme.ECDSA:
    "secp256r1 key (" & $key.eckey & ")"
  of PKScheme.Secp256k1:
    "secp256k1 key (" & $key.skkey & ")"
  of PKScheme.NoSupport:
    "not supported"

func shortLog*(key: PrivateKey|PublicKey): string =
  ## Get short string representation of private/public key ``key``.
  case key.scheme:
  of PKScheme.RSA:
    ($key.rsakey).shortLog
  of PKScheme.Ed25519:
    "ed25519 key (" & ($key.edkey).shortLog & ")"
  of PKScheme.ECDSA:
    "secp256r1 key (" & ($key.eckey).shortLog & ")"
  of PKScheme.Secp256k1:
    "secp256k1 key (" & ($key.skkey).shortLog & ")"
  of PKScheme.NoSupport:
    "not supported"

proc `$`*(sig: Signature): string =
  ## Get string representation of signature ``sig``.
  result = toHex(sig.data)

proc sign*(key: PrivateKey,
           data: openarray[byte]): CryptoResult[Signature] {.gcsafe.} =
  ## Sign message ``data`` using private key ``key`` and return generated
  ## signature in raw binary form.
  var res: Signature
  case key.scheme:
  of PKScheme.RSA:
    let sig = ? key.rsakey.sign(data).orError(SigError)
    res.data = ? sig.getBytes().orError(SigError)
    ok(res)
  of PKScheme.Ed25519:
    let sig = key.edkey.sign(data)
    res.data = sig.getBytes()
    ok(res)
  of PKScheme.ECDSA:
    let sig = ? key.eckey.sign(data).orError(SigError)
    res.data = ? sig.getBytes().orError(SigError)
    ok(res)
  of PKScheme.Secp256k1:
    let sig = key.skkey.sign(data)
    res.data = sig.getBytes()
    ok(res)
  else:
    err(SigError)

proc verify*(sig: Signature, message: openarray[byte], key: PublicKey): bool =
  ## Verify signature ``sig`` using message ``message`` and public key ``key``.
  ## Return ``true`` if message signature is valid.
  case key.scheme:
  of PKScheme.RSA:
    var signature: RsaSignature
    if signature.init(sig.data).isOk:
      signature.verify(message, key.rsakey)
    else:
      false
  of PKScheme.Ed25519:
    var signature: EdSignature
    if signature.init(sig.data):
      signature.verify(message, key.edkey)
    else:
      false
  of PKScheme.ECDSA:
    var signature: EcSignature
    if signature.init(sig.data).isOk:
      signature.verify(message, key.eckey)
    else:
      false
  of PKScheme.Secp256k1:
    var signature: SkSignature
    if signature.init(sig.data).isOk:
      signature.verify(message, key.skkey)
    else:
      false
  else:
    false

template makeSecret(buffer, hmactype, secret, seed: untyped) {.dirty.}=
  var ctx: hmactype
  var j = 0
  # We need to strip leading zeros, because Go bigint serialization do it.
  var offset = 0
  for i in 0..<len(secret):
    if secret[i] != 0x00'u8:
      break
    inc(offset)
  ctx.init(secret.toOpenArray(offset, secret.high))
  ctx.update(seed)
  var a = ctx.finish()
  while j < len(buffer):
    ctx.init(secret.toOpenArray(offset, secret.high))
    ctx.update(a.data)
    ctx.update(seed)
    var b = ctx.finish()
    var todo = len(b.data)
    if j + todo > len(buffer):
      todo = len(buffer) - j
    copyMem(addr buffer[j], addr b.data[0], todo)
    j += todo
    ctx.init(secret.toOpenArray(offset, secret.high))
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
  elif cipherType == "TwofishCTR":
    result.ivsize = twofish256.sizeBlock
    result.keysize = twofish256.sizeKey
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

proc ephemeral*(
    scheme: ECDHEScheme,
    rng: var BrHmacDrbgContext): CryptoResult[KeyPair] =
  ## Generate ephemeral keys used to perform ECDHE.
  var keypair: EcKeyPair
  if scheme == Secp256r1:
    keypair = ? EcKeyPair.random(Secp256r1, rng).orError(KeyError)
  elif scheme == Secp384r1:
    keypair = ? EcKeyPair.random(Secp384r1, rng).orError(KeyError)
  elif scheme == Secp521r1:
    keypair = ? EcKeyPair.random(Secp521r1, rng).orError(KeyError)
  ok(KeyPair(
    seckey: PrivateKey(scheme: ECDSA, eckey: keypair.seckey),
    pubkey: PublicKey(scheme: ECDSA, eckey: keypair.pubkey)))

proc ephemeral*(
    scheme: string, rng: var BrHmacDrbgContext): CryptoResult[KeyPair] =
  ## Generate ephemeral keys used to perform ECDHE using string encoding.
  ##
  ## Currently supported encoding strings are P-256, P-384, P-521, if encoding
  ## string is not supported P-521 key will be generated.
  if scheme == "P-256":
    ephemeral(Secp256r1, rng)
  elif scheme == "P-384":
    ephemeral(Secp384r1, rng)
  elif scheme == "P-521":
    ephemeral(Secp521r1, rng)
  else:
    ephemeral(Secp521r1, rng)

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
               localPubkey, remoteNonce: openarray[byte]): CryptoResult[int] =
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
  var mh1 = ? MultiHash.init(multiCodec("sha2-256"), digest1).orError(HashError)
  var mh2 = ? MultiHash.init(multiCodec("sha2-256"), digest2).orError(HashError)
  var res = 0;
  for i in 0 ..< len(mh1.data.buffer):
    res = int(mh1.data.buffer[i]) - int(mh2.data.buffer[i])
    if res != 0:
      if res < 0:
        res = -1
      elif res > 0:
        res = 1
      break
  ok(res)

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

proc write*(vb: var VBuffer, pubkey: PublicKey) {.
     inline, raises: [Defect, ResultError[CryptoError]].} =
  ## Write PublicKey value ``pubkey`` to buffer ``vb``.
  vb.writeSeq(pubkey.getBytes().tryGet())

proc write*(vb: var VBuffer, seckey: PrivateKey) {.
     inline, raises: [Defect, ResultError[CryptoError]].} =
  ## Write PrivateKey value ``seckey`` to buffer ``vb``.
  vb.writeSeq(seckey.getBytes().tryGet())

proc write*(vb: var VBuffer, sig: PrivateKey) {.
     inline, raises: [Defect, ResultError[CryptoError]].} =
  ## Write Signature value ``sig`` to buffer ``vb``.
  vb.writeSeq(sig.getBytes().tryGet())

proc initProtoField*(index: int, pubkey: PublicKey): ProtoField {.
     raises: [Defect, ResultError[CryptoError]].} =
  ## Initialize ProtoField with PublicKey ``pubkey``.
  result = initProtoField(index, pubkey.getBytes().tryGet())

proc initProtoField*(index: int, seckey: PrivateKey): ProtoField {.
     raises: [Defect, ResultError[CryptoError]].} =
  ## Initialize ProtoField with PrivateKey ``seckey``.
  result = initProtoField(index, seckey.getBytes().tryGet())

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
