import strutils, hexdump, nimcrypto/utils
import common

const
  DefaultPublicExponent = 3'u32

type
  RsaPrivateKey* = ref object
    buffer*: seq[byte]
    key*: BrRsaPrivateKey

  RsaPublicKey* = ref object
    buffer*: seq[byte]
    key*: BrRsaPublicKey

  RsaKeyPair* = object
    seckey*: RsaPrivateKey
    pubkey*: RsaPublicKey

  RsaModulus* = seq[byte]
  RsaPublicExponent* = uint32
  RsaPrivateExponent* = seq[byte]

  RsaError = object of Exception
  RsaRngError = object of RsaError
  RsaGenError = object of RsaError
  RsaIncorrectKeyError = object of RsaError

proc random*(t: typedesc[RsaKeyPair], bits: int): RsaKeyPair =
  ## Generate new random RSA key pair (private key and public key) using
  ## BearSSL's HMAC-SHA256-DRBG algorithm.
  ##
  ## ``bits`` number of bits in RSA key, must be in range [512, 4096].
  var rng: BrHmacDrbgContext
  var keygen: BrRsaKeygen
  var seeder = brPrngSeederSystem(nil)
  brHmacDrbgInit(addr rng, addr sha256Vtable, nil, 0)
  if seeder(addr rng.vtable) == 0:
    raise newException(ValueError, "Could not seed RNG")
  keygen = brRsaKeygenGetDefault()
  result.seckey = new RsaPrivateKey
  result.pubkey = new RsaPublicKey
  result.seckey.buffer = newSeq[byte](brRsaPrivateKeyBufferSize(bits))
  result.pubkey.buffer = newSeq[byte](brRsaPublicKeyBufferSize(bits))
  if keygen(addr rng.vtable,
            addr result.seckey.key, addr result.seckey.buffer[0],
            addr result.pubkey.key, addr result.pubkey.buffer[0],
            cuint(bits), DefaultPublicExponent) == 0:
    raise newException(RsaGenError, "Could not create keypair")

proc random*(t: typedesc[RsaPrivateKey], bits: int): RsaPrivateKey =
  ## Generate new random RSA private key using BearSSL's HMAC-SHA256-DRBG
  ## algorithm.
  ##
  ## ``bits`` number of bits in RSA key, must be in range [512, 4096].
  var rng: BrHmacDrbgContext
  var keygen: BrRsaKeygen
  var seeder = brPrngSeederSystem(nil)
  brHmacDrbgInit(addr rng, addr sha256Vtable, nil, 0)
  if seeder(addr rng.vtable) == 0:
    raise newException(RsaRngError, "Could not seed RNG")
  keygen = brRsaKeygenGetDefault()
  result = new RsaPrivateKey
  result.buffer = newSeq[byte](brRsaPrivateKeyBufferSize(bits))
  if keygen(addr rng.vtable,
            addr result.seckey.key, addr result.seckey.buffer[0],
            nil, nil,
            cuint(bits), DefaultPublicExponent) == 0:
    raise newException(RsaGenError, "Could not create private key")

proc modulus*(seckey: RsaPrivateKey): RsaModulus =
  ## Calculate and return RSA modulus.
  let bytelen = (seckey.key.nBitlen + 7) shr 3
  let compute = brRsaComputeModulusGetDefault()
  result = newSeq[byte](bytelen)
  let length = compute(addr result[0], unsafeAddr seckey.key)
  assert(length == len(result), $length)

proc pubexp*(seckey: RsaPrivateKey): RsaPublicExponent =
  ## Calculate and return RSA public exponent.
  let compute = brRsaComputePubexpGetDefault()
  result = compute(unsafeAddr seckey.key)

proc privexp*(seckey: RsaPrivateKey,
              pubexp: RsaPublicExponent): RsaPrivateExponent =
  ## Calculate and return RSA private exponent.
  let bytelen = (seckey.key.nBitlen + 7) shr 3
  let compute = brRsaComputePrivexpGetDefault()
  result = newSeq[byte](bytelen)
  let length = compute(addr result[0], unsafeAddr seckey.key, pubexp)
  assert(length == len(result), $length)

proc getKey*(seckey: RsaPrivateKey): RsaPublicKey =
  ## Calculate and return RSA public key from RSA private key ``seckey``.
  var ebuf: array[4, byte]
  var modulus = seckey.modulus()
  var pubexp = seckey.pubexp()
  let modlen = len(modulus)
  result = new RsaPublicKey
  result.buffer = newSeq[byte](modlen + sizeof(ebuf))
  result.key.n = cast[ptr cuchar](addr result.buffer[0])
  result.key.nlen = modlen
  result.key.e = cast[ptr cuchar](addr result.buffer[modlen])
  result.key.elen = sizeof(ebuf)
  ebuf[0] = cast[byte](pubexp shr 24)
  ebuf[1] = cast[byte](pubexp shr 16)
  ebuf[2] = cast[byte](pubexp shr 8)
  ebuf[3] = cast[byte](pubexp)
  copyMem(addr result.buffer[0], addr modulus[0], modlen)
  copyMem(addr result.buffer[modlen], addr ebuf[0], sizeof(ebuf))



proc brEncodePublicRsaRawDer(pubkey: RsaPublicKey,
                             dest: var openarray[byte]): int =
  # RSAPublicKey ::= SEQUENCE {
  #   modulus           INTEGER,  -- n
  #   publicExponent    INTEGER,  -- e
  # }
  var num: array[2, BrAsn1Uint]
  num[0] = brAsn1UintPrepare(pubkey.key.n, pubkey.key.nlen)
  num[1] = brAsn1UintPrepare(pubkey.key.e, pubkey.key.elen)
  var slen = 0
  for i in 0..<2:
    var ilen = num[i].asn1len
    slen += 1 + brAsn1EncodeLength(nil, ilen) + ilen
  result = 1 + brAsn1EncodeLength(nil, slen) + slen
  if len(dest) >= result:
    var offset = 1
    dest[0] = 0x30'u8
    offset += brAsn1EncodeLength(addr dest[offset], slen)
    for i in 0..<2:
      offset += brAsn1EncodeUint(addr dest[offset], num[i])

proc brAsn1EncodeBitString(data: var openarray[byte], bytesize: int): int =
  result = 1 + brAsn1EncodeLength(nil, bytesize + 1) + 1
  if len(data) >= result:
    var offset = 1
    data[0] = 0x03'u8
    offset += brAsn1EncodeLength(addr data[offset], bytesize + 1)
    data[offset] = 0'u8

proc marshalBin*(pubkey: RsaPublicKey, kind: MarshalKind): seq[byte] =
  ## Serialize RSA public key ``pubkey`` to binary [RAWDER, PKCS8DER] format.
  var tmp: array[1, byte]
  if kind == RAW:
    var res = brEncodePublicRsaRawDer(pubkey, tmp)
    result = newSeq[byte](res)
    res = brEncodePublicRsaRawDer(pubkey, result)
    assert res == len(result)
  elif kind == PKCS8:
    var pkcs8head = [
      0x30'u8, 0x0D'u8, 0x06'u8, 0x09'u8, 0x2A'u8, 0x86'u8, 0x48'u8, 0x86'u8,
      0xF7'u8, 0x0D'u8, 0x01'u8, 0x01'u8, 0x01'u8, 0x05'u8, 0x00'u8
    ]
    var lenraw = brEncodePublicRsaRawDer(pubkey, tmp)
    echo "lenraw = ", lenraw, " hex = 0x", toHex(lenraw)
    echo "RAWDER"

    var lenseq = sizeof(pkcs8head) + brAsn1EncodeLength(nil, lenraw) + lenraw +
                 brAsn1EncodeBitString(tmp, lenraw)
    echo "brAsn1EncodeBitString = ", brAsn1EncodeBitString(tmp, lenraw)
    echo "lenseq = ", lenseq
    result = newSeq[byte](1 + brAsn1EncodeLength(nil, lenseq) + lenseq)
    result[0] = 0x30'u8
    echo dumpHex(result)
    var offset = 1
    offset += brAsn1EncodeLength(addr result[offset], lenseq)
    echo dumpHex(result)
    copyMem(addr result[offset], addr pkcs8head[0], sizeof(pkcs8head))
    echo dumpHex(result)
    offset += sizeof(pkcs8head)
    offset += brAsn1EncodeBitString(result.toOpenArray(offset, len(result) - 1),
                                    lenraw)
    echo "AFTER BITSTRING"
    echo dumpHex(result)
    echo dumpHex(result.toOpenArray(offset, len(result) - 1))
    offset += brAsn1EncodeLength(addr result[offset], lenraw)

    var res = brEncodePublicRsaRawDer(pubkey, result.toOpenArray(offset,
                                                               len(result) - 1))
    echo "AFTER RAWDER"
    echo dumpHex(result)
    offset += res


proc marshalBin*(seckey: RsaPrivateKey, kind: MarshalKind): seq[byte] =
  ## Serialize RSA private key ``seckey`` to binary [RAWDER, PKCS8DER] format.
  var ebuf: array[4, byte]
  var pubkey: BrRsaPublicKey
  var modulus = seckey.modulus()
  var pubexp = seckey.pubexp()
  var privexp = seckey.privexp(pubexp)
  pubkey.n = cast[ptr cuchar](addr modulus[0])
  pubkey.nlen = len(modulus)
  ebuf[0] = cast[byte](pubexp shr 24)
  ebuf[1] = cast[byte](pubexp shr 16)
  ebuf[2] = cast[byte](pubexp shr 8)
  ebuf[3] = cast[byte](pubexp)
  pubkey.e = cast[ptr cuchar](addr ebuf[0])
  pubkey.elen = sizeof(ebuf)
  if kind == RAW:
    let length = brEncodeRsaRawDer(nil, unsafeAddr seckey.key, addr pubkey,
                                   addr privexp[0], len(privexp))
    result = newSeq[byte](length)
    let res = brEncodeRsaRawDer(addr result[0], unsafeAddr seckey.key,
                                addr pubkey, addr privexp[0],
                                len(privexp))
    assert(res == length)
  elif kind == PKCS8:
    let length = brEncodeRsaPkcs8Der(nil, unsafeAddr seckey.key, addr pubkey,
                                     addr privexp[0], len(privexp))
    result = newSeq[byte](length)
    let res = brEncodeRsaPkcs8Der(addr result[0], unsafeAddr seckey.key,
                                  addr pubkey, addr privexp[0],
                                  len(privexp))
    assert(res == length)

proc marshalPem*[T: RsaPrivateKey | RsaPublicKey](key: T,
                                                  kind: MarshalKind): string =
  ## Serialize RSA private key ``seckey`` to PEM encoded format string.
  var banner: string
  let flags = cast[cuint](BR_PEM_CRLF or BR_PEM_LINE64)
  if kind == RAW:
    when T is RsaPrivateKey:
      banner = "RSA PRIVATE KEY"
    else:
      banner = "RSA PUBLIC KEY"
  elif kind == PKCS8:
    when T is RsaPrivateKey:
      banner = "PRIVATE KEY"
    else:
      banner = "PUBLIC KEY"
  var buffer = marshalBin(key, kind)
  if len(buffer) > 0:
    let length = brPemEncode(nil, nil, len(buffer), banner, flags)
    result = newString(length + 1)
    let res = brPemEncode(cast[ptr byte](addr result[0]), addr buffer[0],
                          len(buffer), banner, flags)
    result.setLen(res)

proc copyRsaPrivateKey(brkey: BrRsaPrivateKey,
                       buffer: ptr cuchar): RsaPrivateKey =
  result.buffer = newSeq[byte](brRsaPrivateKeyBufferSize(int(brkey.nBitlen)))
  let p = cast[uint](addr result.buffer[0])
  let o = cast[uint](buffer)
  let size = brkey.iqlen + cast[int](cast[uint](brkey.iq) - o)
  if size > 0 and size <= len(result.buffer):
    copyMem(addr result.buffer[0], buffer, size)
    result.key.nBitlen = brkey.nBitlen
    result.key.plen = brkey.plen
    result.key.qlen = brkey.qlen
    result.key.dplen = brkey.dplen
    result.key.dqlen = brkey.dqlen
    result.key.iqlen = brkey.iqlen
    result.key.p = cast[ptr cuchar](p + cast[uint](brkey.p) - o)
    result.key.q = cast[ptr cuchar](p + cast[uint](brkey.q) - o)
    result.key.dp = cast[ptr cuchar](p + cast[uint](brkey.dp) - o)
    result.key.dq = cast[ptr cuchar](p + cast[uint](brkey.dq) - o)
    result.key.iq = cast[ptr cuchar](p + cast[uint](brkey.iq) - o)

proc tryUnmarshalBin*(key: var RsaPrivateKey,
                      data: openarray[byte]): X509Status =
  ## Unserialize RSA private key ``key`` from binary blob ``data``. Binary blob
  ## must be RAWDER or PKCS8DER format.
  var ctx: BrSkeyDecoderContext
  result = X509Status.INCORRECT_VALUE
  if len(data) > 0:
    brSkeyDecoderInit(addr ctx)
    brSkeyDecoderPush(addr ctx, unsafeAddr data[0], len(data))
    let err = brSkeyDecoderLastError(addr ctx)
    if err == 0:
      let kt = brSkeyDecoderKeyType(addr ctx)
      if kt == BR_KEYTYPE_RSA:
        key = copyRsaPrivateKey(ctx.pkey.rsa, addr ctx.keyData[0])
        if key.key.nBitlen == ctx.pkey.rsa.nBitlen:
          result = X509Status.OK
        else:
          result = X509Status.INCORRECT_VALUE
      else:
        result = X509Status.WRONG_KEY_TYPE
    else:
      result = cast[X509Status](err)

proc unmarshalBin*(rt: typedesc[RsaPrivateKey],
                   data: openarray[byte]): RsaPrivateKey {.inline.} =
  let res = tryUnmarshalBin(result, data)
  if res != X509Status.OK:
    raise newException(ValueError, $res)

proc getPrivateKey*(key: var RsaPrivateKey, pemlist: PemList): X509Status =
  ## Get first
  result = X509Status.MISSING_KEY
  for item in pemlist:
    if "RSA PRIVATE KEY" in item.name:
      result = key.tryUnmarshalBin(item.data)
      return
    elif "PRIVATE KEY" in item.name:
      result = key.tryUnmarshalBin(item.data)
      return

proc cmp(a: ptr cuchar, alen: int, b: ptr cuchar, blen: int): bool =
  var arr = cast[ptr UncheckedArray[byte]](a)
  var brr = cast[ptr UncheckedArray[byte]](b)
  if alen == blen:
    var n = len(a)
    var res, diff: int
    while n > 0:
      dec(n)
      diff = int(arr[n]) - int(brr[n])
      res = (res and -not(diff)) or diff
    result = (res == 0)

proc `==`*(a, b: RsaPrivateKey): bool =
  ## Compare two RSA private keys for equality.
  if a.key.nBitlen == b.key.nBitlen:
    if cast[int](a.key.nBitlen) > 0:
      let r1 = cmp(a.key.p, a.key.plen, b.key.p, b.key.plen)
      let r2 = cmp(a.key.q, a.key.qlen, b.key.q, b.key.qlen)
      let r3 = cmp(a.key.dp, a.key.dplen, b.key.dp, b.key.dplen)
      let r4 = cmp(a.key.dq, a.key.dqlen, b.key.dq, b.key.dqlen)
      let r5 = cmp(a.key.iq, a.key.iqlen, b.key.iq, b.key.iqlen)
      result = r1 and r2 and r3 and r4 and r5
    else:
      result = true

proc `$`*(a: RsaPrivateKey): string =
  ## Return hexadecimal string representation of RSA private key.
  result = "P: "
  result.add("\n")
  result.add("Q: ")
  result.add("\n")
  result.add("DP: ")
  result.add("\n")
  result.add("DQ: ")
  result.add("\n")
  result.add("IQ: ")
  result.add("\n")

when isMainModule:
  var pk = RsaKeyPair.random()

