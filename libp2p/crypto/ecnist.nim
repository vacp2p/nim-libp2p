## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements constant-time ECDSA and ECDHE for NIST elliptic
## curves secp256r1, secp384r1 and secp521r1.
##
## This module uses unmodified parts of code from
## BearSSL library <https://bearssl.org/>
## Copyright(C) 2018 Thomas Pornin <pornin@bolet.org>.

{.push raises: [Defect].}

import bearssl
# We use `ncrutils` for constant-time hexadecimal encoding/decoding procedures.
import nimcrypto/utils as ncrutils
import minasn1
export minasn1.Asn1Error
import stew/[results, ctops]
export results

const
  PubKey256Length* = 65
  PubKey384Length* = 97
  PubKey521Length* = 133
  SecKey256Length* = 32
  SecKey384Length* = 48
  SecKey521Length* = 66
  Sig256Length* = 64
  Sig384Length* = 96
  Sig521Length* = 132
  Secret256Length* = SecKey256Length
  Secret384Length* = SecKey384Length
  Secret521Length* = SecKey521Length

type
  EcPrivateKey* = ref object
    buffer*: array[BR_EC_KBUF_PRIV_MAX_SIZE, byte]
    key*: BrEcPrivateKey

  EcPublicKey* = ref object
    buffer*: array[BR_EC_KBUF_PUB_MAX_SIZE, byte]
    key*: BrEcPublicKey

  EcKeyPair* = object
    seckey*: EcPrivateKey
    pubkey*: EcPublicKey

  EcSignature* = ref object
    buffer*: seq[byte]

  EcCurveKind* = enum
    Secp256r1 = BR_EC_SECP256R1,
    Secp384r1 = BR_EC_SECP384R1,
    Secp521r1 = BR_EC_SECP521R1

  EcPKI* = EcPrivateKey | EcPublicKey | EcSignature

  EcError* = enum
    EcRngError,
    EcKeyGenError,
    EcPublicKeyError,
    EcKeyIncorrectError,
    EcSignatureError

  EcResult*[T] = Result[T, EcError]

const
  EcSupportedCurvesCint* = {cint(Secp256r1), cint(Secp384r1), cint(Secp521r1)}

proc `-`(x: uint32): uint32 {.inline.} =
  result = (0xFFFF_FFFF'u32 - x) + 1'u32

proc GT(x, y: uint32): uint32 {.inline.} =
  var z = cast[uint32](y - x)
  result = (z xor ((x xor y) and (x xor z))) shr 31

proc CMP(x, y: uint32): int32 {.inline.} =
  cast[int32](GT(x, y)) or -(cast[int32](GT(y, x)))

proc EQ0(x: int32): uint32 {.inline.} =
  var q = cast[uint32](x)
  result = not(q or -q) shr 31

proc NEQ(x, y: uint32): uint32 {.inline.} =
  var q = cast[uint32](x xor y)
  result = ((q or -q) shr 31)

proc LT0(x: int32): uint32 {.inline.} =
  result = cast[uint32](x) shr 31

proc checkScalar(scalar: openArray[byte], curve: cint): uint32 =
  ## Return ``1`` if all of the following hold:
  ##   - len(``scalar``) <= ``orderlen``
  ##   - ``scalar`` != 0
  ##   - ``scalar`` is lower than the curve ``order``.
  ##
  ## Otherwise, return ``0``.
  var impl = brEcGetDefault()
  var orderlen = 0
  var order = cast[ptr UncheckedArray[byte]](impl.order(curve, addr orderlen))

  var z = 0'u32
  var c = 0'i32
  for u in scalar:
    z = z or u
  if len(scalar) == orderlen:
    for i in 0..<len(scalar):
      c = c or (-(cast[int32](EQ0(c))) and CMP(scalar[i], order[i]))
  else:
    c = -1
  result = NEQ(z, 0'u32) and LT0(c)

proc checkPublic(key: openArray[byte], curve: cint): uint32 =
  ## Return ``1`` if public key ``key`` is on curve.
  var ckey = @key
  var x = [0x00'u8, 0x01'u8]
  var impl = brEcGetDefault()
  var orderlen = 0
  discard impl.order(curve, addr orderlen)
  result = impl.mul(cast[ptr cuchar](unsafeAddr ckey[0]), len(ckey),
                    cast[ptr cuchar](addr x[0]), len(x), curve)

proc getOffset(pubkey: EcPublicKey): int {.inline.} =
  let o = cast[uint](pubkey.key.q) - cast[uint](unsafeAddr pubkey.buffer[0])
  if o + cast[uint](pubkey.key.qlen) > uint(len(pubkey.buffer)):
    result = -1
  else:
    result = cast[int](o)

proc getOffset(seckey: EcPrivateKey): int {.inline.} =
  let o = cast[uint](seckey.key.x) - cast[uint](unsafeAddr seckey.buffer[0])
  if o + cast[uint](seckey.key.xlen) > uint(len(seckey.buffer)):
    result = -1
  else:
    result = cast[int](o)

template getPublicKeyLength*(curve: EcCurveKind): int =
  case curve
  of Secp256r1:
    PubKey256Length
  of Secp384r1:
    PubKey384Length
  of Secp521r1:
    PubKey521Length

template getPrivateKeyLength*(curve: EcCurveKind): int =
  case curve
  of Secp256r1:
    SecKey256Length
  of Secp384r1:
    SecKey384Length
  of Secp521r1:
    SecKey521Length

proc copy*[T: EcPKI](dst: var T, src: T): bool =
  ## Copy EC `private key`, `public key` or `signature` ``src`` to ``dst``.
  ##
  ## Returns ``true`` on success, ``false`` otherwise.
  if isNil(src):
    result = false
  else:
    dst = new T
    when T is EcPrivateKey:
      let length = src.key.xlen
      if length > 0 and len(src.buffer) > 0:
        let offset = getOffset(src)
        if offset >= 0:
          dst.buffer = src.buffer
          dst.key.curve = src.key.curve
          dst.key.xlen = length
          dst.key.x = cast[ptr cuchar](addr dst.buffer[offset])
          result = true
    elif T is EcPublicKey:
      let length = src.key.qlen
      if length > 0 and len(src.buffer) > 0:
        let offset = getOffset(src)
        if offset >= 0:
          dst.buffer = src.buffer
          dst.key.curve = src.key.curve
          dst.key.qlen = length
          dst.key.q = cast[ptr cuchar](addr dst.buffer[offset])
          result = true
    else:
      let length = len(src.buffer)
      if length > 0:
        dst.buffer = src.buffer
        result = true

proc copy*[T: EcPKI](src: T): T {.inline.} =
  ## Returns copy of EC `private key`, `public key` or `signature`
  ## object ``src``.
  if not copy(result, src):
    raise newException(EcKeyIncorrectError, "Incorrect key or signature")

proc clear*[T: EcPKI|EcKeyPair](pki: var T) =
  ## Wipe and clear EC `private key`, `public key` or `signature` object.
  doAssert(not isNil(pki))
  when T is EcPrivateKey:
    burnMem(pki.buffer)
    pki.buffer.setLen(0)
    pki.key.x = nil
    pki.key.xlen = 0
    pki.key.curve = 0
  elif T is EcPublicKey:
    burnMem(pki.buffer)
    pki.buffer.setLen(0)
    pki.key.q = nil
    pki.key.qlen = 0
    pki.key.curve = 0
  elif T is EcSignature:
    burnMem(pki.buffer)
    pki.buffer.setLen(0)
  else:
    burnMem(pki.seckey.buffer)
    burnMem(pki.pubkey.buffer)
    pki.seckey.buffer.setLen(0)
    pki.pubkey.buffer.setLen(0)
    pki.seckey.key.x = nil
    pki.seckey.key.xlen = 0
    pki.seckey.key.curve = 0
    pki.pubkey.key.q = nil
    pki.pubkey.key.qlen = 0
    pki.pubkey.key.curve = 0

proc random*(
    T: typedesc[EcPrivateKey], kind: EcCurveKind,
    rng: var BrHmacDrbgContext): EcResult[EcPrivateKey] =
  ## Generate new random EC private key using BearSSL's HMAC-SHA256-DRBG
  ## algorithm.
  ##
  ## ``kind`` elliptic curve kind of your choice (secp256r1, secp384r1 or
  ## secp521r1).
  var ecimp = brEcGetDefault()
  var res = new EcPrivateKey
  if brEcKeygen(addr rng.vtable, ecimp,
                addr res.key, addr res.buffer[0],
                cast[cint](kind)) == 0:
    err(EcKeyGenError)
  else:
    ok(res)

proc getPublicKey*(seckey: EcPrivateKey): EcResult[EcPublicKey] =
  ## Calculate and return EC public key from private key ``seckey``.
  if isNil(seckey):
    return err(EcKeyIncorrectError)

  var ecimp = brEcGetDefault()
  if seckey.key.curve in EcSupportedCurvesCint:
    var length = getPublicKeyLength(cast[EcCurveKind](seckey.key.curve))
    var res = new EcPublicKey
    if brEcComputePublicKey(ecimp, addr res.key,
                            addr res.buffer[0], unsafeAddr seckey.key) == 0:
      err(EcKeyIncorrectError)
    else:
      ok(res)
  else:
    err(EcKeyIncorrectError)

proc random*(
    T: typedesc[EcKeyPair], kind: EcCurveKind,
    rng: var BrHmacDrbgContext): EcResult[T] =
  ## Generate new random EC private and public keypair using BearSSL's
  ## HMAC-SHA256-DRBG algorithm.
  ##
  ## ``kind`` elliptic curve kind of your choice (secp256r1, secp384r1 or
  ## secp521r1).
  let
    seckey = ? EcPrivateKey.random(kind, rng)
    pubkey = ? seckey.getPublicKey()
    key = EcKeyPair(seckey: seckey, pubkey: pubkey)
  ok(key)

proc `$`*(seckey: EcPrivateKey): string =
  ## Return string representation of EC private key.
  if isNil(seckey) or seckey.key.curve == 0 or seckey.key.xlen == 0 or
     len(seckey.buffer) == 0:
    result = "Empty or uninitialized ECNIST key"
  else:
    if seckey.key.curve notin EcSupportedCurvesCint:
      result = "Unknown key"
    else:
      let offset = seckey.getOffset()
      if offset < 0:
        result = "Corrupted key"
      else:
        let e = offset + cast[int](seckey.key.xlen) - 1
        result = ncrutils.toHex(seckey.buffer.toOpenArray(offset, e))

proc `$`*(pubkey: EcPublicKey): string =
  ## Return string representation of EC public key.
  if isNil(pubkey) or pubkey.key.curve == 0 or pubkey.key.qlen == 0 or
     len(pubkey.buffer) == 0:
    result = "Empty or uninitialized ECNIST key"
  else:
    if pubkey.key.curve notin EcSupportedCurvesCint:
      result = "Unknown key"
    else:
      let offset = pubkey.getOffset()
      if offset < 0:
        result = "Corrupted key"
      else:
        let e = offset + cast[int](pubkey.key.qlen) - 1
        result = ncrutils.toHex(pubkey.buffer.toOpenArray(offset, e))

proc `$`*(sig: EcSignature): string =
  ## Return hexadecimal string representation of EC signature.
  if isNil(sig) or len(sig.buffer) == 0:
    result = "Empty or uninitialized ECNIST signature"
  else:
    result = ncrutils.toHex(sig.buffer)

proc toRawBytes*(seckey: EcPrivateKey, data: var openArray[byte]): EcResult[int] =
  ## Serialize EC private key ``seckey`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store EC private key, or `0`
  ## if private key is not in supported curve.
  if isNil(seckey):
    return err(EcKeyIncorrectError)
  if seckey.key.curve in EcSupportedCurvesCint:
    let klen = getPrivateKeyLength(cast[EcCurveKind](seckey.key.curve))
    if len(data) >= klen:
      copyMem(addr data[0], unsafeAddr seckey.buffer[0], klen)
    ok(klen)
  else:
    err(EcKeyIncorrectError)

proc toRawBytes*(pubkey: EcPublicKey, data: var openArray[byte]): EcResult[int] =
  ## Serialize EC public key ``pubkey`` to uncompressed form specified in
  ## section 4.3.6 of ANSI X9.62.
  ##
  ## Returns number of bytes (octets) needed to store EC public key, or `0`
  ## if public key is not in supported curve.
  if isNil(pubkey):
    return err(EcKeyIncorrectError)
  if pubkey.key.curve in EcSupportedCurvesCint:
    let klen = getPublicKeyLength(cast[EcCurveKind](pubkey.key.curve))
    if len(data) >= klen:
      copyMem(addr data[0], unsafeAddr pubkey.buffer[0], klen)
    ok(klen)
  else:
    err(EcKeyIncorrectError)

proc toRawBytes*(sig: EcSignature, data: var openArray[byte]): int =
  ## Serialize EC signature ``sig`` to raw binary form and store it to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store EC signature, or `0`
  ## if signature is not in supported curve.
  doAssert(not isNil(sig))
  result = len(sig.buffer)
  if len(data) >= len(sig.buffer):
    if len(sig.buffer) > 0:
      copyMem(addr data[0], unsafeAddr sig.buffer[0], len(sig.buffer))

proc toBytes*(seckey: EcPrivateKey, data: var openArray[byte]): EcResult[int] =
  ## Serialize EC private key ``seckey`` to ASN.1 DER binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store EC private key,
  ## or `0` if private key is not in supported curve.
  if isNil(seckey):
    return err(EcKeyIncorrectError)
  if seckey.key.curve in EcSupportedCurvesCint:
    var offset, length: int
    var pubkey = ? seckey.getPublicKey()
    var b = Asn1Buffer.init()
    var p = Asn1Composite.init(Asn1Tag.Sequence)
    var c0 = Asn1Composite.init(0)
    var c1 = Asn1Composite.init(1)
    if seckey.key.curve == BR_EC_SECP256R1:
      c0.write(Asn1Tag.Oid, Asn1OidSecp256r1)
    elif seckey.key.curve == BR_EC_SECP384R1:
      c0.write(Asn1Tag.Oid, Asn1OidSecp384r1)
    elif seckey.key.curve == BR_EC_SECP521R1:
      c0.write(Asn1Tag.Oid, Asn1OidSecp521r1)
    c0.finish()
    offset = pubkey.getOffset()
    if offset < 0:
      return err(EcKeyIncorrectError)
    length = pubkey.key.qlen
    c1.write(Asn1Tag.BitString,
             pubkey.buffer.toOpenArray(offset, offset + length - 1))
    c1.finish()
    offset = seckey.getOffset()
    if offset < 0:
      return err(EcKeyIncorrectError)
    length = seckey.key.xlen
    p.write(1'u64)
    p.write(Asn1Tag.OctetString,
            seckey.buffer.toOpenArray(offset, offset + length - 1))
    p.write(c0)
    p.write(c1)
    p.finish()
    b.write(p)
    b.finish()
    var blen = len(b)
    if len(data) >= blen:
      copyMem(addr data[0], addr b.buffer[0], blen)
    # ok anyway, since it might have been a query...
    ok(blen)
  else:
    err(EcKeyIncorrectError)


proc toBytes*(pubkey: EcPublicKey, data: var openArray[byte]): EcResult[int] =
  ## Serialize EC public key ``pubkey`` to ASN.1 DER binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store EC public key,
  ## or `0` if public key is not in supported curve.
  if isNil(pubkey):
    return err(EcKeyIncorrectError)
  if pubkey.key.curve in EcSupportedCurvesCint:
    var b = Asn1Buffer.init()
    var p = Asn1Composite.init(Asn1Tag.Sequence)
    var c = Asn1Composite.init(Asn1Tag.Sequence)
    c.write(Asn1Tag.Oid, Asn1OidEcPublicKey)
    if pubkey.key.curve == BR_EC_SECP256R1:
      c.write(Asn1Tag.Oid, Asn1OidSecp256r1)
    elif pubkey.key.curve == BR_EC_SECP384R1:
      c.write(Asn1Tag.Oid, Asn1OidSecp384r1)
    elif pubkey.key.curve == BR_EC_SECP521R1:
      c.write(Asn1Tag.Oid, Asn1OidSecp521r1)
    c.finish()
    p.write(c)
    let offset = getOffset(pubkey)
    if offset < 0:
      return err(EcKeyIncorrectError)
    let length = pubkey.key.qlen
    p.write(Asn1Tag.BitString,
            pubkey.buffer.toOpenArray(offset, offset + length - 1))
    p.finish()
    b.write(p)
    b.finish()
    var blen = len(b)
    if len(data) >= blen:
      copyMem(addr data[0], addr b.buffer[0], blen)
    ok(blen)
  else:
    err(EcKeyIncorrectError)

proc toBytes*(sig: EcSignature, data: var openArray[byte]): EcResult[int] =
  ## Serialize EC signature ``sig`` to ASN.1 DER binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store EC signature,
  ## or `0` if signature is not in supported curve.
  if isNil(sig):
    return err(EcSignatureError)
  let slen = len(sig.buffer)
  if len(data) >= slen:
    copyMem(addr data[0], unsafeAddr sig.buffer[0], slen)
  ok(slen)

proc getBytes*(seckey: EcPrivateKey): EcResult[seq[byte]] =
  ## Serialize EC private key ``seckey`` to ASN.1 DER binary form and return it.
  if isNil(seckey):
    return err(EcKeyIncorrectError)
  if seckey.key.curve in EcSupportedCurvesCint:
    var res = newSeq[byte]()
    let length = ? seckey.toBytes(res)
    res.setLen(length)
    discard ? seckey.toBytes(res)
    ok(res)
  else:
    err(EcKeyIncorrectError)

proc getBytes*(pubkey: EcPublicKey): EcResult[seq[byte]] =
  ## Serialize EC public key ``pubkey`` to ASN.1 DER binary form and return it.
  if isNil(pubkey):
    return err(EcKeyIncorrectError)
  if pubkey.key.curve in EcSupportedCurvesCint:
    var res = newSeq[byte]()
    let length = ? pubkey.toBytes(res)
    res.setLen(length)
    discard ? pubkey.toBytes(res)
    ok(res)
  else:
    err(EcKeyIncorrectError)

proc getBytes*(sig: EcSignature): EcResult[seq[byte]] =
  ## Serialize EC signature ``sig`` to ASN.1 DER binary form and return it.
  if isNil(sig):
    return err(EcSignatureError)
  var res = newSeq[byte]()
  let length = ? sig.toBytes(res)
  res.setLen(length)
  discard ? sig.toBytes(res)
  ok(res)

proc getRawBytes*(seckey: EcPrivateKey): EcResult[seq[byte]] =
  ## Serialize EC private key ``seckey`` to raw binary form and return it.
  if isNil(seckey):
    return err(EcKeyIncorrectError)
  if seckey.key.curve in EcSupportedCurvesCint:
    var res = newSeq[byte]()
    let length = ? seckey.toRawBytes(res)
    res.setLen(length)
    discard ? seckey.toRawBytes(res)
    ok(res)
  else:
    err(EcKeyIncorrectError)

proc getRawBytes*(pubkey: EcPublicKey): EcResult[seq[byte]] =
  ## Serialize EC public key ``pubkey`` to raw binary form and return it.
  if isNil(pubkey):
    return err(EcKeyIncorrectError)
  if pubkey.key.curve in EcSupportedCurvesCint:
    var res = newSeq[byte]()
    let length = ? pubkey.toRawBytes(res)
    res.setLen(length)
    discard ? pubkey.toRawBytes(res)
    return ok(res)
  else:
    return err(EcKeyIncorrectError)

proc getRawBytes*(sig: EcSignature): EcResult[seq[byte]] =
  ## Serialize EC signature ``sig`` to raw binary form and return it.
  if isNil(sig):
    return err(EcSignatureError)
  var res = newSeq[byte]()
  let length = ? sig.toBytes(res)
  res.setLen(length)
  discard ? sig.toBytes(res)
  ok(res)

proc `==`*(pubkey1, pubkey2: EcPublicKey): bool =
  ## Returns ``true`` if both keys ``pubkey1`` and ``pubkey2`` are equal.
  if isNil(pubkey1) and isNil(pubkey2):
    result = true
  elif isNil(pubkey1) and (not isNil(pubkey2)):
    result = false
  elif isNil(pubkey2) and (not isNil(pubkey1)):
    result = false
  else:
    if pubkey1.key.curve != pubkey2.key.curve:
      return false
    if pubkey1.key.qlen != pubkey2.key.qlen:
      return false
    let op1 = pubkey1.getOffset()
    let op2 = pubkey2.getOffset()
    if op1 == -1 or op2 == -1:
      return false
    return CT.isEqual(pubkey1.buffer.toOpenArray(op1, pubkey1.key.qlen - 1),
                      pubkey2.buffer.toOpenArray(op2, pubkey2.key.qlen - 1))

proc `==`*(seckey1, seckey2: EcPrivateKey): bool =
  ## Returns ``true`` if both keys ``seckey1`` and ``seckey2`` are equal.
  if isNil(seckey1) and isNil(seckey2):
    result = true
  elif isNil(seckey1) and (not isNil(seckey2)):
    result = false
  elif isNil(seckey2) and (not isNil(seckey1)):
    result = false
  else:
    if seckey1.key.curve != seckey2.key.curve:
      return false
    if seckey1.key.xlen != seckey2.key.xlen:
      return false
    let op1 = seckey1.getOffset()
    let op2 = seckey2.getOffset()
    if op1 == -1 or op2 == -1:
      return false
    return CT.isEqual(seckey1.buffer.toOpenArray(op1, seckey1.key.xlen - 1),
                      seckey2.buffer.toOpenArray(op2, seckey2.key.xlen - 1))

proc `==`*(a, b: EcSignature): bool =
  ## Return ``true`` if both signatures ``sig1`` and ``sig2`` are equal.
  if isNil(a) and isNil(b):
    true
  elif isNil(a) and (not isNil(b)):
    false
  elif isNil(b) and (not isNil(a)):
    false
  else:
    # We need to cover all the cases because Signature initialization procedure
    # do not perform any checks.
    if len(a.buffer) == 0 and len(b.buffer) == 0:
      true
    elif len(a.buffer) == 0 and len(b.buffer) != 0:
      false
    elif len(b.buffer) == 0 and len(a.buffer) != 0:
      false
    elif len(a.buffer) != len(b.buffer):
      false
    else:
      CT.isEqual(a.buffer, b.buffer)

proc init*(key: var EcPrivateKey, data: openArray[byte]): Result[void, Asn1Error] =
  ## Initialize EC `private key` or `signature` ``key`` from ASN.1 DER binary
  ## representation ``data``.
  ##
  ## Procedure returns ``Result[void, Asn1Error]``.
  var raw, oid, field: Asn1Field
  var curve: cint

  var ab = Asn1Buffer.init(data)

  field = ? ab.read()

  if field.kind != Asn1Tag.Sequence:
    return err(Asn1Error.Incorrect)

  var ib = field.getBuffer()

  field = ? ib.read()

  if field.kind != Asn1Tag.Integer:
    return err(Asn1Error.Incorrect)
  if field.vint != 1'u64:
    return err(Asn1Error.Incorrect)

  raw = ? ib.read()

  if raw.kind != Asn1Tag.OctetString:
    return err(Asn1Error.Incorrect)

  oid = ? ib.read()

  if oid.kind != Asn1Tag.Oid:
    return err(Asn1Error.Incorrect)

  if oid == Asn1OidSecp256r1:
    curve = cast[cint](Secp256r1)
  elif oid == Asn1OidSecp384r1:
    curve = cast[cint](Secp384r1)
  elif oid == Asn1OidSecp521r1:
    curve = cast[cint](Secp521r1)
  else:
    return err(Asn1Error.Incorrect)

  if checkScalar(raw.toOpenArray(), curve) == 1'u32:
    key = new EcPrivateKey
    copyMem(addr key.buffer[0], addr raw.buffer[raw.offset], raw.length)
    key.key.x = cast[ptr cuchar](addr key.buffer[0])
    key.key.xlen = raw.length
    key.key.curve = curve
    ok()
  else:
    err(Asn1Error.Incorrect)

proc init*(pubkey: var EcPublicKey, data: openArray[byte]): Result[void, Asn1Error] =
  ## Initialize EC public key ``pubkey`` from ASN.1 DER binary representation
  ## ``data``.
  ##
  ## Procedure returns ``Result[void, Asn1Error]``.
  var raw, oid, field: Asn1Field
  var curve: cint

  var ab = Asn1Buffer.init(data)

  field = ? ab.read()

  if field.kind != Asn1Tag.Sequence:
    return err(Asn1Error.Incorrect)

  var ib = field.getBuffer()
  field = ? ib.read()

  if field.kind != Asn1Tag.Sequence:
    return err(Asn1Error.Incorrect)

  var ob = field.getBuffer()
  oid = ? ob.read()

  if oid.kind != Asn1Tag.Oid:
    return err(Asn1Error.Incorrect)

  if oid != Asn1OidEcPublicKey:
    return err(Asn1Error.Incorrect)

  oid = ? ob.read()

  if oid.kind != Asn1Tag.Oid:
    return err(Asn1Error.Incorrect)

  if oid == Asn1OidSecp256r1:
    curve = cast[cint](Secp256r1)
  elif oid == Asn1OidSecp384r1:
    curve = cast[cint](Secp384r1)
  elif oid == Asn1OidSecp521r1:
    curve = cast[cint](Secp521r1)
  else:
    return err(Asn1Error.Incorrect)

  raw = ? ib.read()

  if raw.kind != Asn1Tag.BitString:
    return err(Asn1Error.Incorrect)

  if checkPublic(raw.toOpenArray(), curve) != 0:
    pubkey = new EcPublicKey
    copyMem(addr pubkey.buffer[0], addr raw.buffer[raw.offset], raw.length)
    pubkey.key.q = cast[ptr cuchar](addr pubkey.buffer[0])
    pubkey.key.qlen = raw.length
    pubkey.key.curve = curve
    ok()
  else:
    err(Asn1Error.Incorrect)

proc init*(sig: var EcSignature, data: openArray[byte]): Result[void, Asn1Error] =
  ## Initialize EC signature ``sig`` from raw binary representation ``data``.
  ##
  ## Procedure returns ``Result[void, Asn1Error]``.
  if len(data) > 0:
    sig = new EcSignature
    sig.buffer = @data
    ok()
  else:
    err(Asn1Error.Incorrect)

proc init*[T: EcPKI](sospk: var T,
                     data: string): Result[void, Asn1Error] {.inline.} =
  ## Initialize EC `private key`, `public key` or `signature` ``sospk`` from
  ## ASN.1 DER hexadecimal string representation ``data``.
  ##
  ## Procedure returns ``Asn1Status``.
  sospk.init(ncrutils.fromHex(data))

proc init*(t: typedesc[EcPrivateKey],
           data: openArray[byte]): EcResult[EcPrivateKey] =
  ## Initialize EC private key from ASN.1 DER binary representation ``data`` and
  ## return constructed object.
  var key: EcPrivateKey
  let res = key.init(data)
  if res.isErr:
    err(EcKeyIncorrectError)
  else:
    ok(key)

proc init*(t: typedesc[EcPublicKey],
           data: openArray[byte]): EcResult[EcPublicKey] =
  ## Initialize EC public key from ASN.1 DER binary representation ``data`` and
  ## return constructed object.
  var key: EcPublicKey
  let res = key.init(data)
  if res.isErr:
    err(EcKeyIncorrectError)
  else:
    ok(key)

proc init*(t: typedesc[EcSignature],
           data: openArray[byte]): EcResult[EcSignature] =
  ## Initialize EC signature from raw binary representation ``data`` and
  ## return constructed object.
  var sig: EcSignature
  let res = sig.init(data)
  if res.isErr:
    err(EcSignatureError)
  else:
    ok(sig)

proc init*[T: EcPKI](t: typedesc[T], data: string): EcResult[T] =
  ## Initialize EC `private key`, `public key` or `signature` from hexadecimal
  ## string representation ``data`` and return constructed object.
  t.init(ncrutils.fromHex(data))

proc initRaw*(key: var EcPrivateKey, data: openArray[byte]): bool =
  ## Initialize EC `private key` or `scalar` ``key`` from raw binary
  ## representation ``data``.
  ##
  ## Length of ``data`` array must be ``SecKey256Length``, ``SecKey384Length``
  ## or ``SecKey521Length``.
  ##
  ## Procedure returns ``true`` on success, ``false`` otherwise.
  var curve: cint
  if len(data) == SecKey256Length:
    curve = cast[cint](Secp256r1)
    result = true
  elif len(data) == SecKey384Length:
    curve = cast[cint](Secp384r1)
    result = true
  elif len(data) == SecKey521Length:
    curve = cast[cint](Secp521r1)
    result = true
  if result:
    result = false
    if checkScalar(data, curve) == 1'u32:
      let length = len(data)
      key = new EcPrivateKey
      copyMem(addr key.buffer[0], unsafeAddr data[0], length)
      key.key.x = cast[ptr cuchar](addr key.buffer[0])
      key.key.xlen = length
      key.key.curve = curve
      result = true

proc initRaw*(pubkey: var EcPublicKey, data: openArray[byte]): bool =
  ## Initialize EC public key ``pubkey`` from raw binary representation
  ## ``data``.
  ##
  ## Length of ``data`` array must be ``PubKey256Length``, ``PubKey384Length``
  ## or ``PubKey521Length``.
  ##
  ## Procedure returns ``true`` on success, ``false`` otherwise.
  var curve: cint
  if len(data) > 0:
    if data[0] == 0x04'u8:
      if len(data) == PubKey256Length:
        curve = cast[cint](Secp256r1)
        result = true
      elif len(data) == PubKey384Length:
        curve = cast[cint](Secp384r1)
        result = true
      elif len(data) == PubKey521Length:
        curve = cast[cint](Secp521r1)
        result = true
  if result:
    result = false
    if checkPublic(data, curve) != 0:
      let length = len(data)
      pubkey = new EcPublicKey
      copyMem(addr pubkey.buffer[0], unsafeAddr data[0], length)
      pubkey.key.q = cast[ptr cuchar](addr pubkey.buffer[0])
      pubkey.key.qlen = length
      pubkey.key.curve = curve
      result = true

proc initRaw*(sig: var EcSignature, data: openArray[byte]): bool =
  ## Initialize EC signature ``sig`` from raw binary representation ``data``.
  ##
  ## Length of ``data`` array must be ``Sig256Length``, ``Sig384Length``
  ## or ``Sig521Length``.
  ##
  ## Procedure returns ``true`` on success, ``false`` otherwise.
  let length = len(data)
  if (length == Sig256Length) or (length == Sig384Length) or
     (length == Sig521Length):
    result = true
  if result:
    sig = new EcSignature
    sig.buffer = @data

proc initRaw*[T: EcPKI](sospk: var T, data: string): bool {.inline.} =
  ## Initialize EC `private key`, `public key` or `signature` ``sospk`` from
  ## raw hexadecimal string representation ``data``.
  ##
  ## Procedure returns ``true`` on success, ``false`` otherwise.
  result = sospk.initRaw(ncrutils.fromHex(data))

proc initRaw*(t: typedesc[EcPrivateKey],
              data: openArray[byte]): EcResult[EcPrivateKey] =
  ## Initialize EC private key from raw binary representation ``data`` and
  ## return constructed object.
  var res: EcPrivateKey
  if not res.initRaw(data):
    err(EcKeyIncorrectError)
  else:
    ok(res)

proc initRaw*(t: typedesc[EcPublicKey],
              data: openArray[byte]): EcResult[EcPublicKey] =
  ## Initialize EC public key from raw binary representation ``data`` and
  ## return constructed object.
  var res: EcPublicKey
  if not res.initRaw(data):
    err(EcKeyIncorrectError)
  else:
    ok(res)

proc initRaw*(t: typedesc[EcSignature],
              data: openArray[byte]): EcResult[EcSignature] =
  ## Initialize EC signature from raw binary representation ``data`` and
  ## return constructed object.
  var res: EcSignature
  if not res.initRaw(data):
    err(EcSignatureError)
  else:
    ok(res)

proc initRaw*[T: EcPKI](t: typedesc[T], data: string): T {.inline.} =
  ## Initialize EC `private key`, `public key` or `signature` from raw
  ## hexadecimal string representation ``data`` and return constructed object.
  result = t.initRaw(ncrutils.fromHex(data))

proc scalarMul*(pub: EcPublicKey, sec: EcPrivateKey): EcPublicKey =
  ## Return scalar multiplication of ``pub`` and ``sec``.
  ##
  ## Returns point in curve as ``pub * sec`` or ``nil`` otherwise.
  doAssert((not isNil(pub)) and (not isNil(sec)))
  var impl = brEcGetDefault()
  if sec.key.curve in EcSupportedCurvesCint:
    if pub.key.curve == sec.key.curve:
      var key = new EcPublicKey
      if key.copy(pub):
        let poffset = key.getOffset()
        let soffset = sec.getOffset()
        if poffset >= 0 and soffset >= 0:
          let res = impl.mul(cast[ptr cuchar](addr key.buffer[poffset]),
                             key.key.qlen,
                             cast[ptr cuchar](unsafeAddr sec.buffer[soffset]),
                             sec.key.xlen,
                             key.key.curve)
          if res != 0:
            result = key

proc toSecret*(pubkey: EcPublicKey, seckey: EcPrivateKey,
               data: var openArray[byte]): int =
  ## Calculate ECDHE shared secret using Go's elliptic/curve approach, using
  ## remote public key ``pubkey`` and local private key ``seckey`` and store
  ## shared secret to ``data``.
  ##
  ## Returns number of bytes (octets) needed to store shared secret, or ``0``
  ## on error.
  ##
  ## ``data`` array length must be at least 32 bytes for `secp256r1`, 48 bytes
  ## for `secp384r1` and 66 bytes for `secp521r1`.
  doAssert((not isNil(pubkey)) and (not isNil(seckey)))
  var mult = scalarMul(pubkey, seckey)
  if not isNil(mult):
    if seckey.key.curve == BR_EC_SECP256R1:
      result = Secret256Length
    elif seckey.key.curve == BR_EC_SECP384R1:
      result = Secret384Length
    elif seckey.key.curve == BR_EC_SECP521R1:
      result = Secret521Length
    if len(data) >= result:
      var qplus1 = cast[pointer](cast[uint](mult.key.q) + 1'u)
      copyMem(addr data[0], qplus1, result)

proc getSecret*(pubkey: EcPublicKey, seckey: EcPrivateKey): seq[byte] =
  ## Calculate ECDHE shared secret using Go's elliptic curve approach, using
  ## remote public key ``pubkey`` and local private key ``seckey`` and return
  ## shared secret.
  ##
  ## If error happens length of result array will be ``0``.
  doAssert((not isNil(pubkey)) and (not isNil(seckey)))
  var data: array[Secret521Length, byte]
  let res = toSecret(pubkey, seckey, data)
  if res > 0:
    result = newSeq[byte](res)
    copyMem(addr result[0], addr data[0], res)

proc sign*[T: byte|char](seckey: EcPrivateKey,
                      message: openArray[T]): EcResult[EcSignature] {.gcsafe.} =
  ## Get ECDSA signature of data ``message`` using private key ``seckey``.
  if isNil(seckey):
    return err(EcKeyIncorrectError)
  var hc: BrHashCompatContext
  var hash: array[32, byte]
  var impl = brEcGetDefault()
  if seckey.key.curve in EcSupportedCurvesCint:
    var sig = new EcSignature
    sig.buffer = newSeq[byte](256)
    var kv = addr sha256Vtable
    kv.init(addr hc.vtable)
    if len(message) > 0:
      kv.update(addr hc.vtable, unsafeAddr message[0], len(message))
    else:
      kv.update(addr hc.vtable, nil, 0)
    kv.output(addr hc.vtable, addr hash[0])
    let res = brEcdsaSignAsn1(impl, kv, addr hash[0], addr seckey.key,
                              addr sig.buffer[0])
    # Clear context with initial value
    kv.init(addr hc.vtable)
    if res != 0:
      sig.buffer.setLen(res)
      ok(sig)
    else:
      err(EcSignatureError)
  else:
    err(EcKeyIncorrectError)

proc verify*[T: byte|char](sig: EcSignature, message: openArray[T],
                           pubkey: EcPublicKey): bool {.inline.} =
  ## Verify ECDSA signature ``sig`` using public key ``pubkey`` and data
  ## ``message``.
  ##
  ## Return ``true`` if message verification succeeded, ``false`` if
  ## verification failed.
  doAssert((not isNil(sig)) and (not isNil(pubkey)))
  var hc: BrHashCompatContext
  var hash: array[32, byte]
  var impl = brEcGetDefault()
  if pubkey.key.curve in EcSupportedCurvesCint:
    var kv = addr sha256Vtable
    kv.init(addr hc.vtable)
    if len(message) > 0:
      kv.update(addr hc.vtable, unsafeAddr message[0], len(message))
    else:
      kv.update(addr hc.vtable, nil, 0)
    kv.output(addr hc.vtable, addr hash[0])
    let res = brEcdsaVerifyAsn1(impl, addr hash[0], len(hash),
                                unsafeAddr pubkey.key,
                                addr sig.buffer[0], len(sig.buffer))
    # Clear context with initial value
    kv.init(addr hc.vtable)
    result = (res == 1)
