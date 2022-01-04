## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import
  secp256k1, bearssl,
  stew/[byteutils, results],
  nimcrypto/[hash, sha2]

export sha2, results

const
  SkRawPrivateKeySize* = 256 div 8
    ## Size of private key in octets (bytes)
  SkRawSignatureSize* = SkRawPrivateKeySize * 2 + 1
    ## Size of signature in octets (bytes)
  SkRawPublicKeySize* = SkRawPrivateKeySize + 1
    ## Size of public key in octets (bytes)

# This is extremely confusing but it's to avoid.. confusion between Eth standard and Secp standard
type
  SkPrivateKey* = distinct secp256k1.SkSecretKey
  SkPublicKey* = distinct secp256k1.SkPublicKey
  SkSignature* = distinct secp256k1.SkSignature
  SkKeyPair* = distinct secp256k1.SkKeyPair

template pubkey*(v: SkKeyPair): SkPublicKey = SkPublicKey(secp256k1.SkKeyPair(v).pubkey)
template seckey*(v: SkKeyPair): SkPrivateKey = SkPrivateKey(secp256k1.SkKeyPair(v).seckey)

proc random*(t: typedesc[SkPrivateKey], rng: var BrHmacDrbgContext): SkPrivateKey =
  let rngPtr = unsafeAddr rng # doesn't escape
  proc callRng(data: var openArray[byte]) =
    brHmacDrbgGenerate(rngPtr[], data)

  SkPrivateKey(SkSecretKey.random(callRng))

proc random*(t: typedesc[SkKeyPair], rng: var BrHmacDrbgContext): SkKeyPair =
  let rngPtr = unsafeAddr rng # doesn't escape
  proc callRng(data: var openArray[byte]) =
    brHmacDrbgGenerate(rngPtr[], data)

  SkKeyPair(secp256k1.SkKeyPair.random(callRng))

template seckey*(v: SkKeyPair): SkPrivateKey =
  SkPrivateKey(secp256k1.SkKeyPair(v).seckey)

template pubkey*(v: SkKeyPair): SkPublicKey =
  SkPublicKey(secp256k1.SkKeyPair(v).pubkey)

proc init*(key: var SkPrivateKey, data: openArray[byte]): SkResult[void] =
  ## Initialize Secp256k1 `private key` ``key`` from raw binary
  ## representation ``data``.
  key = SkPrivateKey(? secp256k1.SkSecretKey.fromRaw(data))
  ok()

proc init*(key: var SkPrivateKey, data: string): SkResult[void] =
  ## Initialize Secp256k1 `private key` ``key`` from hexadecimal string
  ## representation ``data``.
  key = SkPrivateKey(? secp256k1.SkSecretKey.fromHex(data))
  ok()

proc init*(key: var SkPublicKey, data: openArray[byte]): SkResult[void] =
  ## Initialize Secp256k1 `public key` ``key`` from raw binary
  ## representation ``data``.
  key = SkPublicKey(? secp256k1.SkPublicKey.fromRaw(data))
  ok()

proc init*(key: var SkPublicKey, data: string): SkResult[void] =
  ## Initialize Secp256k1 `public key` ``key`` from hexadecimal string
  ## representation ``data``.
  key = SkPublicKey(? secp256k1.SkPublicKey.fromHex(data))
  ok()

proc init*(sig: var SkSignature, data: openArray[byte]): SkResult[void] =
  ## Initialize Secp256k1 `signature` ``sig`` from raw binary
  ## representation ``data``.
  sig = SkSignature(? secp256k1.SkSignature.fromDer(data))
  ok()

proc init*(sig: var SkSignature, data: string): SkResult[void] =
  ## Initialize Secp256k1 `signature` ``sig`` from hexadecimal string
  ## representation ``data``.
  # TODO DER vs raw here is fishy
  var buffer: seq[byte]
  try:
    buffer = hexToSeqByte(data)
  except ValueError:
    return err("secp: Hex to bytes failed")
  init(sig, buffer)

proc init*(t: typedesc[SkPrivateKey], data: openArray[byte]): SkResult[SkPrivateKey] =
  ## Initialize Secp256k1 `private key` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns `private key` on success.
  SkSecretKey.fromRaw(data).mapConvert(SkPrivateKey)

proc init*(t: typedesc[SkPrivateKey], data: string): SkResult[SkPrivateKey] =
  ## Initialize Secp256k1 `private key` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns `private key` on success.
  SkSecretKey.fromHex(data).mapConvert(SkPrivateKey)

proc init*(t: typedesc[SkPublicKey], data: openArray[byte]): SkResult[SkPublicKey] =
  ## Initialize Secp256k1 `public key` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns `public key` on success.
  var key: SkPublicKey
  key.init(data) and ok(key)

proc init*(t: typedesc[SkPublicKey], data: string): SkResult[SkPublicKey] =
  ## Initialize Secp256k1 `public key` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns `public key` on success.
  var key: SkPublicKey
  key.init(data) and ok(key)

proc init*(t: typedesc[SkSignature], data: openArray[byte]): SkResult[SkSignature] =
  ## Initialize Secp256k1 `signature` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns `signature` on success.
  var sig: SkSignature
  sig.init(data) and ok(sig)

proc init*(t: typedesc[SkSignature], data: string): SkResult[SkSignature] =
  ## Initialize Secp256k1 `signature` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns `signature` on success.
  var sig: SkSignature
  sig.init(data) and ok(sig)

proc getPublicKey*(key: SkPrivateKey): SkPublicKey =
  ## Calculate and return Secp256k1 `public key` from `private key` ``key``.
  SkPublicKey(SkSecretKey(key).toPublicKey())

proc toBytes*(key: SkPrivateKey, data: var openArray[byte]): SkResult[int] =
  ## Serialize Secp256k1 `private key` ``key`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store
  ## Secp256k1 private key.
  if len(data) >= SkRawPrivateKeySize:
    data[0..<SkRawPrivateKeySize] = SkSecretKey(key).toRaw()
    ok(SkRawPrivateKeySize)
  else:
    err("secp: Not enough bytes")

proc toBytes*(key: SkPublicKey, data: var openArray[byte]): SkResult[int] =
  ## Serialize Secp256k1 `public key` ``key`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store
  ## Secp256k1 public key.
  if len(data) >= SkRawPublicKeySize:
    data[0..<SkRawPublicKeySize] = secp256k1.SkPublicKey(key).toRawCompressed()
    ok(SkRawPublicKeySize)
  else:
    err("secp: Not enough bytes")

proc toBytes*(sig: SkSignature, data: var openArray[byte]): int =
  ## Serialize Secp256k1 `signature` ``sig`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store
  ## Secp256k1 signature.
  secp256k1.SkSignature(sig).toDer(data)

proc getBytes*(key: SkPrivateKey): seq[byte] {.inline.} =
  ## Serialize Secp256k1 `private key` and return it.
  @(SkSecretKey(key).toRaw())

proc getBytes*(key: SkPublicKey): seq[byte] {.inline.} =
  ## Serialize Secp256k1 `public key` and return it.
  @(secp256k1.SkPublicKey(key).toRawCompressed())

proc getBytes*(sig: SkSignature): seq[byte] {.inline.} =
  ## Serialize Secp256k1 `signature` and return it.
  result = newSeq[byte](72)
  let length = toBytes(sig, result)
  result.setLen(length)

proc sign*[T: byte|char](key: SkPrivateKey, msg: openArray[T]): SkSignature =
  ## Sign message `msg` using private key `key` and return signature object.
  let h = sha256.digest(msg)
  SkSignature(sign(SkSecretKey(key), SkMessage(h.data)))

proc verify*[T: byte|char](sig: SkSignature, msg: openArray[T],
                           key: SkPublicKey): bool =
  let h = sha256.digest(msg)
  verify(secp256k1.SkSignature(sig), SkMessage(h.data), secp256k1.SkPublicKey(key))

func clear*(key: var SkPrivateKey) = clear(secp256k1.SkSecretKey(key))

func `$`*(key: SkPrivateKey): string = $secp256k1.SkSecretKey(key)
func `$`*(key: SkPublicKey): string = $secp256k1.SkPublicKey(key)
func `$`*(key: SkSignature): string = $secp256k1.SkSignature(key)
func `$`*(key: SkKeyPair): string = $secp256k1.SkKeyPair(key)

func `==`*(a, b: SkPrivateKey): bool =
  secp256k1.SkSecretKey(a) == secp256k1.SkSecretKey(b)
func `==`*(a, b: SkPublicKey): bool =
  secp256k1.SkPublicKey(a) == secp256k1.SkPublicKey(b)
func `==`*(a, b: SkSignature): bool =
  secp256k1.SkSignature(a) == secp256k1.SkSignature(b)
func `==`*(a, b: SkKeyPair): bool =
  secp256k1.SkKeyPair(a) == secp256k1.SkKeyPair(b)
