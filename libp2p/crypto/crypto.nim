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

from strutils import split, strip, cmpIgnoreCase

const libp2p_pki_schemes* {.strdefine.} = "rsa,ed25519,secp256k1,ecnist"

type
  PKScheme* = enum
    RSA = 0,
    Ed25519,
    Secp256k1,
    ECDSA

proc initSupportedSchemes(list: static string): set[PKScheme] =
  var res: set[PKScheme]

  let schemes = split(list, {',', ';', '|'})
  for item in schemes:
    if cmpIgnoreCase(strip(item), "rsa") == 0:
      res.incl(PKScheme.RSA)
    elif cmpIgnoreCase(strip(item), "ed25519") == 0:
      res.incl(PKScheme.Ed25519)
    elif cmpIgnoreCase(strip(item), "secp256k1") == 0:
      res.incl(PKScheme.Secp256k1)
    elif cmpIgnoreCase(strip(item), "ecnist") == 0:
      res.incl(PKScheme.ECDSA)
  if len(res) == 0:
    res = {PKScheme.RSA, PKScheme.Ed25519, PKScheme.Secp256k1, PKScheme.ECDSA}
  res

proc initSupportedSchemes(schemes: static set[PKScheme]): set[int8] =
  var res: set[int8]
  if PKScheme.RSA in schemes:
    res.incl(int8(PKScheme.RSA))
  if PKScheme.Ed25519 in schemes:
    res.incl(int8(PKScheme.Ed25519))
  if PKScheme.Secp256k1 in schemes:
    res.incl(int8(PKScheme.Secp256k1))
  if PKScheme.ECDSA in schemes:
    res.incl(int8(PKScheme.ECDSA))
  res

const
  SupportedSchemes* = initSupportedSchemes(libp2p_pki_schemes)
  SupportedSchemesInt* = initSupportedSchemes(SupportedSchemes)
  RsaDefaultKeySize* = 3072

template supported*(scheme: PKScheme): bool =
  ## Returns true if specified ``scheme`` is currently available.
  scheme in SupportedSchemes

when supported(PKScheme.RSA):
  import rsa
when supported(PKScheme.Ed25519):
  import ed25519/ed25519
when supported(PKScheme.Secp256k1):
  import secp

# We are still importing `ecnist` because, it is used for SECIO handshake,
# but it will be impossible to create ECNIST keys or import ECNIST keys.

import ecnist, bearssl
import ../protobuf/minprotobuf, ../vbuffer, ../multihash, ../multicodec
import nimcrypto/[rijndael, twofish, sha2, hash, hmac]
# We use `ncrutils` for constant-time hexadecimal encoding/decoding procedures.
import nimcrypto/utils as ncrutils
import ../utility
import stew/results
export results

# This is workaround for Nim's `import` bug
export rijndael, twofish, sha2, hash, hmac, ncrutils

from strutils import split

type
  DigestSheme* = enum
    Sha256,
    Sha512

  ECDHEScheme* = EcCurveKind

  PublicKey* = object
    case scheme*: PKScheme
    of PKScheme.RSA:
      when PKScheme.RSA in SupportedSchemes:
        rsakey*: rsa.RsaPublicKey
      else:
        discard
    of PKScheme.Ed25519:
      when supported(PKScheme.Ed25519):
        edkey*: EdPublicKey
      else:
        discard
    of PKScheme.Secp256k1:
      when supported(PKScheme.Secp256k1):
        skkey*: SkPublicKey
      else:
        discard
    of PKScheme.ECDSA:
      when supported(PKScheme.ECDSA):
        eckey*: ecnist.EcPublicKey
      else:
        discard

  PrivateKey* = object
    case scheme*: PKScheme
    of PKScheme.RSA:
      when supported(PKScheme.RSA):
        rsakey*: rsa.RsaPrivateKey
      else:
        discard
    of PKScheme.Ed25519:
      when supported(PKScheme.Ed25519):
        edkey*: EdPrivateKey
      else:
        discard
    of PKScheme.Secp256k1:
      when supported(PKScheme.Secp256k1):
        skkey*: SkPrivateKey
      else:
        discard
    of PKScheme.ECDSA:
      when supported(PKScheme.ECDSA):
        eckey*: ecnist.EcPrivateKey
      else:
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

proc shuffle*[T](
  rng: ref BrHmacDrbgContext,
  x: var openArray[T]) =

  var randValues = newSeqUninitialized[byte](len(x) * 2)
  brHmacDrbgGenerate(rng[], randValues)

  for i in countdown(x.high, 1):
    let
      rand = randValues[i * 2].int32 or (randValues[i * 2 + 1].int32 shl 8)
      y = rand mod i
    swap(x[i], x[y])

proc random*(T: typedesc[PrivateKey], scheme: PKScheme,
             rng: var BrHmacDrbgContext,
             bits = RsaDefaultKeySize): CryptoResult[PrivateKey] =
  ## Generate random private key for scheme ``scheme``.
  ##
  ## ``bits`` is number of bits for RSA key, ``bits`` value must be in
  ## [2048, 4096], default value is 3072 bits.
  case scheme
  of PKScheme.RSA:
    when supported(PKScheme.RSA):
      let rsakey = ? RsaPrivateKey.random(rng, bits).orError(KeyError)
      ok(PrivateKey(scheme: scheme, rsakey: rsakey))
    else:
      err(SchemeError)
  of PKScheme.Ed25519:
    when supported(PKScheme.Ed25519):
      let edkey = EdPrivateKey.random(rng)
      ok(PrivateKey(scheme: scheme, edkey: edkey))
    else:
      err(SchemeError)
  of PKScheme.ECDSA:
    when supported(PKScheme.ECDSA):
      let eckey = ? ecnist.EcPrivateKey.random(Secp256r1, rng).orError(KeyError)
      ok(PrivateKey(scheme: scheme, eckey: eckey))
    else:
      err(SchemeError)
  of PKScheme.Secp256k1:
    when supported(PKScheme.Secp256k1):
      let skkey = SkPrivateKey.random(rng)
      ok(PrivateKey(scheme: scheme, skkey: skkey))
    else:
      err(SchemeError)

proc random*(T: typedesc[PrivateKey], rng: var BrHmacDrbgContext,
             bits = RsaDefaultKeySize): CryptoResult[PrivateKey] =
  ## Generate random private key using default public-key cryptography scheme.
  ##
  ## Default public-key cryptography schemes are following order:
  ## ed25519, secp256k1, RSA, secp256r1.
  ##
  ## So will be used first available (supported) method.
  when supported(PKScheme.Ed25519):
    let edkey = EdPrivateKey.random(rng)
    ok(PrivateKey(scheme: PKScheme.Ed25519, edkey: edkey))
  elif supported(PKScheme.Secp256k1):
    let skkey = SkPrivateKey.random(rng)
    ok(PrivateKey(scheme: PKScheme.Secp256k1, skkey: skkey))
  elif supported(PKScheme.RSA):
    let rsakey = ? RsaPrivateKey.random(rng, bits).orError(KeyError)
    ok(PrivateKey(scheme: PKScheme.RSA, rsakey: rsakey))
  elif supported(PKScheme.ECDSA):
    let eckey = ? ecnist.EcPrivateKey.random(Secp256r1, rng).orError(KeyError)
    ok(PrivateKey(scheme: PKScheme.ECDSA, eckey: eckey))
  else:
    err(SchemeError)

proc random*(T: typedesc[KeyPair], scheme: PKScheme,
             rng: var BrHmacDrbgContext,
             bits = RsaDefaultKeySize): CryptoResult[KeyPair] =
  ## Generate random key pair for scheme ``scheme``.
  ##
  ## ``bits`` is number of bits for RSA key, ``bits`` value must be in
  ## [512, 4096], default value is 2048 bits.
  case scheme
  of PKScheme.RSA:
    when supported(PKScheme.RSA):
      let pair = ? RsaKeyPair.random(rng, bits).orError(KeyError)
      ok(KeyPair(
        seckey: PrivateKey(scheme: scheme, rsakey: pair.seckey),
        pubkey: PublicKey(scheme: scheme, rsakey: pair.pubkey)))
    else:
      err(SchemeError)
  of PKScheme.Ed25519:
    when supported(PKScheme.Ed25519):
      let pair = EdKeyPair.random(rng)
      ok(KeyPair(
        seckey: PrivateKey(scheme: scheme, edkey: pair.seckey),
        pubkey: PublicKey(scheme: scheme, edkey: pair.pubkey)))
    else:
      err(SchemeError)
  of PKScheme.ECDSA:
    when supported(PKScheme.ECDSA):
      let pair = ? EcKeyPair.random(Secp256r1, rng).orError(KeyError)
      ok(KeyPair(
        seckey: PrivateKey(scheme: scheme, eckey: pair.seckey),
        pubkey: PublicKey(scheme: scheme, eckey: pair.pubkey)))
    else:
      err(SchemeError)
  of PKScheme.Secp256k1:
    when supported(PKScheme.Secp256k1):
      let pair = SkKeyPair.random(rng)
      ok(KeyPair(
        seckey: PrivateKey(scheme: scheme, skkey: pair.seckey),
        pubkey: PublicKey(scheme: scheme, skkey: pair.pubkey)))
    else:
      err(SchemeError)

proc random*(T: typedesc[KeyPair], rng: var BrHmacDrbgContext,
             bits = RsaDefaultKeySize): CryptoResult[KeyPair] =
  ## Generate random private pair of keys using default public-key cryptography
  ## scheme.
  ##
  ## Default public-key cryptography schemes are following order:
  ## ed25519, secp256k1, RSA, secp256r1.
  ##
  ## So will be used first available (supported) method.
  when supported(PKScheme.Ed25519):
    let pair = EdKeyPair.random(rng)
    ok(KeyPair(
      seckey: PrivateKey(scheme: PKScheme.Ed25519, edkey: pair.seckey),
      pubkey: PublicKey(scheme: PKScheme.Ed25519, edkey: pair.pubkey)))
  elif supported(PKScheme.Secp256k1):
    let pair = SkKeyPair.random(rng)
    ok(KeyPair(
      seckey: PrivateKey(scheme: PKScheme.Secp256k1, skkey: pair.seckey),
      pubkey: PublicKey(scheme: PKScheme.Secp256k1, skkey: pair.pubkey)))
  elif supported(PKScheme.RSA):
    let pair = ? RsaKeyPair.random(rng, bits).orError(KeyError)
    ok(KeyPair(
      seckey: PrivateKey(scheme: PKScheme.RSA, rsakey: pair.seckey),
      pubkey: PublicKey(scheme: PKScheme.RSA, rsakey: pair.pubkey)))
  elif supported(PKScheme.ECDSA):
    let pair = ? EcKeyPair.random(Secp256r1, rng).orError(KeyError)
    ok(KeyPair(
      seckey: PrivateKey(scheme: PKScheme.ECDSA, eckey: pair.seckey),
      pubkey: PublicKey(scheme: PKScheme.ECDSA, eckey: pair.pubkey)))
  else:
    err(SchemeError)

proc getPublicKey*(key: PrivateKey): CryptoResult[PublicKey] =
  ## Get public key from corresponding private key ``key``.
  case key.scheme
  of PKScheme.RSA:
    when supported(PKScheme.RSA):
      let rsakey = key.rsakey.getPublicKey()
      ok(PublicKey(scheme: RSA, rsakey: rsakey))
    else:
      err(SchemeError)
  of PKScheme.Ed25519:
    when supported(PKScheme.Ed25519):
      let edkey = key.edkey.getPublicKey()
      ok(PublicKey(scheme: Ed25519, edkey: edkey))
    else:
      err(SchemeError)
  of PKScheme.ECDSA:
    when supported(PKScheme.ECDSA):
      let eckey = ? key.eckey.getPublicKey().orError(KeyError)
      ok(PublicKey(scheme: ECDSA, eckey: eckey))
    else:
      err(SchemeError)
  of PKScheme.Secp256k1:
    when supported(PKScheme.Secp256k1):
      let skkey = key.skkey.getPublicKey()
      ok(PublicKey(scheme: Secp256k1, skkey: skkey))
    else:
      err(SchemeError)

proc toRawBytes*(key: PrivateKey | PublicKey,
                 data: var openArray[byte]): CryptoResult[int] =
  ## Serialize private key ``key`` (using scheme's own serialization) and store
  ## it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store private key ``key``.
  case key.scheme
  of PKScheme.RSA:
    when supported(PKScheme.RSA):
      key.rsakey.toBytes(data).orError(KeyError)
    else:
      err(SchemeError)
  of PKScheme.Ed25519:
    when supported(PKScheme.Ed25519):
      ok(key.edkey.toBytes(data))
    else:
      err(SchemeError)
  of PKScheme.ECDSA:
    when supported(PKScheme.ECDSA):
      key.eckey.toBytes(data).orError(KeyError)
    else:
      err(SchemeError)
  of PKScheme.Secp256k1:
    when supported(PKScheme.Secp256k1):
      key.skkey.toBytes(data).orError(KeyError)
    else:
      err(SchemeError)

proc getRawBytes*(key: PrivateKey | PublicKey): CryptoResult[seq[byte]] =
  ## Return private key ``key`` in binary form (using scheme's own
  ## serialization).
  case key.scheme
  of PKScheme.RSA:
    when supported(PKScheme.RSA):
      key.rsakey.getBytes().orError(KeyError)
    else:
      err(SchemeError)
  of PKScheme.Ed25519:
    when supported(PKScheme.Ed25519):
      ok(key.edkey.getBytes())
    else:
      err(SchemeError)
  of PKScheme.ECDSA:
    when supported(PKScheme.ECDSA):
      key.eckey.getBytes().orError(KeyError)
    else:
      err(SchemeError)
  of PKScheme.Secp256k1:
    when supported(PKScheme.Secp256k1):
      ok(key.skkey.getBytes())
    else:
      err(SchemeError)

proc toBytes*(key: PrivateKey, data: var openArray[byte]): CryptoResult[int] =
  ## Serialize private key ``key`` (using libp2p protobuf scheme) and store
  ## it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store private key ``key``.
  var msg = initProtoBuffer()
  msg.write(1, uint64(key.scheme))
  msg.write(2, ? key.getRawBytes())
  msg.finish()
  var blen = len(msg.buffer)
  if len(data) >= blen:
    copyMem(addr data[0], addr msg.buffer[0], blen)
  ok(blen)

proc toBytes*(key: PublicKey, data: var openArray[byte]): CryptoResult[int] =
  ## Serialize public key ``key`` (using libp2p protobuf scheme) and store
  ## it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store public key ``key``.
  var msg = initProtoBuffer()
  msg.write(1, uint64(key.scheme))
  msg.write(2, ? key.getRawBytes())
  msg.finish()
  var blen = len(msg.buffer)
  if len(data) >= blen and blen > 0:
    copyMem(addr data[0], addr msg.buffer[0], blen)
  ok(blen)

proc toBytes*(sig: Signature, data: var openArray[byte]): int =
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
  msg.write(1, uint64(key.scheme))
  msg.write(2, ? key.getRawBytes())
  msg.finish()
  ok(msg.buffer)

proc getBytes*(key: PublicKey): CryptoResult[seq[byte]] =
  ## Return public key ``key`` in binary form (using libp2p's protobuf
  ## serialization).
  var msg = initProtoBuffer()
  msg.write(1, uint64(key.scheme))
  msg.write(2, ? key.getRawBytes())
  msg.finish()
  ok(msg.buffer)

proc getBytes*(sig: Signature): seq[byte] =
  ## Return signature ``sig`` in binary form.
  result = sig.data

proc init*[T: PrivateKey|PublicKey](key: var T, data: openArray[byte]): bool =
  ## Initialize private key ``key`` from libp2p's protobuf serialized raw
  ## binary form.
  ##
  ## Returns ``true`` on success.
  var id: uint64
  var buffer: seq[byte]
  if len(data) <= 0:
    false
  else:
    var pb = initProtoBuffer(@data)
    let r1 = pb.getField(1, id)
    let r2 = pb.getField(2, buffer)
    if not(r1.isOk() and r1.get() and r2.isOk() and r2.get()):
      false
    else:
      if cast[int8](id) notin SupportedSchemesInt or len(buffer) <= 0:
        false
      else:
        var scheme = cast[PKScheme](cast[int8](id))
        when key is PrivateKey:
          var nkey = PrivateKey(scheme: scheme)
        else:
          var nkey = PublicKey(scheme: scheme)
        case scheme:
        of PKScheme.RSA:
          when supported(PKScheme.RSA):
            if init(nkey.rsakey, buffer).isOk:
              key = nkey
              true
            else:
              false
          else:
            false
        of PKScheme.Ed25519:
          when supported(PKScheme.Ed25519):
            if init(nkey.edkey, buffer):
              key = nkey
              true
            else:
              false
          else:
            false
        of PKScheme.ECDSA:
          when supported(PKScheme.ECDSA):
            if init(nkey.eckey, buffer).isOk:
              key = nkey
              true
            else:
              false
          else:
            false
        of PKScheme.Secp256k1:
          when supported(PKScheme.Secp256k1):
            if init(nkey.skkey, buffer).isOk:
              key = nkey
              true
            else:
              false
          else:
            false

proc init*(sig: var Signature, data: openArray[byte]): bool =
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
  key.init(ncrutils.fromHex(data))

proc init*(sig: var Signature, data: string): bool =
  ## Initialize signature ``sig`` from serialized hexadecimal string
  ## representation.
  ##
  ## Returns ``true`` on success.
  sig.init(ncrutils.fromHex(data))

proc init*(t: typedesc[PrivateKey],
           data: openArray[byte]): CryptoResult[PrivateKey] =
  ## Create new private key from libp2p's protobuf serialized binary form.
  var res: t
  if not res.init(data):
    err(KeyError)
  else:
    ok(res)

proc init*(t: typedesc[PublicKey],
           data: openArray[byte]): CryptoResult[PublicKey] =
  ## Create new public key from libp2p's protobuf serialized binary form.
  var res: t
  if not res.init(data):
    err(KeyError)
  else:
    ok(res)

proc init*(t: typedesc[Signature],
           data: openArray[byte]): CryptoResult[Signature] =
  ## Create new public key from libp2p's protobuf serialized binary form.
  var res: t
  if not res.init(data):
    err(SigError)
  else:
    ok(res)

proc init*(t: typedesc[PrivateKey], data: string): CryptoResult[PrivateKey] =
  ## Create new private key from libp2p's protobuf serialized hexadecimal string
  ## form.
  t.init(ncrutils.fromHex(data))

when supported(PKScheme.RSA):
  proc init*(t: typedesc[PrivateKey], key: rsa.RsaPrivateKey): PrivateKey =
    PrivateKey(scheme: RSA, rsakey: key)
  proc init*(t: typedesc[PublicKey], key: rsa.RsaPublicKey): PublicKey =
    PublicKey(scheme: RSA, rsakey: key)

when supported(PKScheme.Ed25519):
  proc init*(t: typedesc[PrivateKey], key: EdPrivateKey): PrivateKey =
    PrivateKey(scheme: Ed25519, edkey: key)
  proc init*(t: typedesc[PublicKey], key: EdPublicKey): PublicKey =
    PublicKey(scheme: Ed25519, edkey: key)

when supported(PKScheme.Secp256k1):
  proc init*(t: typedesc[PrivateKey], key: SkPrivateKey): PrivateKey =
    PrivateKey(scheme: Secp256k1, skkey: key)
  proc init*(t: typedesc[PublicKey], key: SkPublicKey): PublicKey =
    PublicKey(scheme: Secp256k1, skkey: key)

when supported(PKScheme.ECDSA):
  proc init*(t: typedesc[PrivateKey], key: ecnist.EcPrivateKey): PrivateKey =
    PrivateKey(scheme: ECDSA, eckey: key)
  proc init*(t: typedesc[PublicKey], key: ecnist.EcPublicKey): PublicKey =
    PublicKey(scheme: ECDSA, eckey: key)

proc init*(t: typedesc[PublicKey], data: string): CryptoResult[PublicKey] =
  ## Create new public key from libp2p's protobuf serialized hexadecimal string
  ## form.
  t.init(ncrutils.fromHex(data))

proc init*(t: typedesc[Signature], data: string): CryptoResult[Signature] =
  ## Create new signature from serialized hexadecimal string form.
  t.init(ncrutils.fromHex(data))

proc `==`*(key1, key2: PublicKey): bool {.inline.} =
  ## Return ``true`` if two public keys ``key1`` and ``key2`` of the same
  ## scheme and equal.
  if key1.scheme == key2.scheme:
    case key1.scheme
    of PKScheme.RSA:
      when supported(PKScheme.RSA):
        (key1.rsakey == key2.rsakey)
      else:
        false
    of PKScheme.Ed25519:
      when supported(PKScheme.Ed25519):
        (key1.edkey == key2.edkey)
      else:
        false
    of PKScheme.ECDSA:
      when supported(PKScheme.ECDSA):
        (key1.eckey == key2.eckey)
      else:
        false
    of PKScheme.Secp256k1:
      when supported(PKScheme.Secp256k1):
        (key1.skkey == key2.skkey)
      else:
        false
  else:
    false

proc `==`*(key1, key2: PrivateKey): bool =
  ## Return ``true`` if two private keys ``key1`` and ``key2`` of the same
  ## scheme and equal.
  if key1.scheme == key2.scheme:
    case key1.scheme
    of PKScheme.RSA:
      when supported(PKScheme.RSA):
        (key1.rsakey == key2.rsakey)
      else:
        false
    of PKScheme.Ed25519:
      when supported(PKScheme.Ed25519):
        (key1.edkey == key2.edkey)
      else:
        false
    of PKScheme.ECDSA:
      when supported(PKScheme.ECDSA):
        (key1.eckey == key2.eckey)
      else:
        false
    of PKScheme.Secp256k1:
      when supported(PKScheme.Secp256k1):
        (key1.skkey == key2.skkey)
      else:
        false
  else:
    false

proc `$`*(key: PrivateKey|PublicKey): string =
  ## Get string representation of private/public key ``key``.
  case key.scheme:
  of PKScheme.RSA:
    when supported(PKScheme.RSA):
      $(key.rsakey)
    else:
      "unsupported RSA key"
  of PKScheme.Ed25519:
    when supported(PKScheme.Ed25519):
      "ed25519 key (" & $key.edkey & ")"
    else:
      "unsupported ed25519 key"
  of PKScheme.ECDSA:
    when supported(PKScheme.ECDSA):
      "secp256r1 key (" & $key.eckey & ")"
    else:
      "unsupported secp256r1 key"
  of PKScheme.Secp256k1:
    when supported(PKScheme.Secp256k1):
      "secp256k1 key (" & $key.skkey & ")"
    else:
      "unsupported secp256k1 key"

func shortLog*(key: PrivateKey|PublicKey): string =
  ## Get short string representation of private/public key ``key``.
  case key.scheme:
  of PKScheme.RSA:
    when supported(PKScheme.RSA):
      ($key.rsakey).shortLog
    else:
      "unsupported RSA key"
  of PKScheme.Ed25519:
    when supported(PKScheme.Ed25519):
      "ed25519 key (" & ($key.edkey).shortLog & ")"
    else:
      "unsupported ed25519 key"
  of PKScheme.ECDSA:
    when supported(PKScheme.ECDSA):
      "secp256r1 key (" & ($key.eckey).shortLog & ")"
    else:
      "unsupported secp256r1 key"
  of PKScheme.Secp256k1:
    when supported(PKScheme.Secp256k1):
      "secp256k1 key (" & ($key.skkey).shortLog & ")"
    else:
      "unsupported secp256k1 key"

proc `$`*(sig: Signature): string =
  ## Get string representation of signature ``sig``.
  result = ncrutils.toHex(sig.data)

proc sign*(key: PrivateKey,
           data: openArray[byte]): CryptoResult[Signature] {.gcsafe.} =
  ## Sign message ``data`` using private key ``key`` and return generated
  ## signature in raw binary form.
  var res: Signature
  case key.scheme:
  of PKScheme.RSA:
    when supported(PKScheme.RSA):
      let sig = ? key.rsakey.sign(data).orError(SigError)
      res.data = ? sig.getBytes().orError(SigError)
      ok(res)
    else:
      err(SchemeError)
  of PKScheme.Ed25519:
    when supported(PKScheme.Ed25519):
      let sig = key.edkey.sign(data)
      res.data = sig.getBytes()
      ok(res)
    else:
      err(SchemeError)
  of PKScheme.ECDSA:
    when supported(PKScheme.ECDSA):
      let sig = ? key.eckey.sign(data).orError(SigError)
      res.data = ? sig.getBytes().orError(SigError)
      ok(res)
    else:
      err(SchemeError)
  of PKScheme.Secp256k1:
    when supported(PKScheme.Secp256k1):
      let sig = key.skkey.sign(data)
      res.data = sig.getBytes()
      ok(res)
    else:
      err(SchemeError)

proc verify*(sig: Signature, message: openArray[byte], key: PublicKey): bool =
  ## Verify signature ``sig`` using message ``message`` and public key ``key``.
  ## Return ``true`` if message signature is valid.
  case key.scheme:
  of PKScheme.RSA:
    when supported(PKScheme.RSA):
      var signature: RsaSignature
      if signature.init(sig.data).isOk:
        signature.verify(message, key.rsakey)
      else:
        false
    else:
      false
  of PKScheme.Ed25519:
    when supported(PKScheme.Ed25519):
      var signature: EdSignature
      if signature.init(sig.data):
        signature.verify(message, key.edkey)
      else:
        false
    else:
      false
  of PKScheme.ECDSA:
    when supported(PKScheme.ECDSA):
      var signature: EcSignature
      if signature.init(sig.data).isOk:
        signature.verify(message, key.eckey)
      else:
        false
    else:
      false
  of PKScheme.Secp256k1:
    when supported(PKScheme.Secp256k1):
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
    rng: var BrHmacDrbgContext): CryptoResult[EcKeyPair] =
  ## Generate ephemeral keys used to perform ECDHE.
  var keypair: EcKeyPair
  if scheme == Secp256r1:
    keypair = ? EcKeyPair.random(Secp256r1, rng).orError(KeyError)
  elif scheme == Secp384r1:
    keypair = ? EcKeyPair.random(Secp384r1, rng).orError(KeyError)
  elif scheme == Secp521r1:
    keypair = ? EcKeyPair.random(Secp521r1, rng).orError(KeyError)
  ok(keypair)

proc ephemeral*(
    scheme: string, rng: var BrHmacDrbgContext): CryptoResult[EcKeyPair] =
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

proc getOrder*(remotePubkey, localNonce: openArray[byte],
               localPubkey, remoteNonce: openArray[byte]): CryptoResult[int] =
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
    return p[0]

  for felement in f:
    for selement in s:
      if felement == selement:
        return felement

proc createProposal*(nonce, pubkey: openArray[byte],
                     exchanges, ciphers, hashes: string): seq[byte] =
  ## Create SecIO proposal message using random ``nonce``, local public key
  ## ``pubkey``, comma-delimieted list of supported exchange schemes
  ## ``exchanges``, comma-delimeted list of supported ciphers ``ciphers`` and
  ## comma-delimeted list of supported hashes ``hashes``.
  var msg = initProtoBuffer({WithUint32BeLength})
  msg.write(1, nonce)
  msg.write(2, pubkey)
  msg.write(3, exchanges)
  msg.write(4, ciphers)
  msg.write(5, hashes)
  msg.finish()
  msg.buffer

proc decodeProposal*(message: seq[byte], nonce, pubkey: var seq[byte],
                     exchanges, ciphers, hashes: var string): bool =
  ## Parse incoming proposal message and decode remote random nonce ``nonce``,
  ## remote public key ``pubkey``, comma-delimieted list of supported exchange
  ## schemes ``exchanges``, comma-delimeted list of supported ciphers
  ## ``ciphers`` and comma-delimeted list of supported hashes ``hashes``.
  ##
  ## Procedure returns ``true`` on success and ``false`` on error.
  var pb = initProtoBuffer(message)
  let r1 = pb.getField(1, nonce)
  let r2 = pb.getField(2, pubkey)
  let r3 = pb.getField(3, exchanges)
  let r4 = pb.getField(4, ciphers)
  let r5 = pb.getField(5, hashes)

  r1.isOk() and r1.get() and r2.isOk() and r2.get() and
  r3.isOk() and r3.get() and r4.isOk() and r4.get() and
  r5.isOk() and r5.get()

proc createExchange*(epubkey, signature: openArray[byte]): seq[byte] =
  ## Create SecIO exchange message using ephemeral public key ``epubkey`` and
  ## signature of proposal blocks ``signature``.
  var msg = initProtoBuffer({WithUint32BeLength})
  msg.write(1, epubkey)
  msg.write(2, signature)
  msg.finish()
  msg.buffer

proc decodeExchange*(message: seq[byte],
                     pubkey, signature: var seq[byte]): bool =
  ## Parse incoming exchange message and decode remote ephemeral public key
  ## ``pubkey`` and signature ``signature``.
  ##
  ## Procedure returns ``true`` on success and ``false`` on error.
  var pb = initProtoBuffer(message)
  let r1 = pb.getField(1, pubkey)
  let r2 = pb.getField(2, signature)
  r1.isOk() and r1.get() and r2.isOk() and r2.get()

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

proc write*[T: PublicKey|PrivateKey](pb: var ProtoBuffer, field: int,
                                     key: T) {.
     inline, raises: [Defect, ResultError[CryptoError]].} =
  write(pb, field, key.getBytes().tryGet())

proc write*(pb: var ProtoBuffer, field: int, sig: Signature) {.
     inline, raises: [Defect].} =
  write(pb, field, sig.getBytes())

proc getField*[T: PublicKey|PrivateKey](pb: ProtoBuffer, field: int,
                                        value: var T): ProtoResult[bool] =
  ## Deserialize public/private key from protobuf's message ``pb`` using field
  ## index ``field``.
  ##
  ## On success deserialized key will be stored in ``value``.
  var buffer: seq[byte]
  var key: T
  let res = ? pb.getField(field, buffer)
  if not(res):
    ok(false)
  else:
    if key.init(buffer):
      value = key
      ok(true)
    else:
      err(ProtoError.IncorrectBlob)

proc getField*(pb: ProtoBuffer, field: int,
               value: var Signature): ProtoResult[bool] =
  ## Deserialize signature from protobuf's message ``pb`` using field index
  ## ``field``.
  ##
  ## On success deserialized signature will be stored in ``value``.
  var buffer: seq[byte]
  var sig: Signature
  let res = ? pb.getField(field, buffer)
  if not(res):
    ok(false)
  else:
    if sig.init(buffer):
      value = sig
      ok(true)
    else:
      err(ProtoError.IncorrectBlob)
