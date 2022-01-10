## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implementes API for libp2p peer.

{.push raises: [Defect].}

import
  std/[hashes, strutils],
  stew/[base58, results],
  chronicles,
  nimcrypto/utils,
  ./crypto/crypto, ./multicodec, ./multihash, ./vbuffer,
  ./protobuf/minprotobuf

export results

const
  maxInlineKeyLength* = 42

type
  PeerId* = object
    data*: seq[byte]

func `$`*(pid: PeerId): string =
  ## Return base58 encoded ``pid`` representation.
  # This unusual call syntax is used to avoid a strange Nim compilation error
  base58.encode(Base58, pid.data)

func shortLog*(pid: PeerId): string =
  ## Returns compact string representation of ``pid``.
  var spid = $pid
  if len(spid) > 10:
    spid[3] = '*'
    spid.delete(4, spid.high - 6)

  spid

chronicles.formatIt(PeerId): shortLog(it)

func toBytes*(pid: PeerId, data: var openArray[byte]): int =
  ## Store PeerId ``pid`` to array of bytes ``data``.
  ##
  ## Returns number of bytes needed to store ``pid``.
  result = len(pid.data)
  if len(data) >= result and result > 0:
    copyMem(addr data[0], unsafeAddr pid.data[0], result)

template getBytes*(pid: PeerId): seq[byte] =
  ## Return PeerId ``pid`` as array of bytes.
  pid.data

func hex*(pid: PeerId): string =
  ## Returns hexadecimal string representation of ``pid``.
  toHex(pid.data)

template len*(pid: PeerId): int =
  ## Returns length of ``pid`` binary representation.
  len(pid.data)

func cmp*(a, b: PeerId): int =
  ## Compares two peer ids ``a`` and ``b``.
  ## Returns:
  ##
  ## | 0 iff a == b
  ## | < 0 iff a < b
  ## | > 0 iff a > b
  var i = 0
  var m = min(len(a.data), len(b.data))
  while i < m:
    result = ord(a.data[i]) - ord(b.data[i])
    if result != 0: return
    inc(i)
  result = len(a.data) - len(b.data)

template `<=`*(a, b: PeerId): bool =
  (cmp(a, b) <= 0)

template `<`*(a, b: PeerId): bool =
  (cmp(a, b) < 0)

template `>=`*(a, b: PeerId): bool =
  (cmp(a, b) >= 0)

template `>`*(a, b: PeerId): bool =
  (cmp(a, b) > 0)

template `==`*(a, b: PeerId): bool =
  (cmp(a, b) == 0)

template hash*(pid: PeerId): Hash =
  hash(pid.data)

func validate*(pid: PeerId): bool =
  ## Validate check if ``pid`` is empty or not.
  len(pid.data) > 0 and MultiHash.validate(pid.data)

func hasPublicKey*(pid: PeerId): bool =
  ## Returns ``true`` if ``pid`` is small enough to hold public key inside.
  if len(pid.data) > 0:
    var mh: MultiHash
    if MultiHash.decode(pid.data, mh).isOk:
      if mh.mcodec == multiCodec("identity"):
        result = true

func extractPublicKey*(pid: PeerId, pubkey: var PublicKey): bool =
  ## Returns ``true`` if public key was successfully decoded from PeerId
  ## ``pid``and stored to ``pubkey``.
  ##
  ## Returns ``false`` otherwise.
  if len(pid.data) > 0:
    var mh: MultiHash
    if MultiHash.decode(pid.data, mh).isOk:
      if mh.mcodec == multiCodec("identity"):
        let length = len(mh.data.buffer)
        result = pubkey.init(mh.data.buffer.toOpenArray(mh.dpos, length - 1))

func init*(pid: var PeerId, data: openArray[byte]): bool =
  ## Initialize peer id from raw binary representation ``data``.
  ##
  ## Returns ``true`` if peer was successfully initialiazed.
  var p = PeerId(data: @data)
  if p.validate():
    pid = p
    result = true

func init*(pid: var PeerId, data: string): bool =
  ## Initialize peer id from base58 encoded string representation.
  ##
  ## Returns ``true`` if peer was successfully initialiazed.
  var p = newSeq[byte](len(data) + 4)
  var length = 0
  if Base58.decode(data, p, length) == Base58Status.Success:
    p.setLen(length)
    var opid: PeerId
    shallowCopy(opid.data, p)
    if opid.validate():
      pid = opid
      result = true

func init*(t: typedesc[PeerId], data: openArray[byte]): Result[PeerId, cstring] =
  ## Create new peer id from raw binary representation ``data``.
  var res: PeerId
  if not init(res, data):
    err("peerid: incorrect PeerId binary form")
  else:
    ok(res)

func init*(t: typedesc[PeerId], data: string): Result[PeerId, cstring] =
  ## Create new peer id from base58 encoded string representation ``data``.
  var res: PeerId
  if not init(res, data):
    err("peerid: incorrect PeerId string")
  else:
    ok(res)

func init*(t: typedesc[PeerId], pubkey: PublicKey): Result[PeerId, cstring] =
  ## Create new peer id from public key ``pubkey``.
  var pubraw = ? pubkey.getBytes().orError(
    cstring("peerid: failed to get bytes from given key"))
  var mh: MultiHash
  if len(pubraw) <= maxInlineKeyLength:
    mh = ? MultiHash.digest("identity", pubraw)
  else:
    mh = ? MultiHash.digest("sha2-256", pubraw)
  ok(PeerId(data: mh.data.buffer))

func init*(t: typedesc[PeerId], seckey: PrivateKey): Result[PeerId, cstring] =
  ## Create new peer id from private key ``seckey``.
  PeerId.init(? seckey.getPublicKey().orError(cstring("invalid private key")))

func match*(pid: PeerId, pubkey: PublicKey): bool =
  ## Returns ``true`` if ``pid`` matches public key ``pubkey``.
  let p = PeerId.init(pubkey)
  if p.isErr:
    false
  else:
    pid == p.get()

func match*(pid: PeerId, seckey: PrivateKey): bool =
  ## Returns ``true`` if ``pid`` matches private key ``seckey``.
  let p = PeerId.init(seckey)
  if p.isErr:
    false
  else:
    pid == p.get()

## Serialization/Deserialization helpers

func write*(vb: var VBuffer, pid: PeerId) =
  ## Write PeerId value ``peerid`` to buffer ``vb``.
  vb.writeSeq(pid.data)

func write*(pb: var ProtoBuffer, field: int, pid: PeerId) =
  ## Write PeerId value ``peerid`` to object ``pb`` using ProtoBuf's encoding.
  write(pb, field, pid.data)

func getField*(pb: ProtoBuffer, field: int,
               pid: var PeerId): ProtoResult[bool] {.inline.} =
  ## Read ``PeerId`` from ProtoBuf's message and validate it
  var buffer: seq[byte]
  let res = ? pb.getField(field, buffer)
  if not(res):
    ok(false)
  else:
    var peerId: PeerId
    if peerId.init(buffer):
      pid = peerId
      ok(true)
    else:
      err(ProtoError.IncorrectBlob)
