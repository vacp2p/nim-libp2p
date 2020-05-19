## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import secp256k1, stew/byteutils, nimcrypto/hash, nimcrypto/sha2
export sha2
import stew/results
export results

const
  SkRawPrivateKeySize* = 256 div 8
    ## Size of private key in octets (bytes)
  SkRawSignatureSize* = SkRawPrivateKeySize * 2 + 1
    ## Size of signature in octets (bytes)
  SkRawPublicKeySize* = SkRawPrivateKeySize + 1
    ## Size of public key in octets (bytes)

type
  SecpPrivateKey* = distinct SkSecretKey
  SecpPublicKey* = distinct SkPublicKey
  SecpSignature* = distinct SkSignature
  SecpKeyPair* = distinct SkKeyPair


template pubkey*(v: SkKeyPair): SecpPublicKey = SecpPublicKey(SkPublicKey(SkKeyPair(v).pubkey))
template seckey*(v: SkKeyPair): SecpPrivateKey = SecpPrivateKey(SkPrivateKey(SkKeyPair(v).seckey))

proc random*(t: typedesc[SecpPrivateKey]): SkResult[SecpPrivateKey] =
  ok(SecpPrivateKey(? SkSecretKey.random()))

proc random*(t: typedesc[SecpKeyPair]): SkResult[SecpKeyPair] =
  ok(SecpKeyPair(? SkKeyPair.random()))

template seckey*(v: SecpKeyPair): SecpPrivateKey =
  SecpPrivateKey(SkKeyPair(v).seckey)

template pubkey*(v: SecpKeyPair): SecpPublicKey =
  SecpPublicKey(SkKeyPair(v).pubkey)

proc init*(key: var SecpPrivateKey, data: openarray[byte]): SkResult[void] =
  ## Initialize Secp256k1 `private key` ``key`` from raw binary
  ## representation ``data``.
  key = SecpPrivateKey(? SkSecretKey.fromRaw(data))
  ok()

proc init*(key: var SecpPrivateKey, data: string): SkResult[void] =
  ## Initialize Secp256k1 `private key` ``key`` from hexadecimal string
  ## representation ``data``.
  key = SecpPrivateKey(? SkSecretKey.fromHex(data))
  ok()

proc init*(key: var SecpPublicKey, data: openarray[byte]): SkResult[void] =
  ## Initialize Secp256k1 `public key` ``key`` from raw binary
  ## representation ``data``.
  key = SecpPublicKey(? SkPublicKey.fromRaw(data))
  ok()

proc init*(key: var SecpPublicKey, data: string): SkResult[void] =
  ## Initialize Secp256k1 `public key` ``key`` from hexadecimal string
  ## representation ``data``.
  key = SecpPublicKey(? SkPublicKey.fromHex(data))
  ok()

proc init*(sig: var SecpSignature, data: openarray[byte]): SkResult[void] =
  ## Initialize Secp256k1 `signature` ``sig`` from raw binary
  ## representation ``data``.
  sig = SecpSignature(? SkSignature.fromDer(data))
  ok()

proc init*(sig: var SecpSignature, data: string): SkResult[void] =
  ## Initialize Secp256k1 `signature` ``sig`` from hexadecimal string
  ## representation ``data``.
  # TODO DER vs raw here is fishy
  var buffer: seq[byte]
  try:
    buffer = hexToSeqByte(data)
  except ValueError:
    return err("Hex to bytes failed")
  init(sig, buffer)

proc init*(t: typedesc[SecpPrivateKey], data: openarray[byte]): SkResult[SecpPrivateKey] =
  ## Initialize Secp256k1 `private key` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns `private key` on success.
  ok(SecpPrivateKey(? SkSecretKey.fromRaw(data)))

proc init*(t: typedesc[SecpPrivateKey], data: string): SkResult[SecpPrivateKey] =
  ## Initialize Secp256k1 `private key` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns `private key` on success.
  ok(SecpPrivateKey(? SkSecretKey.fromHex(data)))

proc init*(t: typedesc[SecpPublicKey], data: openarray[byte]): SkResult[SecpPublicKey] =
  ## Initialize Secp256k1 `public key` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns `public key` on success.
  var key: SecpPublicKey
  key.init(data) and ok(key)

proc init*(t: typedesc[SecpPublicKey], data: string): SkResult[SecpPublicKey] =
  ## Initialize Secp256k1 `public key` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns `public key` on success.
  var key: SecpPublicKey
  key.init(data) and ok(key)

proc init*(t: typedesc[SecpSignature], data: openarray[byte]): SkResult[SecpSignature] =
  ## Initialize Secp256k1 `signature` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns `signature` on success.
  var sig: SecpSignature
  sig.init(data) and ok(sig)

proc init*(t: typedesc[SecpSignature], data: string): SkResult[SecpSignature] =
  ## Initialize Secp256k1 `signature` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns `signature` on success.
  var sig: SecpSignature
  sig.init(data) and ok(sig)

proc getKey*(key: SecpPrivateKey): SkResult[SecpPublicKey] =
  ## Calculate and return Secp256k1 `public key` from `private key` ``key``.
  ok(SecpPublicKey(? SkSecretKey(key).toPublicKey()))

proc toBytes*(key: SecpPrivateKey, data: var openarray[byte]): SkResult[int] =
  ## Serialize Secp256k1 `private key` ``key`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store
  ## Secp256k1 private key.
  if len(data) >= SkRawPrivateKeySize:
    data[0..<SkRawPrivateKeySize] = SkSecretKey(key).toRaw()
    ok(SkRawPrivateKeySize)
  else:
    err("Not enough bytes")

proc toBytes*(key: SecpPublicKey, data: var openarray[byte]): SkResult[int] =
  ## Serialize Secp256k1 `public key` ``key`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store
  ## Secp256k1 public key.
  if len(data) >= SkRawPublicKeySize:
    data[0..<SkRawPublicKeySize] = SkPublicKey(key).toRawCompressed()
    ok(SkRawPublicKeySize)
  else:
    err("Not enough bytes")

proc toBytes*(sig: SecpSignature, data: var openarray[byte]): int =
  ## Serialize Secp256k1 `signature` ``sig`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store
  ## Secp256k1 signature.
  SkSignature(sig).toDer(data)

proc getBytes*(key: SecpPrivateKey): seq[byte] {.inline.} =
  ## Serialize Secp256k1 `private key` and return it.
  result = @(SkSecretKey(key).toRaw())

proc getBytes*(key: SecpPublicKey): seq[byte] {.inline.} =
  ## Serialize Secp256k1 `public key` and return it.
  result = @(SkPublicKey(key).toRawCompressed())

proc getBytes*(sig: SecpSignature): seq[byte] {.inline.} =
  ## Serialize Secp256k1 `signature` and return it.
  result = newSeq[byte](72)
  let length = toBytes(sig, result)
  result.setLen(length)

proc sign*[T: byte|char](key: SecpPrivateKey, msg: openarray[T]): SkResult[SecpSignature] =
  ## Sign message `msg` using private key `key` and return signature object.
  let h = sha256.digest(msg)
  ok(SecpSignature(? sign(SkSecretKey(key), h)))

proc verify*[T: byte|char](sig: SecpSignature, msg: openarray[T],
                           key: SecpPublicKey): bool =
  let h = sha256.digest(msg)
  verify(SkSignature(sig), h, SkPublicKey(key))

proc clear*(key: var SecpPrivateKey) {.borrow.}
proc clear*(key: var SecpPublicKey) {.borrow.}
proc clear*(key: var SecpSignature) {.borrow.}
proc clear*(key: var SecpKeyPair) {.borrow.}

proc verify*(key: SecpPrivateKey): bool {.borrow.}

proc `$`*(key: SecpPrivateKey): string {.borrow.}
proc `$`*(key: SecpPublicKey): string {.borrow.}
proc `$`*(key: SecpSignature): string {.borrow.}
proc `$`*(key: SecpKeyPair): string {.borrow.}

proc `==`*(a, b: SecpPrivateKey): bool {.borrow.}
proc `==`*(a, b: SecpPublicKey): bool {.borrow.}
proc `==`*(a, b: SecpSignature): bool {.borrow.}
proc `==`*(a, b: SecpKeyPair): bool {.borrow.}